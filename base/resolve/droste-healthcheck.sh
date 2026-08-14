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
# PORT), then curl the box's endpoint (build-spec rows HEALTH_PATH/HEALTH_ACCEPT)
# on 127.0.0.1 — the container shares the host network namespace, so the service's
# real port is reachable from inside. Exit 0 = healthy, non-zero = unhealthy.
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
        printf 'droste-healthcheck: healthy — %s answered %s.\n' "$url" "$code"
        exit 0
        ;;
    *)
        if [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
            printf 'droste-healthcheck: healthy — %s answered %s.\n' "$url" "$code"
            exit 0
        fi
        printf 'droste-healthcheck: UNHEALTHY — %s answered %s.\n' "$url" "$code"
        exit 1
        ;;
esac
