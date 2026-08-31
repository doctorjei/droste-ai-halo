#!/usr/bin/env bash
# droste-healthcheck.sh — the container-side probe for podman's healthcheck.
#
# Baked at /opt/resources/resolve/ (on PATH) in every port. droste-setup.sh wires it
# at container-create time in the MERGED shape:
#
#   --health-cmd /opt/resources/resolve/droste-healthcheck.sh
#   --health-interval 30s --health-retries 3
#   --health-start-period <generous>      # SEE THE WARNING BELOW
#   --health-on-failure=restart           # podman >= 4.2 (Raiju runs 4.9.3)
#
# ⚠️ START PERIOD IS NOT OPTIONAL. These services load multi-GB (ds4: up to
# 430 GB) model files before they answer anything, and llama-server answers
# /health with 503 while it loads. With --health-on-failure=restart and a short
# start period the container restarts itself forever and never finishes loading.
#
# What it does: read the SAME serve settings the init hook reads — the box's
# DROSTE_<APP>_STARTUP_ENABLED / _HOST / _PORT, which live in its own <app>.cfg
# beside every other setting the user edits — then require BOTH halves of "this box
# is serving":
#
#   1. OUR SERVICE IS RUNNING — the state record droste-serve.sh writes at every
#      container start says the launch succeeded, and that exact process (pid +
#      process start time) is still alive. serve::state_ok.
#   2. IT ANSWERS — curl the box's endpoint (build-spec rows HEALTH_PATH /
#      HEALTH_ACCEPT) at the address the server BINDS (serve::probe_addr: the
#      configured HOST, or 127.0.0.1 when that is the 0.0.0.0 wildcard); the
#      container shares the host network namespace, so the service's real port is
#      reachable from inside.
#
# ⚠️ THE PROBE ADDRESS IS NOT A CONSTANT ANY MORE, and the literal it replaced was a
# restart loop waiting to happen: the moment a user binds their server to a specific
# address, a probe still asking 127.0.0.1 gets nothing, reports UNHEALTHY forever and
# --health-on-failure=restart bounces the container on a server that is working
# perfectly. serve::probe_addr is the ONE place that rule lives.
#
# Exit 0 = healthy, non-zero = unhealthy.
#
# 🚨 THOSE SETTINGS ARE PARSED, NEVER SOURCED (droste::cfg_get, droste-cfg.sh), and
# for this file that is a safety property rather than a style choice. <app>.cfg is
# several hundred lines of the USER's own settings; this probe fires every 30s; and
# --health-on-failure=restart turns any abort in it into a container restart loop
# that ejects every interactive shell in the box. A typo in their own config file
# must never be able to do that.
#
# ⚠️ GATE 1 IS NOT REDUNDANT. These boxes use HOST networking, so the port is not
# ours by construction: when the server door finds the port already taken it
# refuses to start a second listener, and the SQUATTER's reply satisfied gate 2 on
# its own. The box then reported HEALTHY while serving nothing — a worse failure
# than being unhealthy, because the user believed their server was up. The state
# record is what makes the difference between "something answered" and "our
# service answered". Refusal, an instant crash, or a service that has since died
# are all UNHEALTHY no matter what holds the port.
#
# Gate 2's semantics are untouched by gate 1 (per-box endpoint/accept tuning and
# the generous start periods are deliberate, and llama's 503-while-loading is
# still what it always was).
#
# The state record is the DISTROBOX-lane server door's (serve::maybe_launch): the
# foreground server lane execs its service as pid 1 and writes no record — but it
# also never reads the serve settings and never sets the intent flag, so this script
# exits at the gate below without ever consulting the record. (droste-setup.sh wires
# these health flags for the merged/distrobox shape only.)
#
# A box that is NOT configured to serve is HEALTHY BY DEFINITION (exit 0): the
# healthcheck flags may be baked into a container the user later turns serving off
# on, and an interactive-only box must not restart-loop because nothing is
# listening. Same for a missing or unreadable <app>.cfg, and for serve settings it
# cannot make sense of — the init hook already warned about that in the container
# log, and warning again every 30s would only train the log to be ignored.
set -uo pipefail

RESOLVE_DIR=${RESOLVE_DIR:-/opt/resources/resolve}
# shellcheck source=/dev/null
source "$RESOLVE_DIR/droste-serve.sh"
set +e   # this script decides its own exit codes

: "${DROSTE_HEALTH_TIMEOUT:=5}"

serve::read_config
# ⭐ GATE 0 IS INTENT, NOT CONFIG (s45), AND THAT SUBSTITUTION IS THE WHOLE FIX.
# This used to read the box's "serve at box start" setting straight out of its config
# and therefore asked "is this box configured to serve AT BOOT?" when the question it
# needs is "is this box supposed to be serving RIGHT NOW?". Because of that, a user who
# stopped the service by hand got the container restarted under them forever — the
# config still said to start the server with the box, so every probe read the box as
# one that ought to be serving and podman bounced it.
# state/.IS_ACTIVE answers the question actually being asked, and it is reset from
# STARTUP_ENABLED at every container start, so "stopped" stays temporary.
if ! serve::is_active; then
    printf 'droste-healthcheck: no server is wanted right now (%s) — nothing to probe.\n' \
        "$DROSTE_SERVE_ACTIVE"
    exit 0
fi

# Gate 1 — is OUR launch alive? Checked BEFORE the probe: it is a file read plus a
# /proc read (no network, no timeout), and it is the gate that can tell a refusal
# apart from a healthy server. A box that wants no server exited above, so a missing
# state record here means the door was asked to serve and did not.
#
# ⭐ FAILING GATE 1 IS WHERE THE SURGICAL RECOVERY HAPPENS. Rather than reporting
# unhealthy and letting podman's --health-on-failure=restart bounce the whole container
# (killing every interactive shell in it), try to relaunch just the SERVICE, once,
# inside the ~90s that --health-retries 3 at 30s gives us. The probe still reports
# UNHEALTHY — honestly — and if the relaunch worked the next probe reports healthy and
# podman never restarts anything. If it did not, the third failure bounces the container
# exactly as it does today.
# ⚠️ THE FALLBACK IS LOAD-BEARING, NOT DECORATIVE: a container bounce also re-runs the
# init hook — mounts, model-tree scan, template seeding. If the failure is CAUSED by a
# broken mount, relaunching the service cannot fix it and it will correctly fail all
# three checks. Do not remove the bounce thinking the relaunch replaces it.
if ! serve::state_ok; then
    if serve::_relaunch_due; then
        serve::warn_ttys "the server died. Relaunching it now.
        If that fails, this box will restart in ~60s and your shell will close."
        serve::relaunch
    fi
    printf 'droste-healthcheck: UNHEALTHY — %s\n' "$SERVE_STATE_MSG"
    exit 1
fi

# Gate 1b — is the thing LISTENING on that port actually ours? (s45, board item
# "11-residual".) Gates 1 and 2 together still had a hole: our process alive + something
# answering the port is NOT the same as our process serving. Under host networking a
# process that is alive but no longer listening leaves the port free for anything on the
# machine to take, and the squatter's reply satisfied the probe — HEALTHY while serving
# nothing, which is the worse failure because the user believes their server is up.
# ⚠️ Only a POSITIVE identification of someone else fails here; "cannot tell" carries on
# to the probe exactly as before. A health probe that restarts containers must never act
# on an inconclusive read of procfs.
serve::port_owned_by_us "$SERVE_PORT" "$SERVE_REC_PID"
case $? in
    1)  printf 'droste-healthcheck: UNHEALTHY — our service (pid %s) is alive but is NOT the process listening on port %s; something else holds it. See %s.\n' \
            "$SERVE_REC_PID" "$SERVE_PORT" "$DROSTE_SERVE_LOG"
        exit 1
        ;;
esac

serve::read_health_spec

# serve::probe speaks whichever scheme this box's server answers (see the block above
# serve::probe in droste-serve.sh) and passes -k, so a TLS box with the self-signed
# cert that a local box normally has is probed correctly instead of failing cert
# verification. Without both halves a TLS box read UNHEALTHY forever and
# --health-on-failure=restart turned that into a restart loop.
code=$(serve::probe "$SERVE_PORT" "$HEALTH_PATH" "$DROSTE_HEALTH_TIMEOUT")
rc=$?
# ⚠️ REBUILT HERE FOR THE MESSAGES ONLY — serve::probe builds its own URL from these
# same two helpers, so a message naming a different address than the one actually asked
# would be worse than no message at all. Keep them in step; never inline either rule.
url="$(serve::probe_scheme)://$(serve::probe_addr):${SERVE_PORT}${HEALTH_PATH}"

# curl could not get an HTTP response at all (refused, timeout, reset): 000.
if [ -z "$code" ] || [ "$code" = "000" ]; then
    printf 'droste-healthcheck: UNHEALTHY — no HTTP response from %s (curl exit %s).\n' "$url" "$rc"
    exit 1
fi

case "$HEALTH_ACCEPT" in
    any)
        # "any HTTP response proves the server is up" (jupyter: / redirects to
        # /login, and API paths 403 without the token — all of them mean alive).
        printf 'droste-healthcheck: healthy — our service (pid %s) answered %s with %s.\n' "$SERVE_REC_PID" "$url" "$code"
        exit 0
        ;;
    *)
        if [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
            printf 'droste-healthcheck: healthy — our service (pid %s) answered %s with %s.\n' "$SERVE_REC_PID" "$url" "$code"
            exit 0
        fi
        printf 'droste-healthcheck: UNHEALTHY — %s answered %s.\n' "$url" "$code"
        exit 1
        ;;
esac
