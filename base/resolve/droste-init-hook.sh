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
# On ANY non-zero exit (including resolve::critical's internal exit 1) dump the log
# to stderr with a pointer; on success this is a no-op.
trap 'ec=$?; if [ "$ec" -ne 0 ]; then { printf "droste-init-hook: resolver FAILED (exit %s). Detail (also saved to %s):\n" "$ec" "$RESOLVE_LOG"; tail -n 30 "$RESOLVE_LOG" 2>/dev/null; } >&2; fi' EXIT
resolve::apply_spec 2>"$RESOLVE_LOG"
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
# 🚨 RESET INTENT FIRST, AND THIS CALL IS NOT OPTIONAL. state/.IS_ACTIVE means "a server
# should be running right now"; it is defined to be reset from STARTUP_ENABLED at every
# container start — but /opt/program-cache is a HOST directory that survives container
# restarts, so NOTHING RESETS IT BY ITSELF. This line is the entire enforcement. Remove
# it and a `server_stop` becomes permanent and silent, which is the exact class of bug
# the two-setting split was built to remove.
serve::reset_active || serve::warn "could not reset the server intent flag — continuing."
serve::maybe_launch || serve::warn "serve step failed (exit $?) — the box is still usable interactively."
