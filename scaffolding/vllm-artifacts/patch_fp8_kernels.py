import sys
from pathlib import Path

# FP8 (W8A8) Strix Halo kernel routing for vLLM.
# Kernels: https://github.com/leonyurko/vllm-fp8-strix-halo-kernel-support
# (the kernel modules — fp8_triton.py etc. — are placed on PYTHONPATH, e.g. /opt/fp8).
#
# gfx1151 has no native FP8 tensor support. This injects a routing shim into vLLM's
# compressed-tensors W8A8-FP8 scaled-mm path that *optionally* uses @leonyurko's fused
# FP8->bf16 Triton dequant-GEMM (fp8_triton.fp8_gemm).
#
# OPT-IN: the shim only routes to the Triton kernel when the env var
# VLLM_STRIX_FP8_TRITON=1 is set at serve time; otherwise it calls the stock
# torch._scaled_mm (upstream behavior unchanged). This keeps the kernels off the
# default path — they override stock/hipBLASLt FP8, require --enforce-eager +
# VLLM_ROCM_USE_AITER=0, and aren't benchmarked — so they're only used when
# consciously activated (per kyuz0's suggestion on #67).
#
# ⚠️ "OPT-IN" DESCRIBES THIS SHIM, NOT A DROSTE BOX. `targets/vllm/build-spec`'s
# PRE_LAUNCH does the opting in for every box (`: "${DROSTE_VLLM_STRIX_FP8_TRITON:=on}"`,
# f392518), because on gfx1151 the stock branch below is not a fallback — it is a crash.
# See the s78 block at the foot of this header.
#
# Deliberately a SEPARATE patch file (NOT patch_strix.py) so the FP8 work stays
# independent of the is_integrated memory PR (#66). Surgical call-swap (not a file
# overlay): preserves vLLM's current scale-handling in apply_scaled_mm, only
# redirecting the GEMM call.
#
# ── WHY THIS FILE NOW DIES INSTEAD OF SKIPPING ────────────────────────────────
# 🚨 IT SHIPPED AS A SILENT NO-OP. The path below used to read
# `vllm/model_executor/kernels/linear/scaled_mm/pytorch.py`, which is the layout
# vLLM adopted AFTER our pin (upstream 6af03f23, "[Refactor] [1/N] Reorganize
# kernel abstraction directory", landed on main one day after the v0.16.0 release
# branch was cut). At VLLM_REF=v0.16.0 that path has never existed, so every build
# printed " -> FP8 patch: ... skipping" and RETURNED 0. The image still looked
# configured — /opt/fp8 is cloned, trimmed and shipped, PYTHONPATH=/opt/fp8 is
# baked, VLLM_STRIX_FP8_TRITON is a documented setting — and the feature was gone.
#
# ⭐ THIS WAS NOT DRIFT. A PATCH CAN BE BORN BROKEN. This script and VLLM_REF have
# been byte-identical since the initial import (e7ade16, 2026-07-05): the script was
# written against a NEWER vLLM than the one we pin, so it never applied in a single
# build this repo has ever produced. Nothing here rotted — it arrived dead.
# ⭐ SO "IT HAS ALWAYS BEEN THIS WAY" IS EVIDENCE **FOR** A DEFECT, NOT AGAINST ONE.
# A guard that only compares against yesterday cannot see this class of failure, and
# nothing would have caught it except someone asking, of a mutation of upstream
# source, whether it ACTUALLY LANDED. Ask that of every such mutation, at birth.
#
# ⚠️ PERMANENT, NOT A STOPGAP: this is our own kernel routing, not something
# upstream will ever take. NOBODY IS WATCHING FOR IT TO BECOME UNNECESSARY, so the
# guard below is the only thing that will ever report that it stopped applying.
# Every failure mode here is invisible from outside: the image builds, the server
# starts, /health answers 200, and FP8 quietly runs on the stock path.
#
# ── THE LANE HAS RUN, AND IT IS NOT OPTIONAL HERE (measured s71, corrected s78) ─
# 🚨 THIS PARAGRAPH USED TO SAY THE LANE HAD NEVER RUN ON HARDWARE AND TO EXPECT NO
# SPEEDUP. Both were true when written and both are now false, so they are corrected
# rather than deleted — the reasoning under them is what a future reader needs.
# WITHOUT THE SHIM, AN FP8 MODEL KILLS THE ENGINE CORE ON gfx1151. The `if not
# _VLLM_STRIX_FP8_TRITON:` branch below falls through to stock torch._scaled_mm, whose
# capability check is the first statement of ATen's _scaled_mm_out_cuda, and this card
# is not MI300+: "RuntimeError: torch._scaled_mm is only supported on CUDA devices with
# compute capability >= 9.0 or 8.9, or ROCm MI300+", raised inside profile_run before
# KV sizing, followed by a healthcheck relaunch loop. Measured on Raiju serving
# Qwen2.5-1.5B fp8 at s71, and seen again in the field at s78 on a box whose image
# predated the fix. ⇒ targets/vllm/build-spec's PRE_LAUNCH defaults the flag ON.
#
# ⭐ AND THE M=17 GATE IS NO LONGER WHAT IT WAS, BECAUSE OUR OWN DEFAULT MOVED.
# `TorchFP8ScaledMMLinearKernel.get_output_padding()` returns 17 whenever compilation
# mode < VLLM_COMPILE, and vLLM pads the quantized activation to that many rows
# (_custom_ops.py: `shape = (max(num_token_padding, input.shape[0]), shape[1])`) — so
# decode used to arrive at fp8_gemm with M=17, never M=1, and the rows-mapped GEMV that
# is the decode win upstream advertises was unreachable. That mechanism is unchanged;
# the CONDITION is what went away. The old text inferred `mode < VLLM_COMPILE` from the
# --enforce-eager these kernels require, and vLLM derives the mode only when it is
# UNSET — so DROSTE_VLLM_COMPILATION_MODE=vllm_compile (mode 3, the default since s71)
# leaves enforce-eager in place and still returns None from get_output_padding.
# ⚠️ SO DO NOT QUIETLY ADD THE OVERRIDE. leonyurko's overlay overrides
# get_output_padding to None; we reach the same state from a setting rather than by
# changing vLLM's kernel-selection contract, and that remains the cheaper answer.
# ⚠️ AND DO NOT READ ANY OF THIS AS A MEASURED SPEEDUP: there is no Triton-vs-stock
# comparison on gfx1151 and there cannot be one, because the stock arm does not run.
# What is measured is that fp8 serves with the shim on and dies with it off.

TARGET = 'vllm/model_executor/layers/quantization/kernels/scaled_mm/pytorch.py'
# The post-refactor spelling, named ONLY so the death message can tell a future
# maintainer which way the tree moved. Never patched blind — re-point deliberately.
MOVED_TO = 'vllm/model_executor/kernels/linear/scaled_mm/pytorch.py'

# Exact contract at VLLM_REF=v0.16.0. All three live in `apply_scaled_mm` methods of
# the three Torch FP8 kernel classes registered for ROCm. If one of these moves,
# RE-DERIVE it from the source at the new pin rather than adjusting it to go green.
N_CALL_SITES = 3
N_APPLY_DEFS = 3
ROCM_KERNEL_CLASSES = (
    'PerTensorTorchFP8ScaledMMLinearKernel',
    'RowWiseTorchFP8ScaledMMLinearKernel',
    'ChannelWiseTorchFP8ScaledMMLinearKernel',
)

SCALED_MM_FB = '''

import os as _os
_VLLM_STRIX_FP8_TRITON = _os.environ.get("VLLM_STRIX_FP8_TRITON") == "1"


def _scaled_mm_fb(A, B, *, out_dtype, scale_a, scale_b, bias=None):
    # Default: stock torch._scaled_mm (upstream behavior, incl. any hipBLASLt FP8).
    # Opt-in (VLLM_STRIX_FP8_TRITON=1): gfx1151 fused FP8->bf16 Triton dequant GEMM
    # from leonyurko/vllm-fp8-strix-halo-kernel-support (fp8_triton on PYTHONPATH),
    # with a bf16 matmul + manual dequant fallback if the kernel is unavailable.
    if not _VLLM_STRIX_FP8_TRITON:
        return torch._scaled_mm(
            A, B, out_dtype=out_dtype, scale_a=scale_a, scale_b=scale_b, bias=bias
        )
    try:
        from fp8_triton import fp8_gemm
        return fp8_gemm(A.contiguous(), B, scale_a, scale_b, out_dtype, bias)
    except Exception:
        o = (A.to(torch.bfloat16) @ B.to(torch.bfloat16)).to(torch.float32)
        sa = scale_a.to(torch.float32).reshape(-1)
        sb = scale_b.to(torch.float32).reshape(-1)
        o = o * (sa if sa.numel() == 1 else sa.view(-1, 1))
        o = o * (sb if sb.numel() == 1 else sb.view(1, -1))
        if bias is not None:
            o = o + bias.to(torch.float32)
        return o.to(out_dtype)
'''

_ADVICE = """
fp8-kernels: The pinned vLLM no longer matches what this patch assumes. READ
fp8-kernels: {target}
fp8-kernels: at the CURRENT VLLM_REF and RE-DERIVE the path, the anchors and the
fp8-kernels: counts in this file against what you actually find there.
fp8-kernels: Do NOT restore the old `return` that skipped quietly: a skip here is
fp8-kernels: invisible from outside -- the image builds, the server starts, /health
fp8-kernels: answers 200, VLLM_STRIX_FP8_TRITON stays a documented setting, and FP8
fp8-kernels: silently runs on the stock torch._scaled_mm path with no GPU kernel of
fp8-kernels: ours anywhere in it. That is exactly how this shipped inert.
fp8-kernels: If gfx1151 FP8 is no longer wanted, RETIRE THE WHOLE LANE instead --
fp8-kernels: this script, the FP8_KERNELS_* args, /opt/fp8, PYTHONPATH=/opt/fp8 and
fp8-kernels: the VLLM_STRIX_FP8_TRITON setting -- rather than leaving a dead patch.
"""


def die(msg):
    print("fp8-kernels: FATAL: " + msg, file=sys.stderr)
    print(_ADVICE.format(target=TARGET).strip("\n"), file=sys.stderr)
    raise SystemExit(1)


def patch_fp8():
    print("Applying Strix Halo FP8 Triton kernel routing to vLLM (opt-in via VLLM_STRIX_FP8_TRITON)...")

    p = Path(TARGET)
    if not p.exists():
        extra = ""
        if Path(MOVED_TO).exists():
            extra = (" -- it now lives at " + MOVED_TO + ", i.e. the pin crossed"
                     " vLLM's kernel-directory reorganization; re-point TARGET there"
                     " and re-check every count below against that file")
        die(TARGET + " does not exist at this VLLM_REF" + extra)

    txt = p.read_text()

    if '_scaled_mm_fb' in txt:
        die(TARGET + " already carries the shim -- refusing to patch twice")

    # ── REACHABILITY: patching a module nothing dispatches to is a silent no-op ──
    # The shim only runs if these classes are the ones vLLM selects for FP8 on ROCm.
    # The registry lives beside the target file.
    reg = p.parent / '__init__.py'
    if not reg.exists():
        die("no __init__.py beside " + TARGET + " -- the scaled-mm kernel registry moved")
    reg_txt = reg.read_text()
    if 'PlatformEnum.ROCM' not in reg_txt:
        die(str(reg) + " has no PlatformEnum.ROCM entry -- ROCm no longer dispatches"
            " through this registry, so the shim would never be reached")
    for cls in ROCM_KERNEL_CLASSES:
        if cls not in reg_txt:
            die(cls + " is not referenced by " + str(reg) + " -- the class this patch"
                " rewrites is no longer registered, so the shim would never be reached")

    # ⚠️ KNOWN GAP, RECORDED BECAUSE IT IS EXACTLY THE SHAPE THIS FILE EXISTS TO CATCH
    # (s78). The checks above assert that the three pytorch.py classes are REGISTERED.
    # They do NOT assert that the kernel registered AHEAD of them stays out of reach.
    # At this pin _POSSIBLE_FP8_KERNELS[PlatformEnum.ROCM] lists
    # ROCmFP8ScaledMMLinearKernel FIRST, and that class carries a FOURTH
    # 'output = torch._scaled_mm(' — the non-skinny fallback inside
    # rocm_per_tensor_float_w8a8_scaled_mm_impl, in scaled_mm/rocm.py: a file this patch
    # never opens, whose call sites none of the counts below can see. It is unreachable
    # on gfx1151 only because its is_supported() demands on_mi3xx() (gfx942/gfx950) AND
    # VLLM_ROCM_USE_SKINNY_GEMM, so selection falls through to
    # PerTensorTorchFP8ScaledMMLinearKernel, which IS patched.
    # 🚨 IF A FUTURE PIN RELAXES THAT GATE, THE SHIM IS BYPASSED AND THE CRASH RETURNS
    # SILENTLY: that kernel is chosen first, its fallback reaches stock torch._scaled_mm,
    # gfx1151 raises "ROCm MI300+" in profile_run — and every guard in this function is
    # still green, because the file it patched is untouched and correctly patched.
    # ⭐ AN ASSERTION WOULD HAVE TO READ A SECOND FILE: that scaled_mm/rocm.py's
    # is_supported still gates on on_mi3xx(), and/or that its torch._scaled_mm fallback
    # is gone. DELIBERATELY NOT ADDED HERE — recording the gap beside the guard is this
    # session's scope; widening the guard changes what the build refuses to produce, and
    # that decision is not a comment's to make.

    n_defs = txt.count('    def apply_scaled_mm(')
    if n_defs != N_APPLY_DEFS:
        die("expected exactly %d apply_scaled_mm definitions in %s, found %d"
            % (N_APPLY_DEFS, TARGET, n_defs))

    n = txt.count('output = torch._scaled_mm(')
    if n != N_CALL_SITES:
        die("expected exactly %d 'output = torch._scaled_mm(' call sites in %s, found %d"
            % (N_CALL_SITES, TARGET, n))

    # 1) redirect the apply_scaled_mm GEMM calls through the opt-in shim
    txt = txt.replace('output = torch._scaled_mm(', 'output = _scaled_mm_fb(')
    # 2) inject the routing shim at module scope (reads the env var once at import)
    txt = txt + SCALED_MM_FB

    if txt.count('output = torch._scaled_mm(') != 0:
        die("a stock 'output = torch._scaled_mm(' call site SURVIVED the rewrite")
    n_after = txt.count('output = _scaled_mm_fb(')
    if n_after != N_CALL_SITES:
        die("expected exactly %d routed call sites after patching, found %d"
            % (N_CALL_SITES, n_after))
    if txt.count('def _scaled_mm_fb(') != 1:
        die("expected exactly 1 _scaled_mm_fb definition after patching")

    compile(txt, TARGET, 'exec')  # a rewrite that does not parse must not reach the wheel

    p.write_text(txt)
    print(" -> FP8 patch: routed %d scaled_mm call site(s) via _scaled_mm_fb (opt-in: VLLM_STRIX_FP8_TRITON=1)" % N_CALL_SITES)
    print("Successfully patched vLLM for Strix Halo FP8 kernels (opt-in).")


if __name__ == '__main__':
    patch_fp8()
