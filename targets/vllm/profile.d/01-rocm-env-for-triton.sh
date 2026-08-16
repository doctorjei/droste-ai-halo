#!/usr/bin/env bash
# Required for Strix Halo / RDNA3.5 on vLLM
#
# Interactive lane only, in practice: every var below is also baked as an `ENV`
# in targets/Container.vllm, so the server lane already has them and its
# PRE_LAUNCH does not source this file. Unlike finetuning's same-named script
# this one derives nothing — vLLM's Triton path needs no TRITON_HIP_LLD_PATH /
# TRITON_HIP_CLANG_PATH override — so there is nothing here that can fail.
#
# If you ever add a probe: DO NOT shell out to a PATH-resolved `python3`.
# Debian's /etc/profile REBUILDS PATH before it runs profile.d/, so at this point
# `python3` is /usr/bin/python3 (no ROCm packages); /opt/venv/bin only comes back
# afterwards, via rocm.sh's `activate` and zz-venv-last.sh's PROMPT_COMMAND, both
# of which sort after this file. Use /opt/venv/bin/python3 by absolute path,
# report failure on stderr, and never return non-zero — that would kill the login
# shell here and abort the resolver (`set -euo pipefail`) in the server lane.
# finetuning's 01-rocm-env-for-triton.sh is the worked example: it shipped
# exactly this bug, and the empty `eval` hid it.
export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
export FLASH_ATTENTION_TRITON_AMD_ENABLE="TRUE"
export VLLM_TARGET_DEVICE=rocm
export VLLM_USE_TRITON_AWQ=1
# MIOpen's exhaustive kernel search hangs on gfx1151 for some conv shapes
# (notably vision-encoder conv stems). FAST uses heuristics instead.
export MIOPEN_FIND_MODE=FAST

# Temporary fix for "PicklingError: Can't pickle <function launcher ...>" inside EngineCore
export VLLM_DISABLE_COMPILE_CACHE=1
export PYTHONNOUSERSITE=1