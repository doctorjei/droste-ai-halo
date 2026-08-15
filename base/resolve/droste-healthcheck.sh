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
# What it does: read the SAME serve config the init hook reads (server.env: SERVE,
# PORT), then require BOTH halves of "this box is serving":
#
#   1. OUR SERVICE IS RUNNING — the state record droste-serve.sh writes at every
#      container start says the launch succeeded, and that exact process (pid +
#      process start time) is still alive. serve::state_ok.
#   2. IT ANSWERS — curl the box's endpoint (build-spec rows HEALTH_PATH /
#      HEALTH_ACCEPT) on 127.0.0.1; the container shares the host network
#      namespace, so the service's real port is reachable from inside.
#
# Exit 0 = healthy, non-zero = unhealthy.
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
# also never reads server.env, so SERVE stays 0 there and this script exits at the
# gate below without ever consulting the record. (droste-setup.sh wires these
# health flags for the merged/distrobox shape only.)
#
# A box that is NOT configured to serve is HEALTHY BY DEFINITION (exit 0): the
# healthcheck flags may be baked into a container the user later turns serving off
# on, and an interactive-only box must not restart-loop because nothing is
# listening. Same for an unreadable/malformed server.env — the init hook already
# warned about it in the container log.
set -uo pipefail

RESOLVE_DIR=${RESOLVE_DIR:-/opt/resources/resolve}
# shellcheck source=/dev/null
source "$RESOLVE_DIR/droste-serve.sh"
set +e   # this script decides its own exit codes

: "${DROSTE_HEALTH_TIMEOUT:=5}"

serve::read_config
if [ "${SERVE_ENABLED:-0}" -ne 1 ]; then
    printf 'droste-healthcheck: serving is off (%s) — nothing to probe.\n' "$DROSTE_SERVE_ENV"
    exit 0
fi

# Gate 1 — is OUR launch alive? Checked BEFORE the probe: it is a file read plus a
# /proc read (no network, no timeout), and it is the gate that can tell a refusal
# apart from a healthy server. Note that a box with SERVE=0 exited above, so a
# missing state record here means the door was asked to serve and did not.
if ! serve::state_ok; then
    printf 'droste-healthcheck: UNHEALTHY — %s\n' "$SERVE_STATE_MSG"
    exit 1
fi

serve::read_health_spec

url="http://127.0.0.1:${SERVE_PORT}${HEALTH_PATH}"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$DROSTE_HEALTH_TIMEOUT" "$url" 2>/dev/null)
rc=$?

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
