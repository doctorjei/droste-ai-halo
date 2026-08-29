#!/usr/bin/env python3
"""patch_strix.py — build-time source patches for vLLM on Strix Halo (gfx1151).

Run from the root of a checked-out vLLM tree, BEFORE the wheel is built
(scaffolding/Container.vllm-build). Every patch below is written against the
PINNED vLLM ref declared in that Containerfile — currently v0.16.0.

🚨 EVERY SUBSTITUTION IS ANCHOR-GUARDED AND A MISS IS FATAL.
Before this rewrite the script announced " -> Patched <file>" whether or not a
substitution had found anything, and at v0.16.0 SIX of them found nothing:

  * `def _get_gcn_arch() -> str:` — the function is named
    `_get_gcn_arch_via_amdsmi()` at this pin (vllm/platforms/rocm.py:105), so
    "forced gfx1151" was printed for a replacement that never happened. With the
    MagicMock header (below) still installed, `_query_gcn_arch_from_amdsmi()`
    returned a truthy Mock, `"gfx11" in Mock()` is False (measured), and so
    `on_gfx1x()` was False ON REAL gfx1151 HARDWARE. That is the whole reason
    this file is being rewritten: the patch defeated the very detection it
    claimed to force.
  * `device_type = ...` / `device_name = ...` — no such assignments at the pin,
    and both were unanchored `.*` regexes that would have rewritten any
    same-named assignment they did find.
  * `on_mi3xx` in vllm/_aiter_ops.py — the gate is `on_gfx9()` here.
  * `on_mi3xx` in vllm/v1/attention/backends/rocm_aiter_fa.py — not present.
  * `envs.is_set("VLLM_ROCM_USE_AITER")` in the unquantized MoE oracle — gone.
  * `def to_dict(self):` in triton/backends/compiler.py — `AttrsDescriptor` was
    removed from triton years ago.

So: `substitute()` asserts an exact occurrence count before AND after, and dies
non-zero on any mismatch. A pin bump that reflows one of these anchors now
BREAKS THE BUILD instead of silently shipping an image with the patch missing —
which nothing downstream would notice, because every failure mode here is "vLLM
starts, serves, and quietly takes the wrong code path".

⚠️ DO NOT "fix" a failing anchor by widening it. An anchor that matches loosely
is worse than one that matches nothing: it will patch the wrong thing at the
next bump, silently. Re-derive the anchor from the new source.

⚠️ PATCHES DELIBERATELY REMOVED at v0.16.0 (do not resurrect without re-reading
the pinned source first) are listed at the bottom of this file.
"""

import re
import sys
from pathlib import Path

VLLM_PIN = "v0.16.0"


class PatchError(RuntimeError):
    """A patch did not find exactly what it expected. Always fatal."""


def _read(rel: str) -> tuple[Path, str]:
    p = Path(rel)
    if not p.is_file():
        raise PatchError(
            f"{rel} does not exist. Every patch in this file targets the vLLM "
            f"{VLLM_PIN} tree and must be run from its root; if the pin moved and "
            f"this path is gone, re-derive the patch — do not guard it away."
        )
    return p, p.read_text()


def substitute(rel: str, anchor: str, replacement: str, marker: str, expect: int = 1):
    """Replace `anchor` with `replacement`, asserting counts on both sides.

    `marker` must be absent before and present exactly `expect` times after; it
    is what makes a re-run refuse rather than double-patch. The expected number
    of surviving anchors is DERIVED (a replacement may legitimately contain its
    own anchor, e.g. an insertion), never guessed.
    """
    p, txt = _read(rel)
    if marker not in replacement:
        raise PatchError(f"{rel}: marker is not part of the replacement (bug here)")

    before_marker = txt.count(marker)
    if before_marker:
        raise PatchError(
            f"{rel}: already contains the patched text ({before_marker} occurrence(s)) "
            f"— refusing to patch twice."
        )
    before_anchor = txt.count(anchor)
    if before_anchor != expect:
        raise PatchError(
            f"{rel}: expected {expect} occurrence(s) of the anchor, found "
            f"{before_anchor}. The vLLM pin has moved or this code was reflowed; "
            f"re-derive the anchor from the {VLLM_PIN} source.\n"
            f"  anchor: {anchor!r}"
        )

    out = txt.replace(anchor, replacement)
    residual = replacement.count(anchor) * expect
    after_anchor = out.count(anchor)
    after_marker = out.count(marker)
    if after_anchor != residual:
        raise PatchError(
            f"{rel}: {after_anchor} anchor(s) survived, expected {residual}"
        )
    if after_marker != expect:
        raise PatchError(f"{rel}: {after_marker} marker(s) after, expected {expect}")

    p.write_text(out)


def substitute_regex(
    rel: str, pattern: str, replacement: str, marker: str, expect: int, flags: int = 0
):
    """Regex form of `substitute` for the one site that genuinely needs it."""
    p, txt = _read(rel)
    before_marker = txt.count(marker)
    if before_marker:
        raise PatchError(
            f"{rel}: already contains {marker!r} ({before_marker}×) — refusing to "
            f"patch twice."
        )
    found = len(re.findall(pattern, txt, flags=flags))
    if found != expect:
        raise PatchError(
            f"{rel}: expected {expect} regex match(es), found {found}. The vLLM pin "
            f"has moved; re-derive the pattern from the {VLLM_PIN} source."
        )
    out, n = re.subn(pattern, replacement, txt, flags=flags)
    if n != expect:
        raise PatchError(f"{rel}: substituted {n}, expected {expect}")
    if out.count(marker) != expect:
        raise PatchError(
            f"{rel}: {out.count(marker)} marker(s) after, expected {expect}"
        )
    p.write_text(out)


def require(rel: str, needle: str, why: str):
    """Assert a precondition a replacement relies on but does not itself create."""
    _, txt = _read(rel)
    if needle not in txt:
        raise PatchError(f"{rel}: {why}\n  expected to find: {needle!r}")


def prepend(rel: str, header: str, marker: str):
    p, txt = _read(rel)
    if marker in txt:
        raise PatchError(f"{rel}: already carries {marker!r} — refusing to patch twice.")
    p.write_text(header + txt)


def note(msg: str):
    print(f" -> {msg}")


# ── the patches ──────────────────────────────────────────────────────────────


def patch_platforms_init():
    """vllm/platforms/__init__.py — select the ROCm platform without amdsmi.

    The real amdsmi does not work on Strix Halo APUs in a container, so the
    probe here (import amdsmi -> init -> count processor handles) either raises
    or reports nothing and vLLM then selects no platform at all. Short it out.

    Each substitution is an EXACT WHOLE LINE including indentation. The old
    `re.sub(r'is_rocm = .*')` also rewrote the `is_rocm = True` on line 119 with
    itself — harmless, but it is exactly the kind of loose anchor that patches
    the wrong assignment after a refactor.
    """
    rel = "vllm/platforms/__init__.py"
    substitute(
        rel,
        "    is_rocm = False",
        "    is_rocm = True  # droste: forced, the amdsmi probe below cannot run here",
        marker="# droste: forced, the amdsmi probe below cannot run here",
    )
    substitute(
        rel,
        "        import amdsmi",
        "        # droste: import amdsmi",
        marker="# droste: import amdsmi",
    )
    substitute(
        rel,
        "        amdsmi.amdsmi_init()",
        "        pass  # droste: amdsmi.amdsmi_init()",
        marker="# droste: amdsmi.amdsmi_init()",
    )
    substitute(
        rel,
        "            if len(amdsmi.amdsmi_get_processor_handles()) > 0:",
        "            if True:  # droste: len(amdsmi.amdsmi_get_processor_handles()) > 0",
        marker="# droste: len(amdsmi.amdsmi_get_processor_handles()) > 0",
    )
    substitute(
        rel,
        "            amdsmi.amdsmi_shut_down()",
        "            pass  # droste: amdsmi.amdsmi_shut_down()",
        marker="# droste: amdsmi.amdsmi_shut_down()",
    )
    note(f"{rel}: amdsmi probe stubbed, is_rocm forced True")


def patch_rocm_platform():
    """vllm/platforms/rocm.py — stub amdsmi, and keep the stub out of arch detection.

    🚨 THESE TWO HALVES MUST STAY TOGETHER. The MagicMock exists because rocm.py
    calls amdsmi unguarded in `get_device_name()` and in the XGMI probe
    (rocm.py:452-477 at the pin) — with amdsmi absent those are a NameError. But
    the SAME mock also reaches `_query_gcn_arch_from_amdsmi()`, whose every call
    then "succeeds" and returns a Mock. MEASURED: `"gfx11" in MagicMock()` is
    False, so `on_gfx1x()`, `on_mi3xx()`, `on_gfx9()` and the ON_GFX11_GFX12 test
    inside `use_rocm_custom_paged_attention()` all answered "no" on real gfx1151.

    The fix is to make the amdsmi query RAISE, which is a documented, supported
    outcome upstream: `_get_gcn_arch_via_amdsmi()` catches it and falls back to
    `torch.cuda.get_device_properties("cuda").gcnArchName` — the real string.
    That is DETECTION, not a declaration, so there is no second source of truth
    for the arch beside GFX_TARGET in base/rocm-version.env.
    """
    rel = "vllm/platforms/rocm.py"

    mock_marker = 'sys.modules["amdsmi"] = MagicMock()'
    prepend(
        rel,
        "# droste: amdsmi is not usable on Strix Halo in a container. Stub the module so\n"
        "# rocm.py's unguarded amdsmi call sites do not NameError. See patch_strix.py —\n"
        "# arch detection is deliberately routed AWAY from this mock, just below.\n"
        "import sys\n"
        "from unittest.mock import MagicMock\n"
        f"{mock_marker}\n",
        marker=mock_marker,
    )

    raise_marker = 'raise RuntimeError("droste: amdsmi is stubbed; use the torch fallback")'
    substitute(
        rel,
        'def _query_gcn_arch_from_amdsmi() -> str:\n'
        '    """Query GCN arch from amdsmi. Raises if not available."""\n',
        'def _query_gcn_arch_from_amdsmi() -> str:\n'
        '    """Query GCN arch from amdsmi. Raises if not available."""\n'
        "    # droste: amdsmi is a MagicMock here (header above), so every call below\n"
        "    # would 'succeed' and hand back a Mock — and `\"gfx11\" in Mock()` is False,\n"
        "    # which silently reports the wrong architecture on real gfx1151. Raise\n"
        "    # instead: _get_gcn_arch_via_amdsmi() then takes its own documented\n"
        "    # torch.cuda fallback and reads the true gcnArchName.\n"
        f"    {raise_marker}\n",
        marker=raise_marker,
    )
    require(
        rel,
        'return torch.cuda.get_device_properties("cuda").gcnArchName',
        "the torch.cuda fallback that the raise above depends on is gone; without it "
        "_get_gcn_arch_via_amdsmi() has no way to answer and arch detection dies.",
    )
    note(f"{rel}: amdsmi stubbed; GCN arch now read from torch, not from the stub")


def patch_aiter_ops():
    """vllm/_aiter_ops.py — let aiter be considered on gfx11xx, minus two kernels.

    ⚠️ THIS DOES NOT TURN AITER ON. `is_aiter_found_and_supported()` answers "can
    aiter work on this system", and every `rocm_aiter_ops.*` getter behind it
    still requires VLLM_ROCM_USE_AITER, which defaults to False (envs.py:885).
    It makes aiter REACHABLE on gfx1151, where this image compiles it
    (scaffolding/Container.vllm-build) — nothing more.

    The imports are LOCAL, matching upstream's own idiom two lines above. A
    module-level `from vllm.platforms.rocm import ...` here would add a new
    import cycle between _aiter_ops and the platform module for no benefit.
    """
    rel = "vllm/_aiter_ops.py"

    substitute(
        rel,
        "        from vllm.platforms.rocm import on_gfx9\n"
        "\n"
        "        return on_gfx9()\n",
        "        from vllm.platforms.rocm import on_gfx1x, on_gfx9\n"
        "\n"
        "        # droste: aiter is compiled for gfx1151 in this image, so RDNA3.5\n"
        "        # counts as supported. Still gated by VLLM_ROCM_USE_AITER downstream.\n"
        "        return on_gfx9() or on_gfx1x()\n",
        marker="return on_gfx9() or on_gfx1x()",
    )
    substitute(
        rel,
        "    def is_linear_fp8_enabled(cls) -> bool:\n"
        "        return cls.is_linear_enabled()\n",
        "    def is_linear_fp8_enabled(cls) -> bool:\n"
        "        # droste: aiter ships no FP8 linear kernels for gfx11xx.\n"
        "        return False\n",
        marker="# droste: aiter ships no FP8 linear kernels for gfx11xx.",
    )
    substitute(
        rel,
        "    def is_rmsnorm_enabled(cls) -> bool:\n"
        "        return cls._AITER_ENABLED and cls._RMSNORM_ENABLED\n",
        "    def is_rmsnorm_enabled(cls) -> bool:\n"
        "        # droste: aiter RMSNorm hangs under CUDA-graph capture on gfx11xx.\n"
        "        from vllm.platforms.rocm import on_gfx1x\n"
        "\n"
        "        return cls._AITER_ENABLED and cls._RMSNORM_ENABLED and not on_gfx1x()\n",
        marker="cls._AITER_ENABLED and cls._RMSNORM_ENABLED and not on_gfx1x()",
    )
    substitute(
        rel,
        "    def is_fused_moe_enabled(cls) -> bool:\n"
        "        return cls._AITER_ENABLED and cls._FMOE_ENABLED\n",
        "    def is_fused_moe_enabled(cls) -> bool:\n"
        "        # droste: aiter's fused-MoE asm is CDNA-only (dpp_mov); no gfx11xx build.\n"
        "        from vllm.platforms.rocm import on_gfx1x\n"
        "\n"
        "        return cls._AITER_ENABLED and cls._FMOE_ENABLED and not on_gfx1x()\n",
        marker="cls._AITER_ENABLED and cls._FMOE_ENABLED and not on_gfx1x()",
    )
    note(f"{rel}: aiter reachable on gfx1x; fp8-linear off, rmsnorm + fused-MoE off there")


def patch_aiter_fusion():
    """rocm_aiter_fusion.py — tolerate duplicate inductor replacement patterns.

    `skip_duplicates` is a real keyword of torch._inductor.pattern_matcher.
    register_replacement (verified against torch v2.9.1, our pinned torch line).
    Six call sites at this pin; the count is asserted, so a seventh (or a
    rename) stops the build rather than being half-applied.
    """
    rel = "vllm/compilation/passes/fusion/rocm_aiter_fusion.py"
    substitute_regex(
        rel,
        r"(pm\.register_replacement\s*\((?:(?!\bpm\.register_replacement\b).)*?)pm_pass(\s*[\),])",
        r"\1pm_pass, skip_duplicates=True\2",
        marker="pm_pass, skip_duplicates=True",
        expect=6,
        flags=re.DOTALL,
    )
    note(f"{rel}: skip_duplicates=True on 6 register_replacement sites")


def patch_moe_wna16():
    """moe_wna16.py — tp_size moved off the weight container.

    vLLM moved tp_size out of RoutedExperts into FusedMoEConfig but
    moe_wna16_weight_loader still reads `layer.tp_size`, which crashes AWQ MoE
    models that fall back from AWQMoeMarlin to the WNA16 path.
    https://github.com/vllm-project/vllm/issues/45403
    """
    rel = "vllm/model_executor/layers/quantization/moe_wna16.py"
    require(
        rel,
        "get_tp_group",
        "get_tp_group is not imported; the replacement would reference an undefined name.",
    )
    substitute(
        rel,
        "layer.tp_size",
        "get_tp_group().world_size",
        marker="get_tp_group().world_size",
        expect=2,
    )
    note(f"{rel}: layer.tp_size -> get_tp_group().world_size (2 sites)")


def patch_vllm():
    print(f"Applying Strix Halo patches to vLLM {VLLM_PIN}...")
    patch_platforms_init()
    patch_rocm_platform()
    patch_aiter_ops()
    patch_aiter_fusion()
    patch_moe_wna16()
    print("Successfully patched vLLM for Strix Halo.")


# ── removed at v0.16.0 ───────────────────────────────────────────────────────
# Each of these was a no-op against the pinned tree. They are recorded rather
# than deleted silently, because "the anchor is gone" and "the problem is gone"
# are different findings and only the second justifies dropping a patch.
#
# csrc/spinloop.cpp (mwaitxintrin.h -> x86intrin.h for clang)
#     No such file at this pin. If it returns, the clang build fails loudly at
#     compile time, which is the right way to find out.
#
# vllm/platforms/rocm.py: `device_type = .*` / `device_name = .*`
#     No such assignments. Both were unanchored regexes; the nearest thing at
#     the pin is `device_name: str = asic_info["device_id"]`, which is annotated
#     and which these would have been wrong to touch anyway.
#
# vllm/v1/attention/backends/rocm_aiter_fa.py (on_mi3xx -> on_mi3xx or on_gfx1x)
#     No on_mi3xx reference in that file. The gfx9-only gate for the AITER FA
#     backend now lives in RocmPlatform.get_attn_backend_cls
#     (vllm/platforms/rocm.py:329, :351, :370). Opening those to gfx11xx is a
#     REAL behaviour change on untested hardware, so it is a deliberate decision
#     and not something to smuggle in by re-aiming a patch at a new address.
#
# vllm/model_executor/layers/fused_moe/oracle/unquantized.py (block AITER MoE)
#     Its two anchors are gone and its purpose is now covered exactly once:
#     unquantized.py:67 reads `rocm_aiter_ops.is_fused_moe_enabled()`, which
#     patch_aiter_ops() already guards with `not on_gfx1x()`.
#
# vllm/platforms/rocm.py (custom_ops "+rms_norm" bypass, all three variants)
#     Two of the three anchors never existed at this pin. The third did apply —
#     and inserted `getattr(self, "on_gfx1x", ...)` into check_and_update_config,
#     which is a @classmethod taking `cls`: MEASURED, that is a NameError if the
#     branch is ever reached, and it evaluated to False (never blocking anything)
#     if it were not. Redundant regardless: the value it guards,
#     `use_aiter_rms_norm` (rocm.py:498), IS rocm_aiter_ops.is_rmsnorm_enabled().
#     One guard, in one place — see patch_aiter_ops().
#
# mxfp4 Triton MoE capability cap (< (11, 0) -> < (12, 0))
#     Both file paths are gone; the check now lives at
#     vllm/model_executor/layers/quantization/mxfp4.py:93 and :154. NOT
#     re-targeted, because the branch it guards is unreachable in this image:
#     it requires has_triton_kernels(), i.e. the `triton_kernels` package or
#     vllm.third_party.triton_kernels — the image installs neither, and vLLM
#     does not vendor it at this pin.
#
# site-packages patches (triton AttrsDescriptor __repr__; aiter jit __path__;
# flash_attn soft import)
#     All three ran against the BUILDER's site-packages, and the builder's final
#     stage is `FROM scratch` + /artifacts — none of them ever reached a shipped
#     image. Individually: AttrsDescriptor and its to_dict() no longer exist in
#     triton 3.4/3.5/main, so that one printed a receipt for nothing; the aiter
#     JIT __path__ hack is superseded by targets/Container.vllm:177-178, which
#     copies the prebuilt .so straight into site-packages/aiter/jit/; and
#     flash_attn is only BUILT here, never installed, so the soft-import safety
#     net was never applied anywhere. ⚠️ That last one is a real remaining gap in
#     the RUNTIME image and needs a change to targets/Container.vllm, not here.


if __name__ == "__main__":
    try:
        patch_vllm()
    except PatchError as e:
        print(f"patch_strix: ERROR: {e}", file=sys.stderr)
        sys.exit(1)
