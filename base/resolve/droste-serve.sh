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
#       STARTUP_ENABLED=1  # 1/true/yes/on = start this box's server when the BOX starts
#       PORT=8188          # the HOST port the service binds DIRECTLY (host networking,
#                          # no remap: e.g. ds4 binds 8001 itself instead of 8000+remap)
#
# ⭐ TWO SETTINGS, AND THE IMPORTANT PART IS THE LIFETIMES (s45). server.env used to
# carry one knob, `SERVE`, meaning two different things at once — "start at box start"
# AND "this box is supposed to be serving". That single conflation is why stopping the
# service by hand got the container restarted under you, forever, and why holding the
# door shut for a test meant editing a file that SURVIVES RECREATE.
#
#   | | STARTUP_ENABLED           | state/.IS_ACTIVE                        |
#   |-|--------------------------|-----------------------------------------|
#   | what     | a KEY in server.env | a FILE in the program-cache state dir |
#   | written  | by the USER         | by the MACHINE (the verbs, the hook)  |
#   | lifetime | persistent, survives recreate | reset EVERY container start  |
#   | means    | start it at box start | it SHOULD be running right now      |
#
# So a stop is ALWAYS TEMPORARY and the user has to remember nothing. Putting the
# "now" flag in server.env would have re-created the original foot-gun.
# 🚨 `SERVE` is still READ as a fallback (there are live boxes) — see read_config.
# Missing, unreadable or malformed file => do not serve, no error: an interactive-only
# box must never fail to start because of this file. It is read in a SUBSHELL (a
# syntax error or a stray `exit` inside it can therefore not abort the init hook,
# and nothing it assigns leaks into the hook's environment).
#
# Supervision is podman's (`--health-cmd` + `--health-on-failure=restart`, wired at
# create time by droste-setup.sh), probing droste-healthcheck.sh from inside the
# container. A restart re-runs the init line, i.e. re-runs serve::maybe_launch —
# which is why every step below is idempotent and why a leftover instance from a
# previous container start is actively cleaned up (see serve::maybe_launch).
#
# THE STATE RECORD (proof of ownership). Every decision this library makes about
# the service is written to ONE line in $DROSTE_SERVE_RECORD on the PROGRAM-CACHE
# volume (a pid record is re-obtainable bookkeeping — cache class by ruling; the
# service LOG beside it stays on the data volume, because it is what a user reads
# when things broke):
#
#       <pid> <starttime> <token> <argv0> <status>
#       12345 998877 4242:112233 llama-server running
#       -     -      4242:112233 -        refused
#
# with "-" for any field that does not apply. `status` is
# running | starting | stopped | refused | failed
# — WORDS, not 0/1/2, by the same readability rule that named STARTUP_ENABLED
# (`status=starting` needs no legend), and it is what makes the healthcheck honest:
# these boxes use HOST
# networking, so a probe of the port alone proves only that SOMETHING answers it.
# When the door refuses to start a second listener on a port another process
# already holds, the squatter's reply used to satisfy the probe and the box
# reported HEALTHY while serving nothing at all. droste-healthcheck.sh therefore
# requires BOTH halves: this record says OUR launch succeeded and that exact
# process is still alive (serve::state_ok), AND the endpoint answers.
# Every path through maybe_launch that ends in "we are not serving" rewrites the
# record (refused/failed) — it lives on a host volume and outlives both the
# process and the container, so it is never trusted just for being there.
#
# Sourced by a caller that has already set `set -euo pipefail`; kept in effect here.
set -euo pipefail

# ── Config (override via env before sourcing) ───────────────────────────────
# Two per-box roots, same names and defaults as droste-resolve.sh (this library is
# sourced on its own by droste-healthcheck.sh, so it cannot rely on that one having
# set them). Class split, per the storage taxonomy: the settings file and the
# service log are DATA (user-edited / read exactly when something broke), the pid
# record is PROGRAM CACHE (bookkeeping about a process that no longer exists once
# the box is recreated).
: "${DROSTE_DATA_DIR:=/opt/data}"
: "${DROSTE_PCACHE_DIR:=/opt/program-cache}"
: "${DROSTE_SERVE_ENV:=$DROSTE_DATA_DIR/server.env}"      # the serve config file
# ── The state folder (s45) ──────────────────────────────────────────────────
# Per-start state lives in ONE folder on the PROGRAM CACHE, and the folder supplies the
# context so the names inside it can be short (the same argument that lets server.env
# carry a bare PORT):
#   state/launch      the launch record  — OBSERVATION: what we launched, and how it went
#   state/.IS_ACTIVE  0/1                — INTENT: should a server be running right now
# Keeping those in two files is the point, not an accident: they answer different
# questions and are written at different moments (a `stop` sets intent with no launch
# involved). Folding intent into the record — or into server.env — would re-create the
# very conflation this split exists to remove.
# ⚠️ RENAMED FROM `.droste-serve.pid`: that name described one of its five fields. An
# existing box has its record at the old path, so the first start on new code finds none;
# state_ok already reports that honestly ("no launch record …"), so the cost is ONE
# spurious unhealthy cycle at upgrade. Known and accepted, not discovered later.
: "${DROSTE_SERVE_STATE_DIR:=$DROSTE_PCACHE_DIR/state}"
: "${DROSTE_SERVE_RECORD:=$DROSTE_SERVE_STATE_DIR/launch}"      # the launch record
: "${DROSTE_SERVE_ACTIVE:=$DROSTE_SERVE_STATE_DIR/.IS_ACTIVE}"  # the intent flag
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
# read_config — parse server.env into SERVE_STARTUP_ENABLED (0/1), SERVE_PORT (digits
# or ""), SERVE_CONFIG_ERR (human message or ""). NEVER fails, never aborts the
# caller: the file is sourced inside a subshell with errexit/nounset OFF and all
# of its output discarded, and only the keys we care about are printed back
# and then validated. So a hand-edited file with a typo degrades to "don't
# serve" instead of taking the box down.
# PORT is REQUIRED when startup is on: the healthcheck probe reads the same key, so
# a serve-without-port box would run unsupervised on a port nobody agreed on.
#
# ⭐ THE KEY IS `STARTUP_ENABLED`, AND IT ANSWERS EXACTLY ONE QUESTION: "start the
# server when the box starts". It does NOT mean "this box should be serving right
# now" — that is state/.IS_ACTIVE, and conflating the two is the bug this whole
# design exists to remove (a user who stopped the service by hand used to get the
# container restarted under them, forever, because the box still said SERVE=1).
# The name is Jei's, and so is the reason: "enabled" alone reads as "on right now"
# to anyone who does not speak systemd, so STARTUP supplies the disambiguation.
# The dropped SERVE_ prefix is no loss — server.env already supplies the noun, and
# its other key is a bare PORT.
#
# 🚨 `SERVE` IS STILL READ, AS A FALLBACK, AND THE FALLBACK MUST NOT BE DROPPED IN
# THE SAME RELEASE THAT INTRODUCES THE NEW KEY. There are live boxes whose file says
# `SERVE=1`; a straight rename would make every one of them silently stop serving
# with nothing saying why. Same rule as the path-spelling work: READ TOLERANTLY,
# WRITE THE NEW FORM (the installer rewrites the file on its next modify run).
# STARTUP_ENABLED WINS when both are present — an explicit new key is a deliberate
# statement, and a stale SERVE beside it is what a half-migrated file looks like.
serve::read_config() {
    local file=${1:-$DROSTE_SERVE_ENV} raw="" k v sv="" ev="" pv="" src=""
    SERVE_STARTUP_ENABLED=0
    SERVE_PORT=""
    SERVE_PORT_ERR=""
    SERVE_CONFIG_ERR=""
    [ -f "$file" ] && [ -r "$file" ] || return 0
    raw=$(
        set +e +u +o pipefail
        # shellcheck disable=SC1090
        . "$file" >/dev/null 2>&1
        printf 'startup=%s\nserve=%s\nport=%s\n' "${STARTUP_ENABLED-}" "${SERVE-}" "${PORT-}"
    ) 2>/dev/null || raw=""
    while IFS='=' read -r k v; do
        case "$k" in
            startup) ev=$v ;;
            serve)   sv=$v ;;
            port)    pv=$v ;;
        esac
    done <<<"$raw"
    # New key if it is present at all; the legacy key only when it is not.
    if [ -n "$ev" ]; then src=STARTUP_ENABLED; else src=SERVE; ev=$sv; fi
    case "${ev,,}" in
        1|true|yes|on) SERVE_STARTUP_ENABLED=1 ;;
        *)             SERVE_STARTUP_ENABLED=0 ;;
    esac
    # ⭐ PORT IS PARSED ALWAYS, not only when startup is on — this MOVED in s45 and the
    # move is load-bearing. The verbs can now start a server on a box whose
    # STARTUP_ENABLED is 0 (Jei's ruling: starting by hand must not rewrite what the box
    # does at boot), and that launch needs the port exactly as much as a boot-time one.
    # Under the old early return it would have found SERVE_PORT empty.
    if [[ $pv =~ ^[0-9]+$ ]] && [ "$pv" -ge 1 ] && [ "$pv" -le 65535 ]; then
        SERVE_PORT=$pv
    else
        SERVE_PORT_ERR="$file has no usable PORT (got '${pv}') — add e.g. PORT=8188."
    fi
    # A box asked to serve AT STARTUP without a usable port must not serve, and must say
    # why: the healthcheck probe reads the same key, so it would otherwise run
    # unsupervised on a port nobody agreed on. (Unchanged behaviour, new placement.)
    if [ "$SERVE_STARTUP_ENABLED" -eq 1 ] && [ -z "$SERVE_PORT" ]; then
        SERVE_STARTUP_ENABLED=0
        SERVE_CONFIG_ERR="$file sets $src=$ev but no usable PORT (got '${pv}') — not serving. Add e.g. PORT=8188 and restart the container."
    fi
    return 0
}

# ── Intent: state/.IS_ACTIVE ────────────────────────────────────────────────
# "Should a server be running right now?" — the USER's intent, set by the verbs and
# reset from STARTUP_ENABLED at every container start. NOT an observation: after a
# crash, .IS_ACTIVE=1 with nothing serving is the CORRECT reading — the system wants
# it up and is failing to keep it up, which is exactly the state the relaunch logic
# acts on. The observation stays where it already is and is already honest
# (serve::state_ok: pid + process start-time + port probe).
#
# 🚨 "RESET AT EVERY CONTAINER START" IS ENFORCED BY CODE, NOT BY THE STORAGE.
# /opt/program-cache is a HOST directory and survives container restarts, so nothing
# resets this file by itself — droste-init-hook.sh calls serve::reset_active on every
# start, and that call is what makes "stop is always temporary" true.
serve::is_active() {
    local v=""
    [ -f "$DROSTE_SERVE_ACTIVE" ] && [ -r "$DROSTE_SERVE_ACTIVE" ] || return 1
    read -r v < "$DROSTE_SERVE_ACTIVE" 2>/dev/null || return 1
    case "${v,,}" in
        1|true|yes|on) return 0 ;;
        *)             return 1 ;;
    esac
}

# set_active — write the intent flag. Chowned like every other file this library
# creates in the distrobox lane: it is written as root (a host subuid under keep-id)
# onto a host dir the box user owns, and the VERBS write it as that user.
serve::set_active() {  # 0|1
    local want=$1
    mkdir -p "$DROSTE_SERVE_STATE_DIR" 2>/dev/null || true
    printf '%s\n' "$want" > "$DROSTE_SERVE_ACTIVE" 2>/dev/null || {
        serve::warn "could not write $DROSTE_SERVE_ACTIVE"
        return 1
    }
    if [ "${DROSTE_LANE:-server}" = distrobox ] && [ -n "${DROSTE_USER:-}" ]; then
        chown "$DROSTE_USER:" "$DROSTE_SERVE_ACTIVE" 2>/dev/null || true
        chown "$DROSTE_USER:" "$DROSTE_SERVE_STATE_DIR" 2>/dev/null || true
    fi
    return 0
}

# reset_active — the once-per-container-start reset. Called by the init hook BEFORE
# maybe_launch, so a box whose user stopped the service by hand comes back serving on
# the next start with nothing to remember, and a box that was never meant to serve
# stays off.
serve::reset_active() {
    serve::read_config
    if [ "${SERVE_STARTUP_ENABLED:-0}" -eq 1 ]; then
        serve::set_active 1
    else
        serve::set_active 0
    fi
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
# the spec; ds4's PRE_LAUNCH emits one only if a user re-adds DS4_DROSTE_PORT,
# which templates/ds4.env now deliberately omits), else append the flag
# (llama/vllm/ds4 otherwise take their port from an env file / config file /
# their own built-in default — a trailing CLI flag wins over all of those in
# llama.cpp, vLLM and ds4-server, which is what "installer-owned ports"
# requires).
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
# hook once per start). WHY: the pid file lives on a HOST volume, so it outlives
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
# and the pid file lives on a host volume, so both outlive the container), while
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

# _read_pidfile — load SERVE_REC_PID / _START / _TOKEN / _CMD / _STATUS from the
# state record. (_CMD is read back purely so the field is documented and never
# mis-parsed; the identity check deliberately ignores it — see _pid_is_ours.)
#
# ⚠️ THE EMPTY-STATUS DEFAULT WAS FLIPPED IN s45, AND IT MATTERS. It used to read as
# `running` — an optimistic default, harmless while every record either had a status
# or came from a pre-status image. It becomes WRONG the moment `starting` exists: a
# truncated or half-written record would read as "up and fine". It now FAILS CLOSED.
# The compatibility reason for the old default is gone anyway: the record MOVED to
# state/launch in the same change, so a pre-status record at the old path is never
# read at all — a start with no record simply relaunches, which is correct.
# shellcheck disable=SC2034
serve::_read_pidfile() {
    SERVE_REC_PID="" SERVE_REC_START="" SERVE_REC_TOKEN="" SERVE_REC_CMD="" SERVE_REC_STATUS=""
    [ -f "$DROSTE_SERVE_RECORD" ] || return 1
    read -r SERVE_REC_PID SERVE_REC_START SERVE_REC_TOKEN SERVE_REC_CMD SERVE_REC_STATUS \
        < "$DROSTE_SERVE_RECORD" 2>/dev/null || return 1
    [ -n "${SERVE_REC_PID:-}" ] || return 1
    [ -n "${SERVE_REC_STATUS:-}" ] || SERVE_REC_STATUS=unknown   # fail closed, see above
    return 0
}

# _write_state — write THE state record (one line, see the header). Every field is
# written as "-" when it does not apply, so the line always has five fields and
# `read` can never shift them: a blank start time used to collapse two separators
# into one and slide the token into the start column.
# Chowned to the box user for the same reason the log is: it is written as root in
# the distrobox lane (a subuid on the host under keep-id) onto a host dir of the
# user's (the program-cache root).
serve::_write_state() {
    local status=$1 pid=${2:--} start=${3:--} token=${4:--} cmd=${5:--}
    mkdir -p "$(dirname "$DROSTE_SERVE_RECORD")" 2>/dev/null || true
    printf '%s %s %s %s %s\n' "$pid" "$start" "$token" "$cmd" "$status" \
        > "$DROSTE_SERVE_RECORD" 2>/dev/null || {
        serve::warn "could not write $DROSTE_SERVE_RECORD"
        return 1
    }
    if [ "${DROSTE_LANE:-server}" = distrobox ] && [ -n "${DROSTE_USER:-}" ]; then
        chown "$DROSTE_USER:" "$DROSTE_SERVE_RECORD" 2>/dev/null || true
    fi
    return 0
}

# _log_note — append one header line to the service log, in the log's own
# "=== droste-serve: <ts> — <what>" style. WHY it exists beyond launch's own
# header: the log is created AT LAUNCH, so a start that never launched (the
# port-in-use refusal) left no log at all — and the log on the data volume is the
# first place a user looks. "No log" reads as "nothing ran"; it must instead say
# what the door decided and why. No /dev/* guard: writing to the /dev/stderr
# fallback is fine (only _log_tail must never READ it back).
serve::_log_note() {
    local msg=$1
    case "$DROSTE_SERVE_LOG" in
        /dev/*) ;;
        *)      mkdir -p "$(dirname "$DROSTE_SERVE_LOG")" 2>/dev/null || true ;;
    esac
    printf '=== droste-serve: %s — %s\n' "$(date -Is 2>/dev/null || true)" "$msg" \
        >>"$DROSTE_SERVE_LOG" 2>/dev/null || return 0
    if [ "${DROSTE_LANE:-server}" = distrobox ] && [ -n "${DROSTE_USER:-}" ]; then
        chown "$DROSTE_USER:" "$DROSTE_SERVE_LOG" 2>/dev/null || true
    fi
    return 0
}

# _not_serving — the ONE way this library says "this container start is not
# serving": warn into the container log (what `podman logs` shows), append the
# same sentence to the service log (what the user reads first), and stamp the
# state record so the healthcheck cannot be fooled by whatever else answers the
# port. Every early return from maybe_launch that is not "our service is up"
# goes through here.
serve::_not_serving() {
    local status=$1 token=$2 pid=$3 start=$4 msg=$5
    serve::warn "$msg"
    serve::_log_note "${status^^}: $msg"
    serve::_write_state "$status" "$pid" "$start" "$token" "-"
    return 0
}

# _record_age — seconds since the launch record was last written, or a large number
# when there is no record. The record's OWN MTIME is the "since when" the `starting`
# status needs, which is why `starting` cost no new file and no format change: one
# artifact answers "where is the launch up to?", exactly as one answers "should it be
# running?". Prints a bare integer; never fails (a stat we cannot do reads as "old",
# which lets a relaunch proceed rather than wedging on a missing timestamp).
serve::_record_age() {
    local mtime now
    mtime=$(stat -c %Y "$DROSTE_SERVE_RECORD" 2>/dev/null) || { printf '%s' 99999; return 0; }
    now=$(date +%s 2>/dev/null) || { printf '%s' 99999; return 0; }
    printf '%s' $(( now - mtime ))
}

# state_ok — did OUR launch succeed, and is that exact process still alive?
# The healthcheck's first gate (see droste-healthcheck.sh); sets SERVE_STATE_MSG
# with the reason on failure. Deliberately says nothing about the port: the probe
# is the second, independent gate.
# shellcheck disable=SC2034   # SERVE_STATE_MSG is consumed by droste-healthcheck.sh
serve::state_ok() {
    SERVE_STATE_MSG=""
    if ! serve::_read_pidfile; then
        SERVE_STATE_MSG="no launch record at $DROSTE_SERVE_RECORD — the server door has not started a service in this container. See $DROSTE_SERVE_LOG (and the container log) for what it decided instead."
        return 1
    fi
    case "$SERVE_REC_STATUS" in
        running) ;;
        starting)
            # A launch is IN FLIGHT (see serve::_relaunch_due). Not serving yet, and
            # deliberately not treated as a failure to be retried: the whole reason
            # this value exists is that ds4 can take minutes to load and a probe every
            # 30s would otherwise start a second launch racing the first for the port.
            SERVE_STATE_MSG="a launch is still in progress (started $(serve::_record_age)s ago) — not serving yet. See $DROSTE_SERVE_LOG."
            return 1
            ;;
        refused)
            SERVE_STATE_MSG="the server door REFUSED to launch (port ${SERVE_PORT:-?} was already in use when the container started) — whatever answers that port is not this box's service. See $DROSTE_SERVE_LOG."
            return 1
            ;;
        stopped)
            # Deliberate: someone ran server_stop. Reported plainly rather than as a
            # fault — but still `return 1`, because the question this function answers
            # is "is our service up", and it is not. The healthcheck never sees this:
            # a stop clears .IS_ACTIVE and the probe exits at that gate first.
            SERVE_STATE_MSG="the server was stopped by hand (server_stop). It starts again with the box unless STARTUP_ENABLED=0 in $DROSTE_SERVE_ENV."
            return 1
            ;;
        *)
            SERVE_STATE_MSG="the last launch attempt recorded status '$SERVE_REC_STATUS' — nothing of ours is serving. See $DROSTE_SERVE_LOG."
            return 1
            ;;
    esac
    if ! serve::_pid_is_ours "$SERVE_REC_PID" "$SERVE_REC_START"; then
        SERVE_STATE_MSG="the service we launched (pid $SERVE_REC_PID) is gone — anything still answering port ${SERVE_PORT:-?} is not it. See $DROSTE_SERVE_LOG."
        return 1
    fi
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
#   server lane   — root, exactly as today. No image sets USER, droste-setup.sh passes
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
# list rather than doing a group lookup. setpriv --reuid/--regid --keep-groups keeps
# the current supplementary groups untouched, so the served process gets exactly the
# group set an interactive session has. runuser/su would re-initgroups from
# /etc/group and drop GPU access.
#
# --keep-groups IS MANDATORY, not decoration: setpriv refuses to run at all when
# --regid arrives without one of --keep-groups/--clear-groups/--init-groups/--groups
# ("--[re]gid requires --keep-groups, --clear-groups, --init-groups, or --groups") —
# it insists the caller say out loud what happens to the supplementary list. Of the
# four, --keep-groups is the one that spells the paragraph above: inherit the
# container's list verbatim. Leaving it out did not merely change the group set, it
# made setpriv exit before ever exec'ing the service, so the distrobox lane's server
# door never opened in any box.
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
    printf 'setpriv\0--reuid=%s\0--regid=%s\0--keep-groups\0--\0' "$uid" "$gid"
}

# ── Launch ──────────────────────────────────────────────────────────────────
# _log_tail — copy the last few lines of the service log to stderr, one prefixed
# line each. WHY: the only thing a user ever sees of a failed start is `podman
# logs <box>`, and the reason (a python traceback, a port already bound, setpriv
# rejecting its own argv) is in the log file on the data volume — which they have
# to be told to go and read. Putting the tail directly under the error message
# makes the container log self-explanatory.
# Silent unless the log is a readable regular file: the unwritable-data-dir path in
# launch repoints DROSTE_SERVE_LOG at /dev/stderr, where the output has already
# gone and which must never be read back.
serve::_log_tail() {
    local n=${1:-10} line
    case "$DROSTE_SERVE_LOG" in /dev/*) return 0 ;; esac
    [ -f "$DROSTE_SERVE_LOG" ] && [ -r "$DROSTE_SERVE_LOG" ] || return 0
    while IFS= read -r line; do
        printf 'droste-serve:   | %s\n' "$line" >&2
    done < <(tail -n "$n" "$DROSTE_SERVE_LOG" 2>/dev/null)
    return 0
}

# launch — start SERVICE in the background, record its identity, return.
# Output goes to a log on the data volume (readable from either door and from the
# host) with ONE generation kept, because a healthcheck-triggered restart would
# otherwise erase the evidence of the crash that caused it. stdin is /dev/null:
# nothing here is interactive, and the init hook's stdin is pid 1's.
serve::launch() {
    local token=$1 prefix=() pid fields start cmd0 died=0
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
    serve::_log_note "launching: ${SERVICE[*]}"

    HOME="${HOME:-/root}" \
    USER="${DROSTE_USER:-${USER:-root}}" \
    LOGNAME="${DROSTE_USER:-${LOGNAME:-root}}" \
        ${prefix[@]+"${prefix[@]}"} "${SERVICE[@]}" \
        >>"$DROSTE_SERVE_LOG" 2>&1 </dev/null &
    pid=$!

    # Let the fork settle before believing in it. A child that is about to fail its
    # very first exec (a missing interpreter, setpriv rejecting its own argv) is
    # still a live pid for a few milliseconds, so probing /proc in the same breath
    # as the `&` reports a healthy process for something that never ran — which is
    # exactly how a dead server door got announced as "service started". A fifth of
    # a second settles that and is invisible against a container start; if this
    # sleep cannot do fractions the probe simply runs as early as it used to.
    sleep 0.2 2>/dev/null || true

    # Record identity (setpriv execs, it does not fork, so this pid is the service).
    # A service that dies instantly leaves no /proc entry — the start time then
    # records blank, which _pid_is_ours treats as "not ours", so the next run
    # relaunches instead of trusting a pid it cannot verify. It may instead be a
    # ZOMBIE, still listed but already exited (pid 1 here is distrobox-init's
    # keepalive shell, not an eager reaper); that is just as dead, and _pid_is_ours
    # rejects state Z for the same reason. Either shape means the launch failed.
    # argv[0] is written as the 4th field for humans reading the file; it is not
    # part of the identity. The status field is the healthcheck's gate: only a
    # launch we watched survive its first fifth of a second is written `running`.
    start=""
    if fields=$(serve::_proc_fields "$pid"); then
        start=${fields#* }
        [ "${fields% *}" != Z ] || died=1
    else
        died=1
    fi
    cmd0=$(basename -- "${SERVICE[0]}")
    if [ "$died" -eq 1 ]; then
        serve::_write_state failed "$pid" "${start:--}" "$token" "$cmd0"
    else
        serve::_write_state running "$pid" "${start:--}" "$token" "$cmd0"
    fi
    # Keep the log deletable by the box user too (it is on the host's data dir;
    # written here as root, which is a subuid on the host under keep-id — the
    # state record is chowned by _write_state for the same reason).
    if [ "${DROSTE_LANE:-server}" = distrobox ] && [ -n "${DROSTE_USER:-}" ]; then
        chown "$DROSTE_USER:" "$DROSTE_SERVE_LOG" 2>/dev/null || true
    fi
    # Report what actually happened. The old code announced "service started" from
    # the mere fact that a fork had returned a pid, so a service that died on its
    # first instruction left a container log claiming success and a port nobody was
    # listening on — the failure only surfaced later as an unexplained UNHEALTHY.
    # Returning non-zero here is safe for every caller: the sole one is
    # maybe_launch, which runs this behind `||` and always returns 0 itself, and
    # the init hook guards maybe_launch behind a second `||` for the same reason —
    # a broken service must never make the box hard to enter.
    if [ "$died" -eq 1 ]; then
        serve::err "the service exited immediately (pid $pid) — nothing is serving port ${SERVE_PORT:-?}. Last lines of $DROSTE_SERVE_LOG:"
        serve::_log_tail   # BEFORE the note below, so the tail shows the service's
                           # own last words rather than our summary of them.
        serve::_log_note "FAILED: the service exited immediately (pid $pid) — nothing is serving port ${SERVE_PORT:-?}."
        return 1
    fi
    serve::info "service started (pid $pid) on port ${SERVE_PORT:-?}; output: $DROSTE_SERVE_LOG"
    return 0
}

# maybe_launch — the whole server-door decision, called once per container start
# from droste-init-hook.sh (and again after every healthcheck-triggered restart).
# Never returns non-zero for a reason that should keep the box from coming up.
#
# ⭐ THE GATE IS INTENT (state/.IS_ACTIVE), NOT CONFIG (STARTUP_ENABLED). At container
# start those two agree, because the init hook calls serve::reset_active first — but
# they are not the same question, and every other caller reaches this function when
# they DISAGREE: server_start on a box whose startup is off, and the healthcheck's
# relaunch after a user ran server_stop (intent 0 ⇒ leave it down; the old code would
# have fought the user forever because server.env still said SERVE=1).
serve::maybe_launch() {
    local token
    serve::read_config
    if [ -n "${SERVE_CONFIG_ERR:-}" ]; then
        serve::warn "$SERVE_CONFIG_ERR"
        return 0
    fi
    if ! serve::is_active; then
        # Silent by design: interactive-only boxes are the common case, and this
        # runs on every single container start. No state record either — an
        # interactive-only box writes nothing into its host dirs, and the
        # healthcheck answers "healthy, nothing to probe" from the same flag
        # before it ever looks at the record.
        return 0
    fi
    if [ -z "${SERVE_PORT:-}" ]; then
        # Reachable now that intent and config can disagree: a box with
        # STARTUP_ENABLED=0 and no PORT, started by hand. read_config's own
        # startup-time check never fires for it, so say it here rather than
        # launching a service with no agreed port.
        serve::warn "${SERVE_PORT_ERR:-no usable PORT in $DROSTE_SERVE_ENV} — not serving."
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
            if ! serve::_stop_stale "$SERVE_REC_PID" "$SERVE_REC_START"; then
                # The wedged process is still alive and still not serving. Its
                # record would otherwise read `running` + a live pid, so a
                # squatter answering the port would make the box look healthy.
                serve::_not_serving failed "$token" "$SERVE_REC_PID" "$SERVE_REC_START" \
                    "a wedged service from a previous container start (pid $SERVE_REC_PID) could not be stopped — this box is not serving port $SERVE_PORT."
                return 0
            fi
        fi
    fi

    if serve::_port_busy "$SERVE_PORT"; then
        serve::_not_serving refused "$token" - - \
            "port $SERVE_PORT is already in use (host networking: another droste box or a host process?) — not starting a second listener. Change PORT in $DROSTE_SERVE_ENV or free the port, then restart the container."
        return 0
    fi

    serve::apply_port "$SERVE_PORT"
    serve::launch "$token" || serve::warn "service launch failed — the box is still usable interactively; see $DROSTE_SERVE_LOG."
    return 0
}

# ── Socket ownership: does OUR process actually hold the port? ──────────────
# The last hole in "this box is serving": gate 1 proves our recorded process is ALIVE
# and gate 2 proves SOMETHING answers the port, but neither proves they are the same
# thing. A process can be alive and not listening (its server thread died, or it never
# bound and did not exit) — and under HOST NETWORKING anything on the machine can then
# take that port and answer the probe. The box reported HEALTHY while serving nothing.
#
# 🔧 PURE PROCFS, NO NEW DEPENDENCY. `ss -tlnp` is the obvious tool and iproute2 is
# NOT installed in any of these images — adding a package to satisfy a health probe is
# a worse trade than reading the two files the kernel already exposes. /proc/net/tcp
# gives the inode of the LISTEN socket on our port; /proc/<pid>/fd tells us whether
# that inode is ours.
#
# ⚠️ THIS GATE ONLY EVER DENIES ON POSITIVE EVIDENCE. Returns:
#   0  ours          — our pid (or a descendant) holds a LISTEN socket on that port
#   1  NOT ours      — someone else holds it, and we know who does not
#   2  cannot tell   — unreadable procfs, no listener found, etc.
# The caller treats 2 as "carry on", never as a failure. A health probe that restarts
# containers must not act on an inconclusive read.
serve::_listen_rows() {  # port → "<inode> <uid>" per LISTEN socket on that port
    # The unused names are the procfs COLUMN LAYOUT, kept in full so the fields we do
    # read are provably the right ones: sl local rem st tx:rx tr:tm retrnsmt uid
    # timeout inode. Collapsing them to positional junk is how a column shift goes
    # unnoticed after a kernel format change.
    # shellcheck disable=SC2034
    local port=$1 hp f sl loc rem st txrx trtm retr uid tmo inode rest
    hp=$(printf '%04X' "$port" 2>/dev/null) || return 1
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] || continue
        # shellcheck disable=SC2034
        while read -r sl loc rem st txrx trtm retr uid tmo inode rest; do
            [ "$st" = 0A ] || continue          # 0A = TCP_LISTEN (skips the header too)
            [ "${loc##*:}" = "$hp" ] || continue
            printf '%s %s\n' "$inode" "$uid"
        done < "$f"
    done
    return 0
}

serve::_pid_holds_inode() {  # pid, inodes → 0 holds one of them, 1 no, 2 cannot read
    local pid=$1 inodes=$2 fd target ino want
    [ -d "/proc/$pid/fd" ] || return 2
    ls "/proc/$pid/fd" >/dev/null 2>&1 || return 2   # alive but not ours to inspect
    for fd in "/proc/$pid/fd"/*; do
        target=$(readlink "$fd" 2>/dev/null) || continue
        case "$target" in
            'socket:['*']') ino=${target#socket:[}; ino=${ino%]} ;;
            *) continue ;;
        esac
        for want in $inodes; do
            [ "$ino" = "$want" ] && return 0
        done
    done
    return 1
}

# port_owned_by_us — the whole check. Fast path first: our own fds, ONE directory read.
# Only when that fails do we pay for a descendant walk, because a server may hand its
# listening socket to a worker child (vllm forks; the socket is inherited, so the fd
# lives in a process whose ancestry reaches ours). That walk needs a pid→ppid map, and
# under `--pid host` /proc holds every process on the machine — which is exactly why it
# is on the rare path and not the common one.
serve::port_owned_by_us() {  # port, pid → 0 ours | 1 not ours | 2 cannot tell
    local port=$1 pid=$2 rows inodes rc p ppid depth stat ourid ino uid same
    rows=$(serve::_listen_rows "$port") || return 2
    # NOTHING LISTENING is not really "cannot tell" — under host networking the box
    # shares the netns, so an empty result means nothing in that namespace is serving,
    # and we know it. It returns 2 so the PROBE reports it, because "no HTTP response
    # (curl exit 7)" is the more actionable sentence than anything this gate would say.
    # Behaviour, not ignorance.
    [ -n "$rows" ] || return 2
    inodes=$(printf '%s\n' "$rows" | while read -r ino uid; do printf '%s\n' "$ino"; done)
    serve::_pid_holds_inode "$pid" "$inodes"; rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 2 ] && return 2
    # Not held by our pid directly. Look for a DESCENDANT that holds it.
    for p in /proc/[0-9]*; do
        p=${p#/proc/}
        serve::_pid_holds_inode "$p" "$inodes" || continue
        # p holds it — is p a descendant of our pid? Walk up its ppid chain.
        depth=0
        while [ "$p" != 1 ] && [ "$p" != 0 ] && [ -n "$p" ] && [ "$depth" -lt 32 ]; do
            [ "$p" = "$pid" ] && return 0
            stat=$(cat "/proc/$p/stat" 2>/dev/null) || break
            stat=${stat##*") "}
            # shellcheck disable=SC2086   # deliberate word split of a numeric stat line
            set -- $stat
            ppid=${2:-}
            [ -n "$ppid" ] || break
            p=$ppid
            depth=$((depth + 1))
        done
        return 1        # somebody else's process is holding our port
    done
    # ⭐ LAST EVIDENCE BEFORE GIVING UP: the socket's OWNING UID, which /proc/net/tcp
    # gave us for free in the same read. We get here when no pid could be attributed —
    # the holder's /proc/<pid>/fd is unreadable, i.e. it belongs to another user. If
    # EVERY listener on this port is owned by a different uid than our recorded
    # process, that is POSITIVE evidence the listener is not ours, so it is a denial
    # and not a shrug. Sound in this architecture because the whole service tree runs
    # as the box user: setpriv sets uid AND gid and children inherit, so our own socket
    # can only ever carry our own uid.
    # ⚠️ A uid that MATCHES proves nothing (same user, different process), so that case
    # stays "cannot tell". The residue — a same-uid squatter with an unreadable fd
    # table — is a genuine limit of procfs without privileges we do not have, not a
    # gap to be closed by being cleverer here.
    ourid=$(stat -c %u "/proc/$pid" 2>/dev/null) || ourid=""
    if [ -n "$ourid" ]; then
        same=0
        while read -r ino uid; do
            [ -n "${uid:-}" ] || continue
            [ "$uid" = "$ourid" ] && same=1
        done <<<"$rows"
        [ "$same" -eq 0 ] && return 1
    fi
    return 2            # a listener exists, same uid or unknown — genuinely unresolved
}

# ── Surgical recovery (used by droste-healthcheck.sh) ───────────────────────
# The container bounce was never the GOAL — it is the MECHANISM podman gave us for
# relaunching a dead service, because it has no "restart just the service". Killing
# every interactive shell in the box is collateral from using a sledgehammer to do a
# screwdriver's job. With --health-retries 3 at 30s there is a ~90-second window in
# which we can try the screwdriver first, and still let podman restart the container if
# it does not work. Honest reporting is preserved throughout: unhealthy is reported as
# unhealthy on every failing probe, including the one that triggers a relaunch.

# _relaunch_due — may we relaunch RIGHT NOW? The cooldown is the one non-negotiable
# part of this feature: probes fire every 30s whether or not the previous relaunch has
# finished, so without it a slow-starting service (ds4 loads up to 430 GB) would get a
# SECOND launch racing the first for the port, and the feature would spawn processes
# instead of recovering them.
# The clock is the launch record's OWN MTIME — no new file, no new format. Default
# cooldown is 120s: longer than the 30s interval, so AT MOST ONE relaunch happens
# inside a 3-retry window, which is exactly the intended shape (check #1 relaunches;
# #2 and #3 observe, and if they still fail podman bounces the container as before).
#
# ⚠️ ONE ACCEPTED IMPRECISION, stated rather than left to be rediscovered: the mtime is
# the last WRITE, which for a healthy server is its launch. So a server that dies within
# the cooldown of starting up does not get relaunched on the first failing probe — it
# waits for the age to pass 120s, possibly using up most of the retry window. That is
# the right way to be wrong: the alternative (relaunch immediately after a recent
# launch) is precisely the crash-loop that spawns processes, and the cooldown's job is
# to prevent that. A long-running server is unaffected — its record is hours old, so a
# crash relaunches on the very next probe, which is the common case this exists for.
: "${DROSTE_SERVE_RELAUNCH_COOLDOWN:=120}"
serve::_relaunch_due() {
    local age
    age=$(serve::_record_age)
    [ "$age" -ge "$DROSTE_SERVE_RELAUNCH_COOLDOWN" ]
}

# warn_ttys — tell anyone actually sitting in the box, BEFORE podman can eject them.
# Today the first thing a user learns is that they have been disconnected. Best-effort
# by construction: a tty we cannot write to is not a reason to fail a health probe.
# ⚠️ The wording distinction here is load-bearing and must survive editing: the
# relaunch sentence says SERVER, the fallback sentence says BOX — because that one
# really is the container restarting.
serve::warn_ttys() {
    local msg=$1 pts
    for pts in /dev/pts/*; do
        [ -w "$pts" ] || continue
        case "$pts" in */ptmx) continue ;; esac
        printf '\n[droste] %s\n' "$msg" > "$pts" 2>/dev/null || true
    done
    return 0
}

# build_service — turn the build-spec into a final SERVICE argv, WITHOUT re-running the
# mounts. resolve::apply_spec's steps 6+7 (source ENV_FILE, run PRE_LAUNCH) are the
# argv-finalising half; steps 1-5 are mounts, overlays and template seeding, which
# belong to the init hook and must not be repeated.
#
# 🚨 THIS LIVES HERE, NOT IN THE VERB SCRIPT, BECAUSE THE HEALTHCHECK NEEDS IT TOO.
# Found by testing, not by reading: serve::relaunch called maybe_launch -> launch, which
# hits `${#SERVICE[@]}` under `set -u` and died with `SERVICE: unbound variable` — the
# healthcheck sources this library but has no argv of its own. The relaunch could never
# have worked, and worse, it left the record stuck on `starting` so every later probe
# reported "a launch is in progress" forever. The design note that `start` is "a thin
# wrapper over maybe_launch" was true of the VERB (which builds the argv) and not of the
# PROBE. One copy, both callers.
serve::build_service() {
    local spec=${DROSTE_BUILD_SPEC:-/opt/resources/build-spec}
    [ -f "$spec" ] || { serve::err "no build-spec at $spec — cannot tell what this box's server is."; return 1; }
    SERVICE=()
    ENV_FILE=""
    PRE_LAUNCH=""
    # shellcheck disable=SC2034  # consumed by resolve::apply_spec, defined for set -u
    OVERLAYS=() SURFACES=() CRITICAL=() OPTIONAL=() CACHES=()
    # shellcheck source=/dev/null
    source "$spec" || { serve::err "could not read $spec"; return 1; }
    if [ -n "${ENV_FILE:-}" ] && [ -f "$ENV_FILE" ]; then
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
    fi
    if [ -n "${PRE_LAUNCH:-}" ]; then
        "$PRE_LAUNCH" || serve::warn "PRE_LAUNCH reported a problem; continuing with the argv as built."
    fi
    [ "${#SERVICE[@]}" -gt 0 ] || { serve::err "the build-spec defines no SERVICE."; return 1; }
    return 0
}

# relaunch — one attempt to bring the service back WITHOUT bouncing the container.
# Marks the record `starting` first so a probe arriving mid-launch can tell "a launch is
# in flight" from "nothing is running" — that is the whole reason `starting` was added
# to the existing status vocabulary rather than as a second file.
serve::relaunch() {
    serve::_log_note "RELAUNCH: the healthcheck found the service down; relaunching without restarting the container."
    # Build the argv BEFORE claiming a launch is starting: if the spec is unreadable
    # there is nothing to start, and a `starting` record we never follow through on
    # would tell every later probe that a launch is in flight forever.
    if ! serve::build_service; then
        serve::_write_state failed - - - -
        return 0
    fi
    serve::_write_state starting - - - -
    # maybe_launch re-reads the record it just found: pid "-" cannot match a live
    # process (_pid_is_ours rejects it), so it falls straight through to the port check
    # and a fresh launch — which is the intended path, not a coincidence.
    serve::maybe_launch
    # ⚠️ NEVER LEAVE `starting` BEHIND. maybe_launch has several early returns that write
    # no record at all (intent cleared mid-probe, no usable port); any of them would
    # strand the marker written above and wedge every subsequent probe on "a launch is
    # still in progress". If nothing overwrote it, the launch did not happen.
    if serve::_read_pidfile && [ "$SERVE_REC_STATUS" = starting ]; then
        serve::_write_state failed - - - -
    fi
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
