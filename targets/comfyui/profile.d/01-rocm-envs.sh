#!/usr/bin/env bash
# Static torch/ROCm perf env for both lanes
#
# (The old header claimed this file "detects ROCm toolchain paths from the
# _rocm_sdk_core package"; it never did — ComfyUI needs no TRITON_HIP_* override.
# Everything here is a literal export, which is why it cannot fail.)
#
# Sourced from /etc/profile.d/ on every interactive login AND from the
# build-spec's PRE_LAUNCH in the server lane. If you ever add a probe here,
# DO NOT shell out to a PATH-resolved `python3`: Debian's /etc/profile REBUILDS
# PATH before it runs profile.d/, so at this point `python3` is /usr/bin/python3
# (no ROCm packages) — /opt/venv/bin only returns later, via rocm.sh's `activate`
# and zz-venv-last.sh's PROMPT_COMMAND, both of which sort after this file. Call
# /opt/venv/bin/python3 by absolute path, report failure on stderr, and never
# return non-zero (the login shell in one lane, and the resolver's `set -euo
# pipefail` in the other, both die on it). See finetuning's
# 01-rocm-env-for-triton.sh for the worked example — it shipped the PATH bug.

# Enable AOTriton for torch
export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1

# Ensure ROCm uses recent PRs for hipblaslt performance improvement on gfx1151/gfx1101
# Refs: ROCm/rocm-libraries#3913, ROCm/rocm-libraries#3879
export TORCH_BLAS_PREFER_HIPBLASLT=1
