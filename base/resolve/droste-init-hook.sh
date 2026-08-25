#!/usr/bin/env bash
# droste-init-hook.sh — DISTROBOX-lane resolver invocation, for distrobox.ini
# init_hooks (see targets/<port>/distrobox.ini for per-port examples).
#
# distrobox/toolbx replace pid1, so the image ENTRYPOINT never runs there; this
# wrapper is the distrobox counterpart: it sources the same shared resolver +
# per-port build-spec and runs resolve::apply_spec with DROSTE_LANE=distrobox.
# Since lane unification the hook performs the SAME mounts as the server lane —
# overlays (the venv upper on /opt/program-cache, the custom-node upper on
# /opt/data), surfaces, cache binds — so container-lifecycle events never destroy
# in-box state (the founding requirement). Order is apply_spec's:
# ensure_data + ensure_pcache → surfaces/overlays/caches →
# CRITICAL binds (checked AFTER the mounts; declare them as volume= lines in
# distrobox.ini — the HF cache is satisfied by the auto-bound real home) →
# OPTIONAL marker → templates.yaml seeding → ENV_FILE source → PRE_LAUNCH.
# No exec — pid1 is distrobox-init, which `eval`s this hook once per container
# start and then goes into its keepalive loop. In-box mounting needs
# CAP_SYS_ADMIN + /dev/fuse: additional_flags="--cap-add sys_admin --device
# /dev/fuse" in the ini.
# Idempotent: init_hooks run on every container start; every resolver mount
# skips when its exact target is already a mountpoint.
#
# THE SERVER DOOR (merged-container shape): after the spec is applied, the hook
# asks droste-serve.sh whether this start should also bring the box's SERVICE up
# — the answer lives in server.env on the per-box data volume (SERVE=1, PORT=…),
# not in this file and not in the container's baked env, so it is editable and
# survives recreates. Nothing happens without that file, so an interactive-only
# box behaves exactly as it did before. `podman start` replaying the init line is
# what makes this the "server door"; podman's healthcheck restarting the
# container is what supervises it (see droste-healthcheck.sh).
set -euo pipefail

export DROSTE_LANE=distrobox

# init_hooks run as root (HOME=/root), but the spec's $HOME-relative paths must
# resolve to the DISTROBOX USER's home (the host-home bind — that is what makes
# e.g. the HF-cache CRITICAL read as bound). Derive user + home from the first
# regular user distrobox created (uid >= 1000); DROSTE_USER / DROSTE_USER_HOME
# override. Both are EXPORTED for the resolver's lane deviations: it remaps
# /root/-prefixed SURFACE/CACHE dests to $DROSTE_USER_HOME and chowns the dirs
# it creates to $DROSTE_USER (this hook runs as root; the box user is not).
if [ -z "${DROSTE_USER:-}" ]; then
    DROSTE_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }' /etc/passwd)
fi
if [ -z "${DROSTE_USER_HOME:-}" ]; then
    DROSTE_USER_HOME=$(awk -F: '$3 >= 1000 && $3 < 65534 { print $6; exit }' /etc/passwd)
fi
export DROSTE_USER DROSTE_USER_HOME
if [ -n "${DROSTE_USER_HOME:-}" ]; then
    export HOME="$DROSTE_USER_HOME"
fi

# NO GROUP GRANT HERE — it cannot work, and the `usermod -aG droste` that used to
# live at this spot was dead code. Writability of the baked venv/custom_nodes is
# handled by ownership instead, in resolve::_own_dirs (chowns DIRECTORIES ONLY to
# the box user right after each overlay mounts).
# Measured on hardware (gfx1151, rootless podman + crun, 2026-08-08), both delivery
# routes fail:
#   1. usermod here DOES write /etc/group (getent in-box shows the membership), but
#      no session ever picks it up — `podman exec` sets uid/gid + keep-groups and
#      never does a supplementary-group lookup. Every distrobox enter is a podman
#      exec, so `id` never lists the group. Not an ordering race: a second enter is
#      identical, and by-name (`--user jjb`) behaves the same as numeric.
#   2. Create-time `--group-add droste` in the ini's additional_flags is accepted
#      (podman inspect reports groupadd=[droste]) but is swallowed by crun's
#      `keep-groups`: the gid never appears, not even for the container's own root
#      process. Only `podman exec --user <user>:droste` delivers it, and distrobox
#      exposes no exec-time flag in distrobox.ini.
# Rootless userns additionally blocks gaining the group at runtime (`sg`/`newgrp`
# fail with EPERM), so there is no in-shell recovery either.

RESOLVE_DIR=${RESOLVE_DIR:-/opt/resources/resolve}
# shellcheck source=/dev/null
source "$RESOLVE_DIR/droste-resolve.sh"
# shellcheck source=/dev/null
source "$RESOLVE_DIR/droste-serve.sh"

SPEC=${DROSTE_BUILD_SPEC:-/opt/resources/build-spec}
if [ ! -f "$SPEC" ]; then
    resolve::err "build-spec not found at $SPEC"
    exit 1
fi

# Row defaults BEFORE sourcing the spec (set -u safety; spec may omit any row).
SERVICE=()
ENV_FILE=""
OVERLAYS=()
SURFACES=()
CRITICAL=()
OPTIONAL=()
CACHES=()
PRE_LAUNCH=""

# shellcheck source=/dev/null
source "$SPEC"

# Surface resolver diagnostics. distrobox shows only a generic "An error occurred"
# for a failed init hook, hiding the resolver's actionable CRITICAL message. That
# failure often arrives as an internal `exit 1` from resolve::critical (sourced,
# runs in THIS shell), so we catch it with an EXIT trap — not `|| rc=$?`, which the
# direct exit bypasses — and write stderr to a log SYNCHRONOUSLY (a backgrounded
# tee could be killed mid-flush by that exit, truncating the log).
# DATA class, deliberately, and beside .droste-serve.log: it is small, and it is
# wanted exactly when a start went wrong — which is not a moment to have thrown it
# away with the program caches.
RESOLVE_LOG="${DROSTE_DATA_DIR:-/opt/data}/.droste-resolve.log"
# Fall back to /tmp if the data dir isn't writable (ro bind, missing, etc.) so the
# redirect itself can never abort the hook.
if ! ( : >>"$RESOLVE_LOG" ) 2>/dev/null; then
    RESOLVE_LOG="/tmp/droste-resolve.log"
fi
# Hand the log to the box user, exactly as droste-serve.sh does with its own log and
# state record, and for the same reason: this hook is root, which under keep-id is a
# host subuid, so a root-created log on the user's data dir is one they can read but
# not rotate or delete. No lane test — this file IS the distrobox lane. Unconditional
# rather than create-only: it also reclaims the root-owned logs earlier starts left
# behind. Best-effort (`|| true`): a log we could not chown must never abort a start.
if [ -n "${DROSTE_USER:-}" ]; then
    chown "$DROSTE_USER:" "$RESOLVE_LOG" 2>/dev/null || true
fi
# ── Server intent + "a launch is coming", BOTH BEFORE THE MOUNTS (s47) ──────
# 🚨 RESET INTENT FIRST, AND THIS CALL IS NOT OPTIONAL. state/.IS_ACTIVE means "a server
# should be running right now"; it is defined to be reset from STARTUP_ENABLED at every
# container start — but /opt/program-cache is a HOST directory that survives container
# restarts, so NOTHING RESETS IT BY ITSELF. This line is the entire enforcement. Remove
# it and a `server_stop` becomes permanent and silent, which is the exact class of bug
# the two-setting split was built to remove.
# ⚙️ It MOVED ABOVE apply_spec in s47 (it used to sit beside maybe_launch): it reads
# server.env and writes the state dir, both on volumes podman binds at container start,
# so it never needed the mounts — and the stamp below needs to know the intent.
serve::reset_active || serve::warn "could not reset the server intent flag — continuing."

# ⭐ THEN SAY A LAUNCH IS COMING — BEFORE apply_spec, WHICH IS THE WHOLE FIX.
# apply_spec does the mounts, the overlays AND the model-tree scan; on a box with no
# registry yet that scan runs for minutes, and the launch cannot happen until it ends.
# podman is already probing throughout. With NO record at all, the probe read the box as
# "the door was asked to serve and did not" and produced three wrong things at once:
# UNHEALTHY, a warning on every tty saying the server had DIED, and a relaunch attempt
# that could start the service before its own overlays were mounted.
# `starting` is the status that already means "a launch is in flight, do not retry it"
# (serve::state_ok), and serve::_relaunch_due measures its cooldown from THIS record's
# own mtime — so one stamp answers all three, adds no new file and no new format.
# Only for a box that intends to serve: an interactive-only box writes nothing into its
# host dirs, and the probe answers "nothing to probe" from .IS_ACTIVE before it ever
# looks at the record.
if serve::is_active; then
    serve::_write_state starting - - - - || :
fi

# ⚠️ NEVER LEAVE `starting` BEHIND — the same invariant serve::relaunch keeps, and it
# has to hold here too now that the stamp above can outlive its launch. If apply_spec
# fails, maybe_launch never runs, and the stranded marker would tell every later probe
# that a launch is in flight forever — turning a loud mount failure into a box that
# looks permanently mid-start.
hook::seal_state() {
    serve::is_active || return 0
    serve::_read_pidfile || return 0
    [ "${SERVE_REC_STATUS:-}" = starting ] || return 0
    serve::_write_state failed - - - - || :
    return 0
}

# ── Keep the stamp ALIVE while apply_spec works (s48) ───────────────────────
# 🚨 A STAMP IS A TIMESTAMP, AND A TIMESTAMP GOES STALE WHILE THE WORK IT DESCRIBES IS
# STILL GOING ON. serve::_relaunch_due measures the relaunch cooldown from this record's
# own mtime, and NOTHING between the stamp above and the server door below writes the
# record again — so an apply_spec that outlasts DROSTE_SERVE_RELAUNCH_COOLDOWN (120s)
# let the probe conclude the launch was stuck and relaunch the service into a
# HALF-MOUNTED BOX. That is the very hole the stamp exists to close, and a FRESH INSTALL
# walks straight into it: the model-tree scan runs for minutes on a box with no registry
# yet, which is exactly the box a first start has.
# The fix is a heartbeat rather than a bigger cooldown, because the number was never
# wrong — the clock was. See serve::heartbeat_starting for the other half.
#
# ⚠️ IT MUST NOT MAKE A WEDGED HOOK IMMORTAL, and the two guards below are that promise:
#   * it stops the moment the working process is gone, so a hook killed without running
#     its EXIT trap leaves the record to go stale and the stale-`starting` relaunch
#     recovers it — the behaviour g1lab/initstamp.sh checks 19-20 pin down, and the
#     reason "never relaunch while the status says starting" was rejected as the fix;
#   * it stops after HOOK_HEARTBEAT_MAX beats regardless, so a recycled pid cannot keep
#     a dead launch looking alive for the life of the container.
# A hook wedged INSIDE apply_spec does keep beating, and that is DELIBERATE rather than
# an oversight: a relaunch cannot fix a mount that never returned — droste-healthcheck.sh
# says so itself ("if the failure is CAUSED by a broken mount, relaunching the service
# cannot fix it") — it can only start the service without one, which is the corruption
# this whole block exists to prevent. Recovery for that case is podman's container
# bounce, which is driven by the probe's EXIT CODE and is untouched by any of this: the
# probe still reports UNHEALTHY on every beat, so the retry counter still advances.
# ⚙️ $BASHPID, not $$: they are the same in production (the hook is sourced by the shell
# that then runs apply_spec) but differ inside a subshell, where $$ stays the outer
# shell's pid — a heartbeat that outlives its work is the one thing this must not be.
: "${HOOK_HEARTBEAT_INTERVAL:=30}"   # seconds between beats (the probe's own interval)
: "${HOOK_HEARTBEAT_MAX:=240}"       # hard cap; 240 × 30s = 2h, past every start period
HEARTBEAT_PID=""

hook::heartbeat() {  # <pid of the working process>
    local parent=$1 beats=0
    while [ "$beats" -lt "$HOOK_HEARTBEAT_MAX" ]; do
        sleep "$HOOK_HEARTBEAT_INTERVAL"
        kill -0 "$parent" 2>/dev/null || return 0   # the work is gone; let it go stale
        serve::heartbeat_starting || return 0       # the launch has an owner again
        beats=$((beats + 1))
    done
    return 0
}

hook::stop_heartbeat() {
    [ -n "$HEARTBEAT_PID" ] || return 0
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=""
    return 0
}

# On ANY non-zero exit (including resolve::critical's internal exit 1) seal the launch
# record and dump the log to stderr with a pointer; on success this is a no-op.
# ⚙️ The heartbeat is stopped on EVERY exit, not only the failing one — it is the one
# thing here that outlives the shell if nobody reaps it.
trap 'ec=$?; hook::stop_heartbeat || :; if [ "$ec" -ne 0 ]; then hook::seal_state || :; { printf "droste-init-hook: resolver FAILED (exit %s). Detail (also saved to %s):\n" "$ec" "$RESOLVE_LOG"; tail -n 30 "$RESOLVE_LOG" 2>/dev/null; } >&2; fi' EXIT
# ⚙️ FDS DETACHED, DELIBERATELY. A background child inherits the init line's stdout, and
# anything holding that pipe open holds up whoever is reading it — distrobox-init here,
# and a `$(...)` around the hook in g1lab/initstamp.sh. The heartbeat prints nothing by
# design, so it has no use for them.
if serve::is_active; then
    hook::heartbeat "$BASHPID" >/dev/null 2>&1 </dev/null &
    HEARTBEAT_PID=$!
fi
resolve::apply_spec 2>"$RESOLVE_LOG"
hook::stop_heartbeat
# Success path: surface the resolver's own INFO/WARN lines (fuse fallback, etc.) too.
cat "$RESOLVE_LOG" >&2

# ── Server door ─────────────────────────────────────────────────────────────
# MUST come after apply_spec: SERVICE is only final once ENV_FILE is sourced and
# PRE_LAUNCH has run (llama/ds4/vllm rebuild the argv there). Deliberately NOT
# guarded by the resolver's log/trap plumbing and deliberately `|| true`: a serve
# problem must never fail the init hook — distrobox reports a failed hook as a
# generic error and the box would become hard to enter, which is the opposite of
# what we want when the service is the broken part. maybe_launch says nothing at
# all unless server.env turns serving on.
# ⚙️ THE INTENT RESET AND THE `starting` STAMP RUN ABOVE, BEFORE apply_spec (s47) — see
# the block there for why. maybe_launch re-reads the record this start already wrote:
# its pid field is "-", which _pid_is_ours rejects, so it falls straight through to the
# port check and a fresh launch. That is the same path serve::relaunch takes, and it is
# intended rather than incidental.
serve::maybe_launch || serve::warn "serve step failed (exit $?) — the box is still usable interactively."
