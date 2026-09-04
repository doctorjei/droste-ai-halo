#!/usr/bin/env bash
# droste-server.sh — the SERVER VERBS: start / stop / restart / status.
#
# ⭐ THESE VERBS ACT ON THE SERVER, NOT THE CONTAINER (Jei's ruling, 2026-08-22):
# "Anyone who knows the difference will be able to restart the container. We can just
# make sure this is clear in our wording (without being too verbose)." So every word
# this file prints says **server**. The ONE thing that really does restart the
# container — podman's --health-on-failure=restart bounce — is the only place
# "box"/"container" is correct, and it lives in droste-healthcheck.sh.
# `podman restart <box>` remains the documented way to bounce the container and needs
# no wrapper here. NEVER blur the two: the whole point of the surgical-recovery design
# is that they are different events with different blast radii.
#
# INVOKED BY NAME. Four symlinks sit beside this file in /opt/resources/resolve (which
# is on PATH in every image):
#     server_start   server_stop   server_restart   server_status
# and the action is taken from $0, so `server_start` is a REAL COMMAND rather than a
# shell function. That matters: a function only exists in a login shell that sourced
# the banner, while these work from `distrobox enter <box> -- server_status`, from a
# script, and from the host unit's ExecStop.
#
# WHAT A VERB ACTUALLY DOES: it sets the INTENT (state/.IS_ACTIVE) and lets the
# existing machinery make reality match. It does NOT touch the STARTUP_ENABLED setting
# in the box's <box>.cfg — Jei's ruling: a user who starts a server by hand asked to
# start a server, not to change what the box does at boot. That asymmetry is exactly
# what the two-setting split buys, and it is why `stop` is always temporary: the next
# container start resets .IS_ACTIVE from STARTUP_ENABLED and the server comes back.
# ⚠️ IT ALSO MEANS THESE VERBS NEVER WRITE THAT FILE AT ALL. <box>.cfg is the user's
# several-hundred-line config surface, not a droste scratch file; we PARSE the five
# serve settings out of it (droste::cfg_get) and write our own state elsewhere. The one
# writer of a user's cfg is the installer, deliberately and only when they ask.
#
# WHY start CAN BE A THIN WRAPPER: serve::maybe_launch already owns already-running
# detection, stale cleanup, port-busy refusal, state recording and log handling, and
# serve::_privdrop_prefix opens with `[ "$(id -u)" = "0" ] || return 0` — "not root:
# nothing to drop" — so calling it as the box user from an interactive shell needs no
# special case. The pidfile and log are already chowned to that user.
set -uo pipefail

RESOLVE_DIR=${RESOLVE_DIR:-/opt/resources/resolve}
# shellcheck source=/dev/null
source "$RESOLVE_DIR/droste-serve.sh"
set +e   # this script decides its own exit codes

SELF=$(basename -- "$0")

usage() {
    # ⚠️ ASK FOR THE CONFIG PATH BEFORE NAMING IT. DROSTE_SERVE_ENV is EMPTY at source
    # time now that the serve settings live in the box's own <box>.cfg: the path is per
    # box and comes from the build-spec's CFG_FILE row, which serve::read_config is what
    # reads. Every other verb calls it first anyway; usage did not, and would have
    # printed a blank where a path belongs. The call parses a file, never fails, and
    # prints nothing.
    serve::read_config
    cat <<EOF
Usage: server_start | server_stop | server_restart | server_status
       ${SELF} <start|stop|restart|status>

  start    ask for this box's server to be running now
  stop     ask for it to stop (TEMPORARY — it comes back at the next box start
           if ${SERVE_CFG_PREFIX}STARTUP_ENABLED in ${DROSTE_SERVE_ENV} says yes)
  restart  stop, then start
  status   what the box wants, and what is actually true

To change what happens at BOX START, edit ${SERVE_CFG_PREFIX}STARTUP_ENABLED in
${DROSTE_SERVE_ENV} (that setting survives recreate; these verbs do not
touch it). To restart the CONTAINER rather than the server, use
\`podman restart <box>\` on the host.
EOF
}

# The service argv comes from serve::build_service in the shared library — the
# healthcheck's relaunch path needs exactly the same thing, so there is one copy of it
# there rather than two that can drift.
#
# ── stop ────────────────────────────────────────────────────────────────────
# Graceful by construction: SIGTERM, wait up to DROSTE_SERVE_STOP_WAIT, then SIGKILL.
# ⚠️ Only ever signals a pid whose recorded process START TIME still matches the one we
# wrote when WE forked it (serve::_pid_is_ours), so it structurally cannot kill a
# bystander that inherited the pid number — which is a real risk here, because these
# boxes default to `--pid host` and the record outlives the container.
stop_service() {
    local waited=0 quiet=${1:-}
    serve::set_active 0
    if ! serve::_read_pidfile; then
        [ -n "$quiet" ] || printf 'No launch record — nothing of ours is running.\n'
        return 0
    fi
    if ! serve::_pid_is_ours "$SERVE_REC_PID" "$SERVE_REC_START"; then
        [ -n "$quiet" ] || printf 'The server is not running (recorded pid %s is gone).\n' "$SERVE_REC_PID"
        serve::_write_state stopped - - "${SERVE_REC_TOKEN:--}" "${SERVE_REC_CMD:--}"
        return 0
    fi
    printf 'Stopping the server (pid %s)...\n' "$SERVE_REC_PID"
    serve::_log_note "STOPPED: server_stop requested by $(id -un 2>/dev/null || echo '?')."
    kill -TERM "$SERVE_REC_PID" 2>/dev/null
    while [ "$waited" -lt "$DROSTE_SERVE_STOP_WAIT" ]; do
        if ! serve::_pid_is_ours "$SERVE_REC_PID" "$SERVE_REC_START"; then
            serve::_write_state stopped - - "${SERVE_REC_TOKEN:--}" "${SERVE_REC_CMD:--}"
            printf 'Server stopped.\n'
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    serve::warn "the server did not exit within ${DROSTE_SERVE_STOP_WAIT}s — sending SIGKILL."
    kill -KILL "$SERVE_REC_PID" 2>/dev/null
    sleep 1
    if serve::_pid_is_ours "$SERVE_REC_PID" "$SERVE_REC_START"; then
        serve::err "could not stop the server (pid $SERVE_REC_PID)."
        return 1
    fi
    serve::_write_state stopped - - "${SERVE_REC_TOKEN:--}" "${SERVE_REC_CMD:--}"
    printf 'Server stopped (had to be killed).\n'
    return 0
}

# ── start ───────────────────────────────────────────────────────────────────
start_service() {
    local rc
    serve::read_config
    if [ -n "${SERVE_CONFIG_ERR:-}" ]; then
        serve::err "$SERVE_CONFIG_ERR"
        return 1
    fi
    if [ -z "${SERVE_PORT:-}" ]; then
        serve::err "${SERVE_PORT_ERR:-no usable PORT in $DROSTE_SERVE_ENV}"
        return 1
    fi
    serve::build_service || return 1
    # Intent FIRST, then the launch: if the launch fails, the box still WANTS a server,
    # which is the state the healthcheck's relaunch acts on. Setting it afterwards
    # would leave a failed start looking like a box that was never asked to serve.
    # 🚨 A FAILED INTENT WRITE IS FATAL TO THIS VERB, NOT A WARNING TO STEP PAST (s65).
    # set_active already warns, but the old code ignored its return and launched anyway
    # — producing a box that was serving while every reader of the flag believed it had
    # never been asked. Measured on raiju with a full disk: `server_status` reported
    # "should be running now: no", and the healthcheck (which gates on the same flag)
    # declined to relaunch, so the box could not recover on its own.
    # ⭐ Refusing here is the honest failure: nothing is started, the message names the
    # cause, and the state on disk still matches what the box will do.
    if ! serve::set_active 1; then
        serve::err "could not record that this box should be serving — $DROSTE_SERVE_STATE_DIR is not writable (a full disk will do this)."
        serve::err "NOT starting: the healthcheck reads that same flag, so it would not relaunch this service either, and server_status would report the box as deliberately idle. Free some space and try again."
        return 1
    fi
    # 🚨 THE LAUNCH IS DELEGATED — full reasoning in droste-serve.sh's supervisor
    # section. Short form: a service forked from a TTY exec session (which every
    # `distrobox enter` is) is KILLED when that session ends, so a verb that forked it
    # here would report success and leave nothing serving. The supervisor has no TTY
    # anywhere in its ancestry.
    # ⚙️ build_service still runs ABOVE, in this process, on purpose: a broken spec is
    # then reported to the person who typed the command instead of only to the
    # container log. The supervisor rebuilds before launching, which is safe because
    # PRE_LAUNCH is idempotent by contract (it rebuilds SERVICE from its base arrays
    # rather than appending, so calling it twice cannot grow the argv).
    rc=0
    serve::request_launch || rc=$?
    if [ "$rc" -eq 1 ]; then
        serve::warn "no launch supervisor is running — starting the service in this session instead."
        serve::warn "⚠️ If you are inside \`distrobox enter\`, it will be killed when you leave. Restart the container to get a supervised service."
        serve::maybe_launch
    fi
    if serve::state_ok; then
        printf 'Server running (pid %s) on port %s.\n' "$SERVE_REC_PID" "$SERVE_PORT"
        return 0
    fi
    printf 'Server did NOT come up: %s\n' "${SERVE_STATE_MSG:-unknown}"
    return 1
}

# ── status ──────────────────────────────────────────────────────────────────
# Reports the two questions SEPARATELY, because they are separate: what the box WANTS
# (intent) and what is actually true (observation). A crashed server is "wanted, not
# running" — and saying so is the difference between this and a bare `ps`.
status_service() {
    local want obs
    serve::read_config
    # THREE answers, not two — see serve::intent_state for why "no" and "we could not
    # record it" must not be the same word. Kept in the library rather than inline here
    # so it is reachable by a test without running this whole script.
    want=$(serve::intent_state)
    printf 'Server for this box\n'
    printf '  should be running now : %s\n' "$want"
    if [ "$want" = unknown ]; then
        printf '                          ⚠️ %s is not writable — a full disk will do this.\n' \
            "$DROSTE_SERVE_STATE_DIR"
        printf '                          This box may have been asked to serve and been unable to\n'
        printf '                          record it. The healthcheck reads the same flag, so it will\n'
        printf '                          not relaunch either. Free space, then server_start.\n'
    fi
    # 🚨 NAME THE SETTING AS IT IS SPELLED IN THE USER'S FILE. The names are per box
    # (`DROSTE_<APP>_STARTUP_ENABLED`), so a bare `STARTUP_ENABLED` names a variable that
    # is not literally in the file we just told them to open. The prefix is loaded by
    # serve::read_config, which every caller here runs first; the fallback keeps the
    # sentence readable if a spec ever omits the row rather than printing a bare `_`.
    printf '  at box start          : %s   (%sSTARTUP_ENABLED in %s)\n' \
        "$([ "${SERVE_STARTUP_ENABLED:-0}" -eq 1 ] && printf yes || printf no)" \
        "${SERVE_CFG_PREFIX:-}" "$DROSTE_SERVE_ENV"
    # ADDRESS AND PORT ARE ONE ANSWER TO ONE QUESTION ("where do I reach it?"), and the
    # address stopped being a constant when HOST became a setting. Printing the port
    # alone would leave a user who bound their server to one interface with no way to
    # tell — from the tool whose whole job is to say what the box wants — why nothing
    # answers on the address they are trying. Same `<unset>` idiom as the port.
    # 🚨 A REFUSED BOX MUST NOT ADVERTISE AN ADDRESS IT IS NOT USING (s60). When
    # read_config refuses — a bad HOST, a half-set TLS pair, no usable port — it leaves
    # SERVE_HOST at the DEFAULT rather than clearing it, deliberately: clearing would let
    # apply_host emit `--host ""`, which is the s57 box-killer. But that means the value
    # sitting here is the address we DECLINED to serve on, printed two lines above
    # "config: … THIS BOX IS NOT SERVING". Showing it as a fact would be the display
    # contradicting the diagnosis. ⭐ The config line is the answer in that state; these
    # two rows have no honest value to report, so they say so.
    if [ -n "${SERVE_CONFIG_ERR:-}" ]; then
        printf '  address               : —   (not serving; see config below)\n'
        printf '  port                  : —\n'
    else
        printf '  address               : %s\n' "${SERVE_HOST:-<unset>}"
        printf '  port                  : %s\n' "${SERVE_PORT:-<unset>}"
    fi
    if serve::state_ok; then
        obs="running (pid ${SERVE_REC_PID})"
    else
        obs="not running — ${SERVE_STATE_MSG}"
    fi
    printf '  actually              : %s\n' "$obs"
    printf '  log                   : %s\n' "$DROSTE_SERVE_LOG"
    # A serve setting we could not use is the FIRST thing a user needs here, and it is
    # the one thing the two lines above cannot express: "wanted: yes / actually: not
    # running" is true of a broken config and of a crashed server alike. read_config
    # already worked out which; refusing to repeat it would be hiding an answer we hold.
    if [ -n "${SERVE_CONFIG_ERR:-}" ]; then
        printf '  config                : %s\n' "$SERVE_CONFIG_ERR"
    fi
    # ⚠️ ABSENT IS NOT THE SAME AS STOPPED, and saying so would be a lie in the one
    # case a user is most likely to be confused: a box that has never started a server
    # has no .IS_ACTIVE file at all, and "the server was stopped by hand" would send
    # them looking for something that never happened. Only claim a deliberate stop when
    # the flag EXISTS and says no.
    if [ "$want" = no ] && [ -f "$DROSTE_SERVE_ACTIVE" ] && [ "${SERVE_STARTUP_ENABLED:-0}" -eq 1 ]; then
        printf '\nThe server was stopped by hand. That is TEMPORARY — it starts again\n'
        printf 'with the box. To keep it down, set %sSTARTUP_ENABLED to no in %s.\n' \
            "${SERVE_CFG_PREFIX:-}" "$DROSTE_SERVE_ENV"
    elif [ "$want" = no ] && [ ! -f "$DROSTE_SERVE_ACTIVE" ]; then
        printf '\nThis box has not started a server in this container yet.\n'
    fi
    serve::state_ok >/dev/null 2>&1
}

case "$SELF" in
    server_start)   action=start ;;
    server_stop)    action=stop ;;
    server_restart) action=restart ;;
    server_status)  action=status ;;
    *)              action=${1:-} ;;
esac

case "$action" in
    start)   start_service ;;
    stop)    stop_service ;;
    restart) stop_service quiet; start_service ;;
    status)  status_service ;;
    # Hidden, and hidden ON PURPOSE: this is the daemon body, spawned by the init hook
    # via serve::supervisor_start. It is not a verb, there is no symlink for it, and it
    # is deliberately absent from usage() — a user who ran it by hand would get a
    # second supervisor competing for the same fifo. Named with a `__` prefix for the
    # same reason. See droste-serve.sh's supervisor section for why it exists at all.
    __supervisor) serve::supervisor_loop ;;
    -h|--help|help) usage; exit 0 ;;
    *)       usage; exit 2 ;;
esac
exit $?
