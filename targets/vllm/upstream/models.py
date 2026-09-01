# VENDORED — DO NOT EDIT BY HAND.
# Source: github.com/kyuz0/amd-strix-halo-vllm-toolboxes  scripts/models.py
# Pinned at the toolbox submodule provenance sha recorded in BUILD_NOTES.md:
#   6446b9595273f289e11586c3c7d3e1e6f2945888
# Fetched 2026-07-08 (raw.githubusercontent.com at that sha). NOTHING READS THIS FILE
# AT BUILD TIME and it is not COPYed into the image; it is the record of where the
# MODEL_TABLE stanzas in targets/vllm/templates/vllm_config.yaml came from, so drift is
# visible in git rather than as a silent build change.
# To refresh: re-fetch scripts/models.py at the new toolbox pin, replace below, then run
# `scripts/vllm-models.py` — it reports which stanzas in that hand-authored YAML the new
# table disagrees with. The report never writes the YAML; the edits are yours to make.
#
# 🚨 ONE UPSTREAM CLAIM BELOW IS NOT TRUE OF *OUR* IMAGES, and it is not ours to edit.
# The FP8 stanza (RedHatAI/Meta-Llama-3.1-8B-Instruct-FP8-dynamic) says
# "Correctness-verified on gfx1151". That is kyuz0's sentence, verbatim, and it is true
# of HIS images — they run a vLLM whose layout patch_fp8_kernels.py actually matches.
# It was NEVER true here: at VLLM_REF=v0.16.0 that patch targeted a path vLLM only
# adopted AFTER our pin, so it applied in ZERO builds this repo has produced and
# VLLM_STRIX_FP8_TRITON did nothing at all. What ran on gfx1151 in this image was stock
# torch._scaled_mm — the same code with the flag on or off — so nothing about the Triton
# kernels was verified here, correctness included.
# ✅ The patch is re-pointed and guarded as of s61 part 2; the flag is now WIRED. It is still
# UNVALIDATED on hardware, and a second gate (vLLM pads decode to 17 rows, so the
# rows-mapped M==1 GEMV that carries the speedup is unreachable) means no performance
# win is expected yet. See scaffolding/vllm-artifacts/patch_fp8_kernels.py.
# ⚠️ DO NOT "FIX" THE SENTENCE IN THE STANZA. Everything below this header is verbatim
# upstream, which is the only thing that makes drift visible in git; an edit there would
# show up as upstream drift at the next refresh and would put OUR claim inside THEIR
# text. Corrections belong in this header.
# ⚠️ And keep this header free of the table's opening literal: a naive text check that
# anchors on it would land in this comment instead of the definition. (Harmless to
# scripts/vllm-models.py, which EXECUTES this file and reads the dict — but not to a
# reader doing the obvious thing. It caught me once already.)

MODEL_TABLE = {
    # 1. Llama 3.1 8B Instruct
    # MAD uses 131k tokens. We scale to 32k for 32GB VRAM safety.
    "meta-llama/Meta-Llama-3.1-8B-Instruct": {
        "trust_remote": False,
        "valid_tp": [1, 2],
        "max_num_seqs": "64",
        "max_tokens": "32768",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "llama3_json",
        ]
    },

    # EXPERIMENTAL — FP8 (W8A8) via @leonyurko's Strix Halo Triton kernels (#67).
    # The "env" VLLM_STRIX_FP8_TRITON=1 opts this model into the patched fp8_triton
    # path (default-off; without it FP8 uses stock torch._scaled_mm). The kernels
    # require VLLM_ROCM_USE_AITER=0 + enforce_eager. Correctness-verified on gfx1151,
    # not yet benchmarked.
    "RedHatAI/Meta-Llama-3.1-8B-Instruct-FP8-dynamic": {
        "trust_remote": False,
        "valid_tp": [1],
        "enforce_eager": True,
        "env": {"VLLM_STRIX_FP8_TRITON": "1", "VLLM_ROCM_USE_AITER": "0"},
        "max_num_seqs": "64",
        "max_tokens": "32768",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "llama3_json",
        ]
    },

    "google/gemma-4-26B-A4B-it": {
        "trust_remote": False,
        "enforce_eager": False,
        "valid_tp": [1, 2],
        "max_num_seqs": "64",
        "max_tokens": "32768",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "gemma4",
            "--reasoning-parser", "gemma4",
        ]
    },

    "google/gemma-4-31B-it": {
        "trust_remote": False,
        "enforce_eager": False,
        "valid_tp": [1, 2],
        "max_num_seqs": "64",
        "max_tokens": "32768",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "gemma4",
            "--reasoning-parser", "gemma4",
        ]
    },
    # 2. GPT-OSS 20B (MXFP4)
    # MAD Row 0 uses 8192. We match this exactly.
    "openai/gpt-oss-20b": {
        "trust_remote": True,
        "valid_tp": [1, 2],
        "max_num_seqs": "64",
        "max_tokens": "8192",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "openai",
            "--reasoning-parser", "openai_gptoss",
        ]
    },
    
    "openai/gpt-oss-120b": {
        "trust_remote": True,
        "valid_tp": [1],
        "max_num_seqs": "64",
        "max_tokens": "8192",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "openai",
            "--reasoning-parser", "openai_gptoss",
        ]
    },

    "Qwen/Qwen3.6-35B-A3B": {
        "trust_remote": True,
        "valid_tp": [1],
        "max_num_seqs": "64",
        "max_tokens": "16384",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "qwen3_coder",
            "--reasoning-parser", "qwen3",
        ]
    },

    "cyankiwi/Qwen3.6-35B-A3B-AWQ-4bit": {
        "trust_remote": True,
        "valid_tp": [1], 
        "enforce_eager": True, 
        "env": {"VLLM_USE_TRITON_AWQ": "1"},
        "max_num_seqs": "64",
        "max_tokens": "16384",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "qwen3_coder",
            "--reasoning-parser", "qwen3",
        ]
    },  

    "cyankiwi/Qwen3.5-122B-A10B-AWQ-4bit": {
        "trust_remote": True,
        "valid_tp": [1,2], # Too big for single GPU
        "enforce_eager": True, 
        "env": {"VLLM_USE_TRITON_AWQ": "1"},
        "max_num_seqs": "64",
        "max_tokens": "16384",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "qwen3_coder",
            "--reasoning-parser", "qwen3",
        ]
    },

    "cyankiwi/Qwen3.5-122B-A10B-AWQ-8bit": {
        "trust_remote": True,
        "valid_tp": [2], # Too big for single GPU
        "enforce_eager": True, 
        "env": {"VLLM_USE_TRITON_AWQ": "1"},
        "max_num_seqs": "64",
        "max_tokens": "16384",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "qwen3_coder",
            "--reasoning-parser", "qwen3",
        ]
    },

    "cyankiwi/MiniMax-M2.7-AWQ-4bit": {
        "trust_remote": True,
        "valid_tp": [2],
        "enforce_eager": True,
        "env": {"VLLM_USE_TRITON_AWQ": "1"},
        "max_num_seqs": "64",
        "max_tokens": "16384",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "minimax_m2",
            "--reasoning-parser", "deepseek_r1",
        ]
    },

    "ayysasha/MiniMax-M2.7-AWQ-G32-STRIX-2H": {
        "trust_remote": True,
        "valid_tp": [2],
        "enforce_eager": True,
        "env": {"VLLM_USE_TRITON_AWQ": "1"},
        "ctx": "131072",
        "max_num_seqs": "64",
        "max_tokens": "16384",
        "extra_flags": [
            "--enable-auto-tool-choice",
            "--tool-call-parser", "minimax_m2",
            "--reasoning-parser", "deepseek_r1",
        ]
    },

}

MODELS_TO_RUN = list(MODEL_TABLE.keys())

# Hardware / Global Defaults
GPU_UTIL = "0.90"
OFF_NUM_PROMPTS = 200 # Increased for Strix Halo (Steady State Saturation)
OFF_FORCED_OUTPUT = "512"
DEFAULT_BATCH_TOKENS = "8192"
