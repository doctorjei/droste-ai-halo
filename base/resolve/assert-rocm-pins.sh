#!/usr/bin/env bash
# assert-rocm-pins.sh — fail the BUILD if the ROCm stack is not exactly the pin.
#
# WHY THIS EXISTS. Every other guard in this tree PREVENTS the ROCm torch from
# being replaced: install ordering, the absence of -U, and the constraints file
# wired into PIP_CONSTRAINT/UV_CONSTRAINT/UV_BUILD_CONSTRAINT. This one CATCHES
# it, whatever installer, flag, node or transitive dependency did the replacing.
# It is the only check that survives a guard we forgot to apply.
#
# The failure it exists for is the worst one this project has, precisely because
# it is quiet: a generic PyPI torch replaces the ROCm build, the image still
# builds, the container still starts, the service still answers — and there is
# no GPU. Nothing in CI notices, because everything "works".
#
# Run it AFTER any layer that installs or re-pins part of the stack:
#   base/Container.torch      after the torch install (the source of truth)
#   targets/Container.comfyui after the torchvision/torchaudio pin
#   targets/Container.vllm    after its --force-reinstall torchvision re-pin
#
# Usage: assert-rocm-pins.sh [package ...]        (default: all three)
# Named packages MUST be installed and MUST match. Absent is a failure, not a
# skip: "torch is gone" is as broken as "torch is wrong", and the caller always
# knows which packages its own layer is supposed to have.
set -euo pipefail

PINS=/etc/droste/rocm-version.env
[ -r "$PINS" ] || { printf 'assert-rocm-pins: %s not readable\n' "$PINS" >&2; exit 1; }
# shellcheck disable=SC1090
. "$PINS"

want_for() {
    case "$1" in
        torch)       printf '%s' "${TORCH_VERSION:-}" ;;
        torchvision) printf '%s' "${TORCHVISION_VERSION:-}" ;;
        torchaudio)  printf '%s' "${TORCHAUDIO_VERSION:-}" ;;
        *)           printf '' ;;
    esac
}

installed_for() {
    python3 - "$1" <<'PY' 2>/dev/null || true
import sys
try:
    import importlib.metadata as m
    print(m.version(sys.argv[1]))
except Exception:
    pass
PY
}

[ "$#" -gt 0 ] || set -- torch torchvision torchaudio
rc=0
for pkg in "$@"; do
    want=$(want_for "$pkg")
    if [ -z "$want" ]; then
        printf 'assert-rocm-pins: no pin recorded for %s in %s\n' "$pkg" "$PINS" >&2
        rc=1
        continue
    fi
    got=$(installed_for "$pkg")
    if [ -z "$got" ]; then
        printf 'assert-rocm-pins: FAIL %s is NOT INSTALLED (pin: %s)\n' "$pkg" "$want" >&2
        rc=1
    elif [ "$got" != "$want" ]; then
        printf 'assert-rocm-pins: FAIL %s is %s, pin is %s\n' "$pkg" "$got" "$want" >&2
        printf 'assert-rocm-pins:      something replaced the ROCm build. A wheel\n' >&2
        printf 'assert-rocm-pins:      without +rocm is a CPU/CUDA build: no GPU.\n' >&2
        rc=1
    else
        printf 'assert-rocm-pins: ok   %s %s\n' "$pkg" "$got"
    fi
done
exit "$rc"
