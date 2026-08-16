#!/usr/bin/env bash
# Detect and export ROCm toolchain paths from the _rocm_sdk_core package
#
# Sourced from BOTH lanes: /etc/profile.d/ on every interactive login (and again
# from 99-toolbox-banner.sh, which loads this file itself), and — in the server
# lane, which has no login shell — from the build-spec's PRE_LAUNCH. Two rules
# follow from that, and breaking the first one already shipped a silent bug:
#
#   1) NEVER resolve the interpreter through PATH. Debian's /etc/profile REBUILDS
#      PATH before it runs profile.d/, so at this point a bare `python3` is
#      /usr/bin/python3, which has no _rocm_sdk_core. /opt/venv/bin is only put
#      back afterwards, by rocm.sh's `activate` and zz-venv-last.sh's
#      PROMPT_COMMAND — both sort after this file. The import raised, the `eval`
#      that consumed the probe got an empty string, and all three exports simply
#      never happened for the entire interactive lane, while the server lane
#      (whose PATH is the image's ENV, venv first) kept working. Call the venv
#      interpreter by absolute path, as 99-toolbox-banner.sh's rocm_version()
#      already does.
#
#   2) NEVER fail hard — and NEVER fail quietly. A non-zero status from here
#      would kill the login shell in one lane and abort the resolver (which runs
#      under `set -euo pipefail`) in the other, so every step below is
#      status-guarded and unset-safe. But a probe that finds nothing must SAY so
#      on stderr (container log in the server lane): the silence is precisely
#      what let (1) ship unnoticed.

# The venv interpreter — the one the torch/triton/flash-attn stack is installed
# in. Absolute by design; see rule (1) above.
_rocm_env_py=/opt/venv/bin/python3

# Sourced more than once per login (profile.d, then the banner re-sources it).
# Probing again would only re-append to LD_LIBRARY_PATH and repeat any warning,
# so do the work once per shell. Deliberately NOT exported: a child shell that
# rebuilds its PATH must run the probe for itself.
if [ -z "${_droste_rocm_triton_env_done:-}" ]; then
    _droste_rocm_triton_env_done=1
    _rocm_env_out=''
    _rocm_env_msg=''

    if [ ! -x "$_rocm_env_py" ]; then
        _rocm_env_msg="$_rocm_env_py is missing or not executable"
    else
        # Query the venv python for the SDK's embedded ROCm paths. The probe
        # validates what it finds and exits non-zero with a one-line reason on
        # stderr, so a broken SDK tree can no longer masquerade as "nothing to
        # export". Its stderr is deliberately NOT captured: it goes straight to
        # the terminal / container log alongside the summary below.
        _rocm_env_out="$(
"$_rocm_env_py" - <<'PY'
import pathlib, sys

try:
    import _rocm_sdk_core as r
except Exception as e:
    sys.exit(f"_rocm_sdk_core is not importable by this interpreter: {e}")

core = pathlib.Path(r.__file__).parent
bin_ = core / "lib" / "llvm" / "bin"
lib  = core / "lib"

missing = [str(p) for p in (bin_ / "ld.lld", bin_ / "clang++", lib)
           if not p.exists()]
if missing:
    sys.exit("missing from the ROCm SDK tree: " + ", ".join(missing))

print(f'export TRITON_HIP_LLD_PATH="{bin_ / "ld.lld"}"')
print(f'export TRITON_HIP_CLANG_PATH="{bin_ / "clang++"}"')
# ${LD_LIBRARY_PATH:+...} not $LD_LIBRARY_PATH: unset-safe under `set -u`, and
# no trailing colon (an empty PATH element means "the current directory").
print(f'export LD_LIBRARY_PATH="{lib}${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}"')
PY
        )" || _rocm_env_msg="the ROCm SDK probe failed (reason above)"
        if [ -z "$_rocm_env_out" ] && [ -z "$_rocm_env_msg" ]; then
            _rocm_env_msg="the ROCm SDK probe succeeded but printed nothing"
        fi
    fi

    if [ -n "$_rocm_env_msg" ]; then
        printf '01-rocm-env-for-triton.sh: %s\n' "$_rocm_env_msg" >&2
        printf '01-rocm-env-for-triton.sh: %s\n' \
            'TRITON_HIP_LLD_PATH / TRITON_HIP_CLANG_PATH left UNSET — Triton HIP kernel compiles (flash-attn, unsloth) may fail.' >&2
    else
        eval "$_rocm_env_out"
    fi

    unset _rocm_env_out _rocm_env_msg
fi
unset _rocm_env_py

# Enable Triton AMD backend for flash-attn
#
# Exported UNCONDITIONALLY — deliberately, even when the probe above failed:
#   * Withholding it here would be theatre. The image already carries
#     `ENV FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE` (targets/Container.finetuning),
#     so the flag is already TRUE in both lanes before this file runs; skipping
#     the export changes nothing short of an active `unset`.
#   * Turning it off is not a safe fallback. flash-attn was BUILT with the flag
#     TRUE, which makes its setup.py skip the CUDA/C++ extension entirely — the
#     pure-Python/Triton path is the ONLY backend installed. Clearing the flag
#     does not select a working alternative, it selects a missing one, and trades
#     a possible kernel-compile failure for a certain import failure.
#   * The two TRITON_HIP_* vars are an OVERRIDE for Triton's own lld/clang
#     discovery, not a hard prerequisite; gating the backend on them would break
#     setups that compile fine without the override.
# So: keep the flag, and make a missing override loud (above) rather than
# silently reshaping the runtime around it.
export FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE
