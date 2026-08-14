#!/usr/bin/env bash
# droste-serve.sh — shared SERVICE-LAUNCH library (SOURCED, not executed).
#
# ONE launch path, TWO doors. Both callers build the identical SERVICE argv the
# same way (source droste-resolve.sh -> source /opt/resources/build-spec ->
# resolve::apply_spec, which ends with ENV_FILE + PRE_LAUNCH), then hand it to
# this library:
#
#   droste-entrypoint.sh  (SERVER lane, pid1)  -> serve::exec_service
#       foreground exec, exactly as before this file existed. The server lane is
#       DELIBERATELY untouched by everything else here: it never reads server.env,
#       never rewrites the port (its ports are podman-published HOST:CONTAINER
#       remaps — rewriting the in-container bind would break the remap), never
#       backgrounds anything. Two-container deploys keep working from these images.
#
#   droste-init-hook.sh   (DISTROBOX lane, runs from the container's init line)
#                                                  -> serve::maybe_launch
#       the MERGED-container "server door": `podman start <box>` replays the
#       distrobox init line, the hook applies the spec, and this library decides
#       whether that start should also bring the box's service up. The decision
#       lives in a config file on the per-box DATA volume (server.env, below), so
#       it is toggleable with an editor + `podman restart` and survives image
#       updates and container recreation.
#
# server.env (default /opt/data/server.env — same format and place as llama.env /
# ds4.env) is shell-sourceable KEY=VALUE:
#       SERVE=1            # 1/true/yes/on = this box serves on start; anything else = no
#       PORT=8188          # the HOST port the service binds DIRECTLY (host networking,
#                          # no remap: e.g. ds4 binds 8001 itself instead of 8000+remap)
# Missing, unreadable or malformed file => do not serve, no error: an interactive-only
# box must never fail to start because of this file. It is read in a SUBSHELL (a
# syntax error or a stray `exit` inside it can therefore not abort the init hook,
# and nothing it assigns leaks into the hook's environment).
#
# Supervision is podman's (`--health-cmd` + `--health-on-failure=restart`, wired at
# create time by droste-setup), probing droste-healthcheck.sh from inside the
# container. A restart re-runs the init line, i.e. re-runs serve::maybe_launch —
# which is why every step below is idempotent and why a leftover instance from a
# previous container start is actively cleaned up (see serve::maybe_launch).
#
# Sourced by a caller that has already set `set -euo pipefail`; kept in effect here.
set -euo pipefail

# ── Config (override via env before sourcing) ───────────────────────────────
: "${DROSTE_DATA_DIR:=/opt/data}"
: "${DROSTE_SERVE_ENV:=$DROSTE_DATA_DIR/server.env}"      # the serve config file
: "${DROSTE_SERVE_PID:=$DROSTE_DATA_DIR/.droste-serve.pid}"
: "${DROSTE_SERVE_LOG:=$DROSTE_DATA_DIR/.droste-serve.log}"
# The flag every one of the five services takes for its listen port (comfyui
# main.py, jupyter lab, vllm serve, llama-server, ds4-server all spell it
# `--port`). A build-spec may override it if a future port differs.
: "${SERVE_PORT_FLAG:=--port}"
: "${DROSTE_SERVE_STOP_WAIT:=15}"   # seconds to wait for a stale instance to die

# ── Messaging (independent of droste-resolve.sh: droste-healthcheck.sh sources
#    THIS file alone) ──────────────────────────────────────────────────────────
serve::info() { printf 'droste-serve: INFO: %s\n' "$*" >&2; }
serve::warn() { printf 'droste-serve: WARN: %s\n' "$*" >&2; }
serve::err()  { printf 'droste-serve: ERROR: %s\n' "$*" >&2; }

# ── Config reading ──────────────────────────────────────────────────────────
# read_config — parse server.env into SERVE_ENABLED (0/1), SERVE_PORT (digits or
# ""), SERVE_CONFIG_ERR (human message or ""). NEVER fails, never aborts the
# caller: the file is sourced inside a subshell with errexit/nounset OFF and all
# of its output discarded, and only the two keys we care about are printed back
# and then validated. So a hand-edited file with a typo degrades to "don't
# serve" instead of taking the box down.
# PORT is REQUIRED when SERVE is on: the healthcheck probe reads the same key, so
# a serve-without-port box would run unsupervised on a port nobody agreed on.
serve::read_config() {
    local file=${1:-$DROSTE_SERVE_ENV} raw="" k v sv="" pv=""
    SERVE_ENABLED=0
    SERVE_PORT=""
    SERVE_CONFIG_ERR=""
    [ -f "$file" ] && [ -r "$file" ] || return 0
    raw=$(
        set +e +u +o pipefail
        # shellcheck disable=SC1090
        . "$file" >/dev/null 2>&1
        printf 'serve=%s\nport=%s\n' "${SERVE-}" "${PORT-}"
    ) 2>/dev/null || raw=""
    while IFS='=' read -r k v; do
        case "$k" in
            serve) sv=$v ;;
            port)  pv=$v ;;
        esac
    done <<<"$raw"
    case "${sv,,}" in
        1|true|yes|on) SERVE_ENABLED=1 ;;
        *)             SERVE_ENABLED=0 ;;
    esac
    [ "$SERVE_ENABLED" -eq 1 ] || return 0
    if [[ $pv =~ ^[0-9]+$ ]] && [ "$pv" -ge 1 ] && [ "$pv" -le 65535 ]; then
        SERVE_PORT=$pv
    else
        SERVE_ENABLED=0
        SERVE_CONFIG_ERR="$file sets SERVE=$sv but no usable PORT (got '${pv}') — not serving. Add e.g. PORT=8188 and restart the container."
    fi
    return 0
}

# read_health_spec — pull the per-box probe endpoint out of the baked build-spec
# (rows HEALTH_PATH / HEALTH_ACCEPT; see base/resolve/build-spec.example). Sourced
# in a SUBSHELL for the same reason server.env is: the health probe must not be
# able to trip over spec-level side effects. Defaults are the safe generic pair
# ("/" and "ok" = any 2xx/3xx).
serve::read_health_spec() {
    local spec=${1:-${DROSTE_BUILD_SPEC:-/opt/resources/build-spec}} raw="" k v
    HEALTH_PATH="/"
    HEALTH_ACCEPT="ok"
    [ -f "$spec" ] && [ -r "$spec" ] || return 0
    raw=$(
        set +e +u +o pipefail
        # shellcheck disable=SC1090
        . "$spec" >/dev/null 2>&1
        printf 'path=%s\naccept=%s\n' "${HEALTH_PATH-}" "${HEALTH_ACCEPT-}"
    ) 2>/dev/null || raw=""
    while IFS='=' read -r k v; do
        case "$k" in
            path)   [ -n "$v" ] && HEALTH_PATH=$v ;;
            accept) [ -n "$v" ] && HEALTH_ACCEPT=$v ;;
        esac
    done <<<"$raw"
    case "$HEALTH_PATH" in
        /*) ;;
        *)  HEALTH_PATH="/$HEALTH_PATH" ;;
    esac
    case "$HEALTH_ACCEPT" in
        ok|any) ;;
        *)      HEALTH_ACCEPT="ok" ;;
    esac
    return 0
}

# ── Port plumbing ───────────────────────────────────────────────────────────
# apply_port — put the configured port into the SERVICE argv, in place. Replace
# the value after every existing $SERVE_PORT_FLAG (comfyui/jupyter carry one in
# the spec; ds4's PRE_LAUNCH builds one from DS4_DROSTE_PORT), else append the
# flag (llama/vllm take their port from an env file / config file — a trailing
# CLI flag wins over both in llama.cpp and vLLM, which is what "installer-owned
# ports" requires).
serve::apply_port() {
    local port=$1 i=0 n=${#SERVICE[@]} found=0
    while [ "$i" -lt "$n" ]; do
        if [ "${SERVICE[$i]}" = "$SERVE_PORT_FLAG" ]; then
            found=1
            if [ $((i + 1)) -lt "$n" ]; then
                SERVICE[i + 1]=$port
            else
                SERVICE+=("$port")
            fi
        fi
        i=$((i + 1))
    done
    [ "$found" -eq 1 ] || SERVICE+=("$SERVE_PORT_FLAG" "$port")
}

# _port_busy — is anything answering on 127.0.0.1:<port>? Uses curl (baked in the
# runtime base; bash /dev/tcp is not guaranteed to be compiled in). curl exit 7 =
# connection refused = free; anything else (0 = answered, 28 = timed out, protocol
# junk) is treated as occupied — under host networking that could be our own
# survivor from a previous start, another droste box, or a host process, and in
# every one of those cases starting a second binder is wrong.
serve::_port_busy() {
    local port=$1 rc=0
    command -v curl >/dev/null 2>&1 || return 1
    curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$port/" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 7 ]
}

# ── Process identity (the idempotency machinery) ────────────────────────────
# _proc_fields — echo "<state> <starttime>" for a pid, or fail. /proc/<pid>/stat's
# comm field (2) can contain spaces and parens, so everything up to the LAST ") "
# is dropped: the remaining field 1 is state (stat field 3) and field 20 is
# starttime (stat field 22).
serve::_proc_fields() {
    local pid=$1 stat
    [ -n "$pid" ] || return 1
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    stat=${stat##*") "}
    # shellcheck disable=SC2086   # deliberate word split of a numeric stat line
    set -- $stat
    [ "$#" -ge 20 ] || return 1
    printf '%s %s' "$1" "${20}"
}

# _instance_token — an id that is unique to THIS container start and stable within
# it: pid + starttime of our parent (distrobox-init's shell, which `eval`s the init
# hook once per start). WHY: the pid file lives on the DATA volume, so it outlives
# both the process and the container; distrobox boxes also default to `--pid host`,
# so a recorded pid can still be alive — and can even still be OUR service — after a
# `podman restart`. Comparing tokens is what lets maybe_launch tell "already
# launched during this start" (skip) from "leftover from the previous start"
# (adopt if it is serving, otherwise clear it out and relaunch).
serve::_instance_token() {
    local f
    if f=$(serve::_proc_fields "$PPID"); then
        printf '%s:%s' "$PPID" "${f#* }"
    else
        printf 'unknown:%s' "$$"
    fi
}

# _pid_is_ours — is <pid> a live, non-zombie process that is the very one we
# recorded at launch? Identity = pid AND process START TIME: a bare "is the pid
# alive" test would happily match an unrelated process that inherited the number
# (pids come from the HOST namespace here — distrobox defaults to `--pid host` —
# and the pid file lives on the data volume, so both outlive the container), while
# the start-time tick pins it to the exact process we forked. Zombies count as
# dead: our service can exit and sit unreaped for a while, because pid 1 is
# distrobox-init's keepalive shell, not an eager reaper.
# argv[0] is deliberately NOT part of the identity — it is recorded for humans
# only. Several services exec themselves into a different name (the `jupyter`
# dispatcher becomes `jupyter-lab`), so matching on it produces false negatives.
# A recorded start time is REQUIRED: a blank one (the service died before we could
# read /proc) must never match a live process, or _stop_stale could signal a
# stranger.
serve::_pid_is_ours() {
    local pid=$1 want_start=$2 fields state start
    [ -n "$want_start" ] || return 1
    fields=$(serve::_proc_fields "$pid") || return 1
    state=${fields% *}
    start=${fields#* }
    [ "$state" != Z ] || return 1
    [ "$start" = "$want_start" ] || return 1
    return 0
}

# _read_pidfile — load SERVE_REC_PID / _START / _TOKEN / _CMD from the pid file.
# (_CMD is read back purely so the field is documented and never mis-parsed; the
# identity check deliberately ignores it — see _pid_is_ours.)
# shellcheck disable=SC2034
serve::_read_pidfile() {
    SERVE_REC_PID="" SERVE_REC_START="" SERVE_REC_TOKEN="" SERVE_REC_CMD=""
    [ -f "$DROSTE_SERVE_PID" ] || return 1
    read -r SERVE_REC_PID SERVE_REC_START SERVE_REC_TOKEN SERVE_REC_CMD \
        < "$DROSTE_SERVE_PID" 2>/dev/null || return 1
    [ -n "${SERVE_REC_PID:-}" ] || return 1
    return 0
}

# _stop_stale — terminate a leftover service from a PREVIOUS container start that
# is NOT serving (the port was free when we checked). Only ever called for a pid
# whose start time matches the one we recorded when WE forked it, so this cannot
# signal an innocent bystander. Without it, a `--pid host` box that survives a
# healthcheck-triggered restart could come back with a wedged old process and no
# new one — the design's "restart brings the service back" promise would be false.
serve::_stop_stale() {
    local pid=$1 start=$2 waited=0
    serve::warn "stale service from a previous container start (pid $pid) is not serving — stopping it before relaunch."
    kill -TERM "$pid" 2>/dev/null || true
    while [ "$waited" -lt "$DROSTE_SERVE_STOP_WAIT" ]; do
        serve::_pid_is_ours "$pid" "$start" || return 0
        sleep 1
        waited=$((waited + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
    if serve::_pid_is_ours "$pid" "$start"; then
        serve::err "could not stop stale service pid $pid — not launching a second instance."
        return 1
    fi
    return 0
}

# ── Privilege model ─────────────────────────────────────────────────────────
# _privdrop_prefix — print (NUL-separated) the argv prefix that runs the service
# as the box user in the DISTROBOX lane; nothing in the server lane.
#
# WHO OWNS THE SERVED PROCESS:
#   server lane   — root, exactly as today. No image sets USER, droste-setup passes
#                   no --user, and the compose/plain create binds the HF cache to
#                   /root/.cache/huggingface: the service has always been root there
#                   and stays root. Nothing in this function fires for it.
#   merged/distrobox — the BOX USER (uid >= 1000, $DROSTE_USER). distrobox creates
#                   the container with `--userns keep-id`, so container uid 1000 IS
#                   the host user while container root maps to a SUBUID: a service
#                   running as root would write files into the user's real home
#                   (the HF cache lives there, auto-bound) and into the data volume
#                   that the host user then cannot even delete. It would also fight
#                   the resolver, whose whole distrobox deviation set (_mkuserdir,
#                   _own_dirs, copy-mode chown) exists to keep in-box state owned by
#                   uid 1000. Same-uid-as-the-interactive-door is also the point of
#                   the merge: `pip install` in the box and the served process are
#                   then literally the same environment and the same owner.
#
# setpriv, NOT runuser/su: supplementary groups must be INHERITED, not looked up.
# distrobox creates the container with `--annotation run.oci.keep_original_groups=1`
# and only adds the box user to `sudo` inside /etc/group — the host's render/video
# gids (what opens /dev/kfd and /dev/dri) reach the container as the container
# process's own group list, and `distrobox enter` (a podman exec) inherits that same
# list rather than doing a group lookup. setpriv --reuid/--regid keeps the current
# supplementary groups untouched, so the served process gets exactly the group set
# an interactive session has. runuser/su would re-initgroups from /etc/group and
# drop GPU access.
serve::_privdrop_prefix() {
    local uid gid
    [ "${DROSTE_LANE:-server}" = distrobox ] || return 0
    [ "$(id -u)" = "0" ] || return 0            # not root: nothing to drop
    [ -n "${DROSTE_USER:-}" ] || { serve::warn "no box user derived — the service will run as root."; return 0; }
    uid=$(id -u "$DROSTE_USER" 2>/dev/null) || uid=""
    gid=$(id -g "$DROSTE_USER" 2>/dev/null) || gid=""
    if [ -z "$uid" ] || [ -z "$gid" ]; then
        serve::warn "could not resolve uid/gid for '$DROSTE_USER' — the service will run as root."
        return 0
    fi
    if ! command -v setpriv >/dev/null 2>&1; then
        serve::warn "setpriv (util-linux) not found — the service will run as root; files it writes into your home and data dir will not be owned by you."
        return 0
    fi
    printf 'setpriv\0--reuid=%s\0--regid=%s\0--\0' "$uid" "$gid"
}

# ── Launch ──────────────────────────────────────────────────────────────────
# launch — start SERVICE in the background, record its identity, return.
# Output goes to a log on the data volume (readable from either door and from the
# host) with ONE generation kept, because a healthcheck-triggered restart would
# otherwise erase the evidence of the crash that caused it. stdin is /dev/null:
# nothing here is interactive, and the init hook's stdin is pid 1's.
serve::launch() {
    local token=$1 prefix=() pid fields start cmd0
    if [ "${#SERVICE[@]}" -eq 0 ]; then
        serve::err "no SERVICE defined in the build-spec — nothing to serve."
        return 1
    fi
    mapfile -t -d '' prefix < <(serve::_privdrop_prefix)
    mkdir -p "$(dirname "$DROSTE_SERVE_LOG")" 2>/dev/null || true
    if [ -s "$DROSTE_SERVE_LOG" ]; then
        mv -f "$DROSTE_SERVE_LOG" "$DROSTE_SERVE_LOG.prev" 2>/dev/null || true
    fi
    if ! ( : >"$DROSTE_SERVE_LOG" ) 2>/dev/null; then
        serve::warn "cannot write $DROSTE_SERVE_LOG — service output goes to the container log instead."
        DROSTE_SERVE_LOG=/dev/stderr
    fi
    {
        printf '=== droste-serve: %s — launching: %s\n' "$(date -Is 2>/dev/null || true)" "${SERVICE[*]}"
    } >>"$DROSTE_SERVE_LOG" 2>/dev/null || true

    HOME="${HOME:-/root}" \
    USER="${DROSTE_USER:-${USER:-root}}" \
    LOGNAME="${DROSTE_USER:-${LOGNAME:-root}}" \
        ${prefix[@]+"${prefix[@]}"} "${SERVICE[@]}" \
        >>"$DROSTE_SERVE_LOG" 2>&1 </dev/null &
    pid=$!

    # Record identity IMMEDIATELY (setpriv execs, it does not fork, so this pid is
    # the service). A service that dies instantly leaves no /proc entry — the start
    # time then records blank, which _pid_is_ours treats as "not ours", so the next
    # run relaunches instead of trusting a pid it cannot verify. argv[0] is written
    # as the 4th field for humans reading the file; it is not part of the identity.
    start=""
    if fields=$(serve::_proc_fields "$pid"); then
        start=${fields#* }
    fi
    cmd0=$(basename -- "${SERVICE[0]}")
    printf '%s %s %s %s\n' "$pid" "$start" "$token" "$cmd0" \
        > "$DROSTE_SERVE_PID" 2>/dev/null || serve::warn "could not write $DROSTE_SERVE_PID"
    # Keep the bookkeeping files deletable by the box user (they are on the host's
    # data dir; written here as root, which is a subuid on the host under keep-id).
    if [ "${DROSTE_LANE:-server}" = distrobox ] && [ -n "${DROSTE_USER:-}" ]; then
        chown "$DROSTE_USER:" "$DROSTE_SERVE_PID" "$DROSTE_SERVE_LOG" 2>/dev/null || true
    fi
    serve::info "service started (pid $pid) on port ${SERVE_PORT:-?}; output: $DROSTE_SERVE_LOG"
    return 0
}

# maybe_launch — the whole server-door decision, called once per container start
# from droste-init-hook.sh (and again after every healthcheck-triggered restart).
# Never returns non-zero for a reason that should keep the box from coming up.
serve::maybe_launch() {
    local token
    serve::read_config
    if [ -n "${SERVE_CONFIG_ERR:-}" ]; then
        serve::warn "$SERVE_CONFIG_ERR"
        return 0
    fi
    if [ "${SERVE_ENABLED:-0}" -ne 1 ]; then
        # Silent by design: interactive-only boxes are the common case, and this
        # runs on every single container start.
        return 0
    fi
    token=$(serve::_instance_token)

    if serve::_read_pidfile; then
        if serve::_pid_is_ours "$SERVE_REC_PID" "$SERVE_REC_START"; then
            if [ "$SERVE_REC_TOKEN" = "$token" ]; then
                serve::info "service already launched during this container start (pid $SERVE_REC_PID) — nothing to do."
                return 0
            fi
            if serve::_port_busy "$SERVE_PORT"; then
                serve::warn "a service from a previous container start (pid $SERVE_REC_PID) is still answering on port $SERVE_PORT — leaving it alone."
                return 0
            fi
            serve::_stop_stale "$SERVE_REC_PID" "$SERVE_REC_START" || return 0
        fi
    fi

    if serve::_port_busy "$SERVE_PORT"; then
        serve::warn "port $SERVE_PORT is already in use (host networking: another droste box or a host process?) — not starting a second listener. Change PORT in $DROSTE_SERVE_ENV or free the port, then restart the container."
        return 0
    fi

    serve::apply_port "$SERVE_PORT"
    serve::launch "$token" || serve::warn "service launch failed — the box is still usable interactively; see $DROSTE_SERVE_LOG."
    return 0
}

# exec_service — the FOREGROUND door (server lane, pid 1). Byte-for-byte the
# behaviour droste-entrypoint.sh had inline: exec the spec's SERVICE argv.
serve::exec_service() {
    if [ "${#SERVICE[@]}" -eq 0 ]; then
        serve::err "no SERVICE to exec"
        return 1
    fi
    exec "${SERVICE[@]}"
}
