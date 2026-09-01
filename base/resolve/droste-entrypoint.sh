#!/usr/bin/env bash
# droste-entrypoint.sh — shared SERVER-lane ENTRYPOINT for all 5 ports.
#
# Ports opt in with `ENTRYPOINT ["droste-entrypoint.sh"]` (on PATH) or the absolute
# path. It sources the per-port /opt/resources/build-spec, runs the resolver in the
# EXACT design order (resolve::apply_spec), then execs the service.
#
# This entrypoint only ever runs in the SERVER lane — distrobox/toolbx replace pid1 and
# bypass it, calling the resolver library directly from init_hooks (lane=distrobox).
#
# Standard entrypoint convention: if the user supplies a command
# (`podman run IMAGE bash`), exec THAT after resolving; otherwise exec SERVICE.
# NOTE: the CRITICAL checks still run first, so a quick UNBOUND shell needs
# `-e ALLOW_EPHEMERAL=1` — without it, no binds means a hard-error before exec.
set -euo pipefail

RESOLVE_DIR=${RESOLVE_DIR:-/opt/resources/resolve}
# shellcheck source=/dev/null
source "$RESOLVE_DIR/droste-resolve.sh"
# The shared launch path (serve::exec_service below). Sourcing it is inert: the
# library only defines functions + defaults, reads no config, and NOTHING in the
# server lane consults the box's serve settings: this file calls no
# serve::read_config and no serve::maybe_launch, so the port / address / TLS
# application that lives behind that door never runs here. The operator of a direct
# run chose the address and port on their own command line, so overriding either from
# a config file would break exactly the deployments this image still has to serve.
# droste ships no published-port definition of its own.
# ⚠️ THAT IS A DELIBERATE ASYMMETRY WITH THE INIT HOOK, not an omission: the serve
# settings are the MERGED shape's supervision surface (they are what the healthcheck
# and the server verbs act on), and this lane has neither.
# ⚠️ WHAT DOES REACH THIS LANE IS THE SPEC'S OWN WORK — apply_spec below sources
# CFG_FILE and runs PRE_LAUNCH in BOTH lanes, so whatever a box's PRE_LAUNCH builds
# into SERVICE applies to a direct `podman run` too. "The server lane ignores the
# config file" has never been true of that half, and it is worth knowing which half
# you are looking at before calling a difference between the lanes a bug.
# shellcheck source=/dev/null
source "$RESOLVE_DIR/droste-serve.sh"

SPEC=${DROSTE_BUILD_SPEC:-/opt/resources/build-spec}
if [ ! -f "$SPEC" ]; then
    resolve::err "build-spec not found at $SPEC"
    exit 1
fi

# Row defaults BEFORE sourcing the spec (set -u safety; spec may omit any row).
SERVICE=()
CFG_FILE=""
OVERLAYS=()
SURFACES=()
CRITICAL=()
OPTIONAL=()
CACHES=()
DOWNLOAD_WATCH=()
PRE_LAUNCH=""

# shellcheck source=/dev/null
source "$SPEC"

export DROSTE_LANE=server
resolve::apply_spec

# ── The download watcher (N24) ──────────────────────────────────────────────
# AFTER apply_spec because R8's off switch lives in the box's <box>.cfg, which
# apply_spec's step 6 is what applies — see the long note at the same site in
# droste-init-hook.sh; this is the same three lines with the same guarantees.
# ⚙️ AND BEFORE THE USER-COMMAND exec BELOW, deliberately: `podman run IMAGE bash`
# replaces this shell, so a launch placed after it would never happen for the one
# lane where a human is most likely to type `hf download` by hand — which is the
# case (ds4's, §1.3) that a server-oriented design misses entirely.
# ⚠️ Here fd 9 lands on the container log by the shortest possible route: this
# process IS pid 1 in the server lane, so /proc/1/fd/2 and a bare 9>&2 are the same
# file description and either arm is correct.
# shellcheck source=/dev/null
if source "$RESOLVE_DIR/droste-dlwatch.sh"; then
    dlwatch::launch || serve::warn "download watcher: did not start — downloads will not be announced. The container is unaffected."
else
    serve::warn "download watcher: could not load $RESOLVE_DIR/droste-dlwatch.sh — downloads will not be announced. The container is unaffected."
fi

# User-supplied command wins (keeps `podman run -it IMAGE bash` working).
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

if [ ${#SERVICE[@]} -eq 0 ]; then
    resolve::err "no SERVICE defined in $SPEC and no command was given"
    exit 1
fi

# Same argv, same lane semantics as the inline `exec "${SERVICE[@]}"` this
# replaced — routed through the shared launch path so both doors (this
# foreground exec and the init hook's background launch) run the service one way.
serve::exec_service
