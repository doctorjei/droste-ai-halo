#!/usr/bin/env python3
"""model-scanner: HF-cache -> ComfyUI symlink-tree scanner for the droste comfyui container.

Runs at every container start (from the entrypoint, before ComfyUI launches). Walks the
shared HuggingFace hub cache plus an optional local models dir, CLASSIFIES every weight
file it finds, and maintains a ComfyUI-friendly symlink tree (default
/opt/data/model-tree, bind-mounted onto /opt/ComfyUI/models). Links point at the resolved
blob (realpath) so they survive HF repo revision bumps. Steady state (nothing changed)
does no heavy I/O: known identities skip classification entirely and go straight to a
cheap link-verify.

The registry is a classified INVENTORY of the model sources; the ComfyUI link tree is
just one consumer of it. EVERYTHING identifiable gets a real classification -- including
things ComfyUI cannot load (LLM repos and GGUFs -> `llm`, speech-recognition models in
any container -> `asr`, split-GGUF parts, sharded components) -- those are
recorded with links:[] and never linked. `unclassified` is reserved STRICTLY for
genuinely unknown files, so the UNCLASSIFIED report is a true heuristics-gap list.

Usage:
    model_scanner.py sync   [-n|--dry-run] [--no-prune] [--hardlink] [path overrides]
    model_scanner.py status [path overrides]
    (no verb defaults to `sync`)

Path overrides: --cache-dir, --models-dir, --tree, --registry.

DESIGN NOTES / REGISTRY SCHEMA
==============================
One YAML store (default /opt/data/model-registry.yaml) plays TWO roles:

1. Classification cache -- keyed by CONTENT IDENTITY so we never re-inspect a file we
   have already seen:
     * HF blobs:      "hf:<blob-filename>" -- the blob filename IS its sha256 (no re-hash)
     * local files:   "local:<relpath>|<size>|<mtime_ns>" -- cheap stat key; a touched or
       rewritten file gets a NEW identity (old one prunes, new one reclassifies), so
       multi-GB files are never fully hashed.
     * diffusers repo units: "diffusers:<org>/<repo>@<revision>" -- a REPO-LEVEL entry
       (the unit is a snapshot dir, not a blob); re-detected each run (one stat), so it
       carries no classification cost.

2. Ownership ledger -- the safety invariant:
     * a tree-relative link path recorded under some entry's `links` == OURS
       (we may replace or prune it);
     * any path in the tree NOT in the registry == the USER'S -> never clobbered,
       never pruned. Registry lost => worst case orphaned symlinks, never destroyed
       user files.

Schema (version 2):

    version: 2            # registry format version (2: repo units, members, sharded)
    heuristics: 2         # classification-heuristics version; mismatch => reclassify all
                          #   (also migrates v1 trees: old links are still owned, so the
                          #    prune/relink pass renames them cleanly)
    entries:
      "hf:<sha256>":                       # weight-file entry
        origin: hf                         # or "local"
        category: vae                      # ComfyUI category, an inventory category
                                           #   (llm, asr, gguf-split,
                                           #    diffusers), or "unclassified"
        format: safetensors                # CONTAINER format: gguf | ggml | ctranslate2
                                           #   | safetensors | pickle | diffusers
        sharded: true                      # OPTIONAL; multi-part file: classified but
                                           #   never linked (absent = single-file)
        source: /abs/path/to/blobs/<sha>   # resolved source at last sync (informational)
        display: org/repo/vae/diffusion_pytorch_model.safetensors   # provenance
        links:                             # tree-relative links WE own (ownership!)
          - vae/FLUX.1-Fill-dev--vae.safetensors   # [] for inventory-only/unclassified
      "diffusers:org/repo@<rev>":          # repo-level diffusers unit
        origin: hf
        category: diffusers
        format: diffusers
        source: /abs/path/to/snapshots/<rev>
        display: org/repo@<rev8>
        links: []                          # NEVER dir-linked (DiffusersLoader is niche)
        members:                           # identities of its component weight files
          - "hf:<sha256>"                  #   (repo <-> component relationship)

Only categories in the ComfyUI category set are linkable, and sharded files are never
linked even when their role is known. Entries whose identity vanished from the sources
are dropped (and their symlinks pruned) on sync unless --no-prune, in which case the
entries are carried forward so ownership of the now-broken links is retained for a
later prune.

LINK NAMING -- generic-filename rule: when a to-be-linked basename is generic
(model.safetensors, diffusion_pytorch_model.safetensors, pytorch_model.bin, model.bin,
fp16/bf16 variants, ...) the link name is ALWAYS derived from provenance:
`<repo-name>--<subdir>` (e.g. vae/FLUX.1-Fill-dev--vae.safetensors) or
`<repo-name>--<stem>` at repo root -- a meaningless plain name is never squatted.
Non-generic basenames keep their plain name; a provenance prefix is added only on
collision.

Classification ladder (cheapest first, stop at first confident match; on conflict or
no signal -> "unclassified", which is recorded but NEVER linked):
  0. diffusers component role: files inside a repo with a root model_index.json inherit
     their component subdir's role (vae -> vae, text_encoder* -> text_encoders,
     transformer/unet/prior -> diffusion_models, image_encoder -> clip_vision, ...)
  1. path segments (snapshot-relative dirs, e.g. Comfy-Org `split_files/<category>/`,
     or category-named subdirs under the local models dir); exact names first, then
     segments that merely QUALIFY one (nai_hypernetworks -> hypernetworks)
  2. filename keywords (lora, vae, controlnet, t5/clip_l/clip_g, esrgan/4x-upscalers,
     yolo detectors -> ultralytics/{bbox,segm}, sam -> sams, face-parsing, pose, ...)
  3. CTranslate2 layout: a `.bin` + a sibling vocabulary file -> asr
  4. safetensors header (8-byte length + JSON header ONLY -- tensors never read):
     tensor-name prefixes + `__metadata__` modelspec.architecture
  5. sibling config.json (HF-format repos): `architectures` -> category;
     LLM architectures (…ForCausalLM etc.) -> `llm` (vllm's models; inventory-only)
  6. GGUF metadata (`general.architecture`): diffusion archs -> diffusion_models,
     clip/t5 -> text_encoders, LLM archs -> `llm` (llama/ds4's models;
     inventory-only); a split part whose architecture is unreadable -> `gguf-split`

The linking core (ensure_link/prune, ownership checks) is classification-agnostic so a
later manifest-driven explicit layer (see hf-comfy-link seed) can share it.
"""

from __future__ import annotations

import argparse
import json
import os
import pickle
import re
import struct
import sys
import time
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("model-scanner: pyyaml is required (the comfyui image bakes it)")

# --------------------------------------------------------------------------- constants

REGISTRY_VERSION = 2
# 7: qualified path segments (nai_hypernetworks) and annotator family names (depth_anything,
#    ZoeD, the Annotators repo) now classify, so every registry must re-run.
# 8: STEP 2 -- the weighted SCORE decides the category, not the heuristic ladder, and LoFi
#    (name/path/sidecar) evidence is trusted less. Precedence changed for every file.
# 9: inventory categories named by ROLE, not container: ctranslate2 + ggml-asr -> asr,
#    gguf-llm -> llm; entries gain a `format` field. New content rules besides.
# 10: content-rule changes, all from Jei's collection: AnimateDiff motion LORAS split off
#    from motion MODULES (new linkable `animatediff_motion_lora`) and the motion signal
#    itself narrowed to UNet-block context (a video-depth model's `head.motion_modules.`
#    was reading as AnimateDiff); a vision tower that co-occurs with a language decoder is
#    a multimodal LLM (text_encoders), not clip_vision; DiT ControlNets (controlnet_blocks.
#    / controlnet_x_embedder.) outrank the bare-DiT rule; and legacy (pre-1.6, non-zip)
#    torch files are finally readable, so files that yielded nothing now classify.
#    Every registry must re-run.
# 11: content-rule changes, all from Jei's key dumps of the files heuristics 10 finally
#    made readable. (a) a vae vote now requires real autoencoder ANATOMY -- "has an
#    encoder and a decoder" is not "is a VAE", and ParseNet (a face-segmentation net)
#    was outvoting its own correct filename on that alone; (b) the DataParallel
#    `module.` wrapper is stripped ONCE in the shared key classifier, so every rule
#    sees the same names whether or not a checkpoint was saved off a DataParallel
#    model; (c) RetinaFace/facexlib heads (BboxHead/ClassHead/LandmarkHead) ->
#    facedetection; (d) CPM/OpenPose stage convs (Mconv<n>_stage<n>, model<n>_<n>) ->
#    controlnet_aux, so `facenet.pth` -- a pose model, not a face-recognition net --
#    classifies by content instead of by its misleading name.
#    Every registry must re-run.
HEURISTICS_VERSION = 12

DEFAULT_CACHE_DIR = "~/.cache/huggingface/hub"
DEFAULT_MODELS_DIR = "/opt/models"
DEFAULT_TREE = "/opt/data/model-tree"
DEFAULT_REGISTRY = "/opt/data/model-registry.yaml"

WEIGHT_EXTS = {".safetensors", ".gguf", ".pth", ".ckpt", ".pt", ".bin"}

# Pickle-format weights. Content-sniffed via read_pickle_signals, which NEVER executes
# the payload (see _restricted_unpickle). `.bin` is included because HF-format torch
# weights use it, and the CT2 `model.bin` case is matched earlier by layout.
PICKLE_EXTS = {".pth", ".pt", ".ckpt", ".bin"}

UNCLASSIFIED = "unclassified"

# ComfyUI category dirs (folder_paths.py) == the LINKABLE categories.
# `diffusers` is deliberately ABSENT (2026-08-12, s32): repo units are inventory-only
# (INVENTORY_CATEGORIES), and dropping it here also drops its SEGMENT_MAP entry -- so a
# stray file under a `diffusers/` directory no longer classifies (and links!) off the
# folder name while a byte-identical file elsewhere goes unclassified.
CATEGORIES = {
    "checkpoints", "diffusion_models", "text_encoders", "vae", "loras",
    "controlnet", "clip_vision", "upscale_models", "latent_upscale_models",
    "embeddings", "style_models", "photomaker", "gligen", "hypernetworks",
    "vae_approx", "audio_encoders", "model_patches",
    "background_removal", "detection", "frame_interpolation",
    "geometry_estimation", "optical_flow",
}

# Custom-node detector/aux dirs that popular ComfyUI packs scan (Impact-Pack,
# ReActor/facexlib, ControlNet-aux). Not core folder_paths categories, but the tree
# link mechanics are identical, so they are added to the LINKABLE set. Nested paths
# (ultralytics/bbox) work directly: plan_links just joins "<cat>/<link_name>".
DETECTOR_CATEGORIES = {
    "ultralytics/bbox",   # Impact-Pack UltralyticsDetectorProvider: detection/bbox
    "ultralytics/segm",   # Impact-Pack UltralyticsDetectorProvider: segmentation
    "sams",               # Impact-Pack SAMLoader: Segment-Anything checkpoints
    "facedetection",      # ReActor / facerestore facexlib weights (face parsing)
    "facerestore_models",  # ReActor / facerestore: CodeFormer, GFPGAN, RestoreFormer
    "controlnet_aux",     # ControlNet-aux annotator / pose-estimator weights
    "animatediff_models",  # AnimateDiff-Evolved motion modules (temporal transformers)
    # AnimateDiff-Evolved registers TWO folders (animatediff/utils_model.py): the motion
    # modules above and the motion LORAS below, which are loaded by a DIFFERENT node and
    # are invisible to it anywhere else. They share the motion-module tensor layout, so
    # only the LoRA processor keys tell them apart (see classify_safetensors_header).
    "animatediff_motion_lora",
}
CATEGORIES |= DETECTOR_CATEGORIES

# Inventory-only categories: real classifications that ComfyUI cannot load.
# Recorded with links:[] so later features are a linking rule, never a re-scan.
# Inventory-only categories: real classifications that ComfyUI cannot load. Named by
# ROLE, exactly like every loadable category -- the container a model ships in is
# recorded separately in `format`. (Until 2026-08-12 these were named after their
# containers, which split one model across two categories: whisper in CTranslate2 and
# whisper in ggml had nothing in common, and `llm` vs `gguf-llm` were one thing twice.)
INVENTORY_CATEGORIES = {"llm", "asr", "gguf-split", "diffusers"}

# path-segment -> category (step 1). Includes aliases and common singular forms.
SEGMENT_MAP = {c: c for c in CATEGORIES}
SEGMENT_MAP.update({
    "unet": "diffusion_models",          # legacy alias
    "clip": "text_encoders",             # legacy alias
    "diffusion_model": "diffusion_models",
    "text_encoder": "text_encoders",
    "lora": "loras",
    "checkpoint": "checkpoints",
    "embedding": "embeddings",
    "controlnets": "controlnet",
    "upscaler": "upscale_models",
    "upscalers": "upscale_models",
    "upscale": "upscale_models",
    "hypernetwork": "hypernetworks",
})

# A path segment often QUALIFIES a category name rather than being one: nai_hypernetworks,
# sdxl-loras, flux_controlnet -- all of which the exact lookup above misses entirely.
# Matched against the SEPARATOR-NORMALIZED segment, at the end only, and only across a
# separator: those two bounds are what keep it honest. Without the boundary `unclip` reads
# as `clip` and `myvae` as `vae`; without the suffix anchor `hypernetworks_disabled` -- a
# dir deliberately parked out of the way -- would be swept back in. A leading qualifier is
# the shape people write; nobody names a directory OF hypernetworks `hypernetworks_nai`.
SEGMENT_SUFFIX_RE = re.compile(
    r"_(" + "|".join(sorted((k for k in SEGMENT_MAP if "/" not in k),
                            key=len, reverse=True)) + r")$")

# diffusers component subdir -> role (step 0; only inside a model_index.json repo)
DIFFUSERS_COMPONENT_MAP = {
    "vae": "vae", "vae_decoder": "vae", "vae_encoder": "vae",
    "text_encoder": "text_encoders", "text_encoder_2": "text_encoders",
    "text_encoder_3": "text_encoders",
    "transformer": "diffusion_models", "unet": "diffusion_models",
    "prior": "diffusion_models",
    "image_encoder": "clip_vision",
    "controlnet": "controlnet",
}

# GGUF general.architecture -> category (step 6)
GGUF_DIFFUSION_ARCHS = {
    "flux", "sd1", "sd2", "sd3", "sdxl", "stable_diffusion", "sd",
    "wan", "qwen_image", "ltxv", "hunyuan", "hunyuan_video", "hidream",
    "cosmos", "lumina2", "aura", "auraflow", "pixart", "chroma", "omnigen",
}
GGUF_TEXT_ARCHS = {"clip", "t5", "t5encoder", "umt5", "byt5", "bert"}
GGUF_LLM_ARCHS = {
    "llama", "llama4", "qwen2", "qwen2moe", "qwen2vl", "qwen3", "qwen3moe",
    "deepseek", "deepseek2", "deepseek3", "gemma", "gemma2", "gemma3",
    "mistral", "mixtral", "phi2", "phi3", "phimoe", "gpt2", "gptneox",
    "falcon", "starcoder", "starcoder2", "command-r", "cohere", "cohere2",
    "olmo", "olmo2", "granite", "granitemoe", "internlm2", "stablelm",
    "mamba", "rwkv6", "glm4", "chatglm", "minicpm", "minicpm3", "nemotron",
    "exaone", "baichuan", "orion", "plamo", "smollm3",
}

# Recognised architectures, in one set: read_gguf_metadata stops early on a hit, and keeps
# reading on a miss so the structural fallback has hyperparameters to work with.
_GGUF_KNOWN_ARCHS = GGUF_DIFFUSION_ARCHS | GGUF_TEXT_ARCHS | GGUF_LLM_ARCHS

# config.json architectures -> category (step 5)
CONFIG_TEXT_ARCHS = {
    "CLIPModel", "CLIPTextModel", "CLIPTextModelWithProjection",
    "T5EncoderModel", "UMT5EncoderModel", "MT5EncoderModel", "T5Model",
}
CONFIG_VISION_ARCHS = {"CLIPVisionModel", "CLIPVisionModelWithProjection",
                       "SiglipVisionModel", "SiglipModel"}
# HF-format LLM repos are vllm's problem, not comfyui's: inventory-only `llm`
CONFIG_LLM_SUFFIXES = ("ForCausalLM", "ForConditionalGeneration",
                       "LMHeadModel", "ForSeq2SeqLM")

# CTranslate2 model dirs: a .bin beside one of these signature vocabulary files (step 3).
# The SIBLING is the evidence -- the weights file is an opaque CT2 blob that is not a
# pickle and carries no readable structure of its own.
CT2_SIBLINGS = ("vocabulary.txt", "vocabulary.json",
                "shared_vocabulary.txt", "shared_vocabulary.json")

# multi-part weight files: model-00001-of-00002.safetensors, *-00001-of-00003.gguf, ...
SHARDED_RE = re.compile(r"-\d{4,6}-of-\d{4,6}\.[A-Za-z0-9]+$")

# ESRGAN-style upscaler scale-factor tag on an otherwise arch-unknown .pth: a leading
# "4x"/"2x"/"8x"/"16x" or a trailing "x4"/"x2"/... (e.g. 4x-ClearRealityV1, RealESRGAN_x4).
# Matched on the normalized stem (non-alnum -> "_"), only AFTER lora/vae/controlnet/text
# checks have excluded genuine models, so a bare scale tag is a strong upscaler signal.
UPSCALE_SCALE_RE = re.compile(
    r"(?:^|_)(?:2|4|8|16)x(?=$|_|[a-z])|(?:^|_)x(?:2|4|8|16)(?=$|_|[a-z])")

# lllyasviel ControlNet-v1-1 filenames: control_v11p_sd15_softedge, control_v11f1e_sd15_tile,
# control_v11p_sd15s2_lineart_anime, plus the older control_sd15_* / control_sd21_* naming.
# None contain the substring "controlnet", so the plain keyword rule misses them all.
CONTROLNET_NAME_RE = re.compile(r"^control_(?:v\d|sd\d|lora)")

# ControlNet-AUX annotator families the token rules cannot see, matched on the normalized
# stem (so `_` is the only boundary character) ahead of the WEAK ControlNet signals:
#   * depth_anything -- carries a bare `depth` token, which the ControlNet rule claims
#     first (control_v11f1p_sd15_depth genuinely IS a ControlNet), so the family name has
#     to be tested before that rule ever runs. Also covers metric_video_depth_anything_*.
#   * zoed -- ZoeDepth ships as ZoeD_M12_N.pt, which normalizes to `zoed`, never `zoe`.
#   * annotator(s) -- lllyasviel/Annotators, reached through the REPO-NAME pass: erika.pth,
#     netG.pth and sk_model.pth carry no signal of their own, and the repo is the only
#     thing that says what they are.
# All distinctive multi-character names, so no control_* ControlNet filename contains one.
ANNOTATOR_NAME_RE = re.compile(r"(?:^|_)(?:depth_anything|zoed|annotators?)(?:$|_)")

# AnimateDiff temporal stack, IN UNET-BLOCK CONTEXT. The bare `.motion_modules.` /
# `.temporal_transformer.` substrings are not enough: Metric-Video-Depth-Anything-Large
# names its temporal head `head.motion_modules.0.temporal_transformer.*` and was filed as
# an AnimateDiff motion module on that alone. AnimateDiff modules and motion LoRAs both
# hang off a UNet's down_blocks/mid_block/up_blocks, and a depth model's `head.`/
# `pretrained.` trunk cannot reach that shape -- so the block prefix IS the discriminator.
ANIMATEDIFF_KEY_RE = re.compile(
    r"(?:^|\.)(?:down_blocks|mid_block|up_blocks)\.(?:[^.]+\.)*"
    r"(?:motion_modules|temporal_transformer)\.")

# The LoRA processor that separates an AnimateDiff motion LORA from the motion MODULE it
# adapts -- same tensor layout otherwise. Note the spelling: `.to_k_lora.down.`, never
# `.lora_down`, which is why the generic lora rule never sees these files.
MOTION_LORA_MARKERS = ("to_q_lora", "to_k_lora", "to_v_lora", "to_out_lora",
                       "_lora.down.", "_lora.up.")

# torch.nn.DataParallel wraps EVERY key of the model it holds in `module.`, and a
# checkpoint saved straight off a DataParallel model carries that wrapper forever --
# detection_Resnet50_Final.pth inspects as prefixes `_metadata, module` with keys like
# `module.BboxHead.0.conv1x1.weight`. It is pure PACKAGING: it says nothing about what
# the model is, and every prefix rule is blind while it is there. So it is stripped
# ONCE, in the shared key classifier, ahead of all rules -- doing it per-rule would
# oblige every future rule to remember to. Only the CLASSIFIER sees the stripped names;
# `inspect` still prints the raw keys, because what is on disk is what a human reading
# the evidence is trying to match against.
DATAPARALLEL_PREFIX = "module."


def strip_dataparallel(keys) -> list:
    """Drop a leading `module.` from every key (torch DataParallel packaging)."""
    n = len(DATAPARALLEL_PREFIX)
    return [k[n:] if k.startswith(DATAPARALLEL_PREFIX) else k for k in keys]


# REAL autoencoder anatomy, in THREE spellings: ldm (`encoder.down.` / `decoder.up.`),
# diffusers (`encoder.down_blocks.` / `decoder.up_blocks.`) and the causal-video
# autoencoders (`encoder.downsamples.` / `decoder.upsamples.`), plus the quantisation
# convs that only a LATENT autoencoder has (`quant_conv.` / `post_quant_conv.`).
#
# Required because "has an encoder and a decoder" is not "is a VAE". parsing_parsenet.pth
# -- ParseNet, a face-PARSING/segmentation net, 85.3 MB -- has prefixes
# `body, decoder, encoder, out_img_conv, out_mask_conv` and won vae@0.6 x 20 parts against
# its own correct filename (facedetection, LoFi-capped at 0.3 x 5). Plenty of models are
# shaped like an autoencoder; only an autoencoder has an autoencoder's insides. Without
# anatomy the vae rule simply does not fire -- it abstains rather than guessing some other
# category -- and the naming measures decide.
#
# The Wan spelling is here because the quant convs are NOT: a field dump of the real
# wan_2.1_vae.safetensors (Jei, s33) has top-level prefixes `conv1, conv2, decoder,
# encoder` with keys like `decoder.upsamples.0.residual.0.gamma` and NO quant_conv /
# post_quant_conv anywhere -- so the resample stack is the only anatomy such a file has
# to offer. PROVENANCE DIFFERS between the two halves of that pair: `decoder.upsamples.`
# is PROVEN (it is in the dump); `encoder.downsamples.` is INFERRED from the encoder/
# decoder symmetry every one of these autoencoders is built with, and is unconfirmed.
# Both are narrow enough to be safe either way -- ParseNet, the counterexample this whole
# rule exists for, has neither (its encoder/decoder are bare `encoder.0` / `decoder.0`).
VAE_ANATOMY_PREFIXES = ("encoder.down.", "decoder.up.",
                        "encoder.down_blocks.", "decoder.up_blocks.",
                        "encoder.downsamples.", "decoder.upsamples.")


def _has_vae_anatomy(keys) -> bool:
    """True when an encoder/decoder pair is backed by real autoencoder internals.

    `quant_conv.` is a substring test on purpose: it covers `post_quant_conv.` in the
    same breath, and both sit at the state-dict root in ldm and diffusers alike.
    """
    return any(k.startswith(VAE_ANATOMY_PREFIXES) or "quant_conv." in k for k in keys)


# RetinaFace / facexlib detection heads. These three head names together ARE the
# RetinaFace signature (detection_Resnet50_Final.pth, detection_mobilenet0.25_Final.pth);
# nothing else in a model collection names a tensor `BboxHead`. Only visible once the
# DataParallel wrapper above is stripped -- which is exactly how these files ship.
RETINAFACE_HEAD_PREFIXES = ("BboxHead.", "ClassHead.", "LandmarkHead.")

# Convolutional Pose Machine / OpenPose stage convolutions. `facenet.pth` (153.7 MB) is,
# despite its name, a CPM LANDMARK model: prefixes `Mconv1_stage2 ... Mconv7_stage6`, keys
# like `Mconv1_stage2.bias`. The openpose annotators already routed here BY NAME
# (body_pose_model.pth / hand_pose_model.pth) are the same architecture family and spell
# their stages `model1_1.0.weight`, so one rule covers both -- and now covers them by
# CONTENT, which is what a renamed or oddly-named copy needs. Anchored at the start of the
# key and requiring the stage digits, so an ordinary `model.`/`model0.` prefix cannot match.
POSE_STAGE_KEY_RE = re.compile(r"^(?:Mconv\d+_stage\d+|model\d+_\d+)\.")
# WHERE they land. The openpose estimators already live in controlnet_aux, so a CPM
# landmark net joins them. This placement is one constant on purpose: it awaits Jei's
# confirmation, and changing it is a one-line change here, nowhere else.
POSE_STAGE_CATEGORY = "controlnet_aux"

# generic basenames that must never be used as link names (provenance rule)
GENERIC_STEM_RE = re.compile(
    r"^(model|pytorch_model|diffusion_pytorch_model|tf_model|flax_model|"
    r"adapter_model)([._-](fp16|fp32|bf16))?$")


# --------------------------------------------------------------------------- logging

def log(msg: str) -> None:
    print(msg, flush=True)


# --------------------------------------------------------------------------- sources

@dataclass
class SourceFile:
    identity: str        # content identity (registry key)
    path: Path           # resolved real path (blob / real file) -- link target
    link_name: str       # preferred basename for the tree link (provenance-resolved)
    display: str         # human-readable provenance
    rel_dir_parts: tuple # lowercase dir segments for step-1 classification
    config_dir: Path     # dir to check for sibling config.json / CT2 vocabularies
    origin: str          # "hf" | "local"
    sharded: bool = False        # multi-part file: classified but never linked
    component: str | None = None  # diffusers component subdir (repo has model_index.json)


@dataclass
class RepoUnit:
    """A repo-level diffusers unit (snapshot dir with a root model_index.json)."""
    identity: str        # "diffusers:<org>/<repo>@<revision>"
    display: str
    source: str          # snapshot dir
    members: list        # identities of its component weight files


def _sanitize(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-")


def preferred_link_name(repo_tail: str | None, rel: Path) -> str:
    """Generic basenames ALWAYS get a provenance-derived name; others keep theirs."""
    if not GENERIC_STEM_RE.match(rel.stem.lower()):
        return rel.name
    parts = []
    if repo_tail:
        parts.append(repo_tail)
    dirs = rel.parts[:-1]
    if dirs:
        parts.append("-".join(dirs))
    if not parts:
        return rel.name  # local file at models root: no provenance to derive from
    if len(parts) < 2:
        parts.append(rel.stem)  # keep the stem when only one provenance element
    return _sanitize("--".join(parts)) + rel.suffix


def scan_hf_cache(cache_dir: Path) -> tuple[list[SourceFile], list[RepoUnit]]:
    """Walk the standard hub layout: models--org--repo/snapshots/<rev>/<path> -> blobs/<sha>.

    Dedupes files by blob identity (the same blob referenced from several revisions or
    several repos is scanned once). Snapshots with a root model_index.json additionally
    yield a repo-level diffusers RepoUnit listing their member identities."""
    sources: dict[str, SourceFile] = {}
    units: list[RepoUnit] = []
    if not cache_dir.is_dir():
        return [], []
    for repo_dir in sorted(p for p in cache_dir.iterdir()
                           if p.is_dir() and p.name.startswith("models--")):
        repo_display = repo_dir.name[len("models--"):].replace("--", "/", 1)
        repo_tail = repo_display.split("/", 1)[-1]
        snaps = repo_dir / "snapshots"
        if not snaps.is_dir():
            continue
        for snap in sorted(p for p in snaps.iterdir() if p.is_dir()):
            is_diffusers = (snap / "model_index.json").is_file()
            members: list[str] = []
            for f in sorted(snap.rglob("*")):
                if not (f.is_file() or f.is_symlink()):
                    continue
                if f.suffix.lower() not in WEIGHT_EXTS:
                    continue
                real = f.resolve()
                if not real.is_file():
                    continue  # dangling snapshot link (blob pruned) -- not a source
                if real.parent.name == "blobs":
                    identity = "hf:" + real.name  # blob filename IS its sha256
                else:  # non-standard layout; fall back to a stat key
                    st = real.stat()
                    identity = f"hf:{real.name}|{st.st_size}|{st.st_mtime_ns}"
                members.append(identity)
                if identity in sources:
                    continue
                rel = f.relative_to(snap)
                sources[identity] = SourceFile(
                    identity=identity,
                    path=real,
                    link_name=preferred_link_name(repo_tail, rel),
                    display=f"{repo_display}/{rel}",
                    rel_dir_parts=tuple(s.lower() for s in rel.parts[:-1]),
                    config_dir=f.parent,
                    origin="hf",
                    sharded=bool(SHARDED_RE.search(f.name)),
                    component=(rel.parts[0] if is_diffusers and len(rel.parts) > 1
                               else None),
                )
            if is_diffusers:
                units.append(RepoUnit(
                    identity=f"diffusers:{repo_display}@{snap.name}",
                    display=f"{repo_display}@{snap.name[:8]}",
                    source=str(snap),
                    members=sorted(set(members)),
                ))
    return list(sources.values()), units


def scan_models_dir(models_dir: Path) -> list[SourceFile]:
    """Walk the optional local models dir. Absent dir -> silently empty."""
    sources: list[SourceFile] = []
    if not models_dir.is_dir():
        return sources
    for f in sorted(models_dir.rglob("*")):
        if not f.is_file() or f.suffix.lower() not in WEIGHT_EXTS:
            continue
        rel = f.relative_to(models_dir)
        st = f.stat()
        sources.append(SourceFile(
            identity=f"local:{rel}|{st.st_size}|{st.st_mtime_ns}",
            path=f.resolve(),
            link_name=preferred_link_name(None, rel),
            display=str(rel),
            rel_dir_parts=tuple(s.lower() for s in rel.parts[:-1]),
            config_dir=f.parent,
            origin="local",
            sharded=bool(SHARDED_RE.search(f.name)),
        ))
    return sources


def collect_sources(cache_dir: Path,
                    models_dir: Path) -> tuple[list[SourceFile], list[RepoUnit]]:
    files, units = scan_hf_cache(cache_dir)
    return files + scan_models_dir(models_dir), units


# --------------------------------------------------------------------- format readers
# Module-level so tests can wrap them with counters (incremental runs must not call them).

def read_safetensors_header(path: Path) -> dict:
    """Read ONLY the 8-byte length + JSON header of a .safetensors file."""
    with open(path, "rb") as f:
        raw = f.read(8)
        if len(raw) < 8:
            raise ValueError("truncated safetensors")
        n = int.from_bytes(raw, "little")
        if not 0 < n <= 100_000_000:
            raise ValueError(f"implausible safetensors header length {n}")
        return json.loads(f.read(n))


def read_gguf_metadata(path: Path, max_kv: int = 256) -> dict:
    """Read GGUF magic + metadata key/values (scalar + string; arrays skipped)."""
    meta: dict = {}
    with open(path, "rb") as f:
        if f.read(4) != b"GGUF":
            raise ValueError("not a GGUF file")
        version, = struct.unpack("<I", f.read(4))
        if version < 2:
            raise ValueError(f"unsupported GGUF version {version}")
        _tensor_count, kv_count = struct.unpack("<QQ", f.read(16))

        scalar = {0: ("<B", 1), 1: ("<b", 1), 2: ("<H", 2), 3: ("<h", 2),
                  4: ("<I", 4), 5: ("<i", 4), 6: ("<f", 4), 7: ("<?", 1),
                  10: ("<Q", 8), 11: ("<q", 8), 12: ("<d", 8)}

        def read_str() -> str:
            n, = struct.unpack("<Q", f.read(8))
            if n > 65536:
                raise ValueError("implausible GGUF string length")
            return f.read(n).decode("utf-8", "replace")

        def read_value(vtype: int, store: bool):
            if vtype in scalar:
                fmt, size = scalar[vtype]
                v, = struct.unpack(fmt, f.read(size))
                return v if store else None
            if vtype == 8:  # string
                s = read_str()
                return s if store else None
            if vtype == 9:  # array: elem-type u32 + count u64 + elems (skipped)
                etype, = struct.unpack("<I", f.read(4))
                count, = struct.unpack("<Q", f.read(8))
                if count > 1_000_000:
                    raise ValueError("implausible GGUF array length")
                for _ in range(count):
                    read_value(etype, store=False)
                return None
            raise ValueError(f"unknown GGUF value type {vtype}")

        for _ in range(min(kv_count, max_kv)):
            key = read_str()
            vtype, = struct.unpack("<I", f.read(4))
            # The tokenizer entries hold the whole vocabulary as arrays. Parsing those
            # purely to advance the cursor costs more than every other key combined, and
            # nothing after them is needed -- so note that a tokenizer exists (evidence
            # in itself: a language model has one, an image model does not) and stop.
            if key.startswith("tokenizer."):
                meta["__tokenizer__"] = True
                break
            val = read_value(vtype, store=True)
            if val is not None:
                meta[key] = val
            # Stop as soon as the architecture is one we RECOGNISE -- nothing later can
            # change the answer. For an UNKNOWN architecture keep reading: the structural
            # fallback in classify_gguf needs the hyperparameters that follow, and those
            # sit before the tokenizer in every GGUF writer's ordering. (Breaking here
            # unconditionally is what made `step35` and `minimax-m2` unclassifiable --
            # the evidence was in the file, we just stopped one key too early.)
            arch = str(meta.get("general.architecture", "")).lower()
            if arch and arch in _GGUF_KNOWN_ARCHS:
                break
    return meta


def read_config_json(path: Path) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


# ----------------------------------------------------------------------- classification

def classify_by_segments(src: SourceFile) -> str | None:
    for seg in src.rel_dir_parts:
        cat = SEGMENT_MAP.get(seg)
        if cat:
            return cat
    # Qualified segments (nai_hypernetworks) only AFTER every segment has failed the exact
    # test, so an exact match anywhere in the path still outranks a qualified one -- a
    # file under nai_hypernetworks/loras/ is a lora, not a hypernetwork.
    for seg in src.rel_dir_parts:
        seg = re.sub(r"[^a-z0-9]+", "_", seg)   # sdxl-loras and sdxl_loras are one dir name
        # Same precedence the filename rules use: a control_lora / control_v11 segment
        # names a ControlNet, and must not be read as a lora by the suffix match below.
        if CONTROLNET_NAME_RE.search(seg):
            return "controlnet"
        m = SEGMENT_SUFFIX_RE.search(seg)
        if m:
            return SEGMENT_MAP[m.group(1)]
    return None


def repo_of(display: str) -> str:
    """`org/repo/sub/file.ext` -> `repo` (the hf-provenance display form)."""
    parts = display.split("/")
    return parts[1] if len(parts) >= 3 else parts[0]


def classify_by_filename(name: str) -> str | None:
    norm = re.sub(r"[^a-z0-9]+", "_", Path(name).stem.lower()).strip("_")
    tokens = set(t for t in norm.split("_") if t)
    if "clip_vision" in norm:                       # before any bare-clip rule
        return "clip_vision"
    # control-lora is a ControlNet distributed in LoRA form and loads from
    # models/controlnet, so it must be tested BEFORE the lora rule -- which would
    # otherwise swallow it on the bare "lora" token and file it where no
    # ControlNet loader looks.
    if "control_lora" in norm:
        return "controlnet"
    if tokens & {"lora", "loras"} or "lightning_lora" in norm:
        return "loras"
    if "taesd" in tokens:
        return "vae_approx"
    if "vae" in tokens:
        return "vae"
    # The literal word "controlnet" settles the question outright, so it is tested on its
    # own and outranks everything below -- a depth_anything CONTROLNET is a ControlNet.
    if "controlnet" in norm:
        return "controlnet"
    # Annotator FAMILY names, ahead of the weak ControlNet signals below: a bare `depth`
    # token is a much softer claim than a named estimator family (see ANNOTATOR_NAME_RE).
    if ANNOTATOR_NAME_RE.search(norm):
        return "controlnet_aux"
    # The weaker ControlNet spellings: lllyasviel's ControlNet-v1-1 filenames
    # (control_v11p_sd15_softedge, control_v11f1e_sd15_tile, control_v11p_sd15s2_
    # lineart_anime, ...), the bare task token, and the T2I-Adapter/control-lora forms
    # -- none of which contain the substring "controlnet".
    if (tokens & {"canny", "depth"} or CONTROLNET_NAME_RE.search(norm)
            or "t2iadapter" in norm or "t2i_adapter" in norm):
        return "controlnet"
    if (tokens & {"t5", "umt5", "byt5", "t5xxl"}
            or "clip_l" in norm or "clip_g" in norm
            or "text_encoder" in norm or "qwen_2_5_vl" in norm):
        return "text_encoders"
    # ---- auxiliary detector / estimator models (Impact-Pack / ReActor / ControlNet-aux).
    # These are .pt/.pth pickles the scanner never content-sniffs, so filename is the
    # only signal -- same idiom as the esrgan/taesd rules above.
    # Ultralytics / YOLO detectors -> Impact-Pack models/ultralytics/{bbox,segm}
    # ("yolo" substring catches yolov5/8/9, yolo11, yolov11, yolox, ... in one shot).
    if "yolo" in norm:
        if "segm" in norm or tokens & {"seg", "segmentation"}:
            return "ultralytics/segm"
        return "ultralytics/bbox"
    # SAM (Segment Anything) -> Impact-Pack models/sams
    if ("sam_vit" in norm or "mobile_sam" in norm or "sam_hq" in norm
            or "sam2_hiera" in norm or "sam2" in tokens
            or ("sam" in tokens and "vit" in tokens)):
        return "sams"
    # BiSeNet / ParseNet face-parsing (facexlib) -> models/facedetection
    if tokens & {"parsenet", "bisenet"} or "parsing_parsenet" in norm \
            or "parsing_bisenet" in norm:
        return "facedetection"
    # OpenPose / DWPose body & hand estimators -> ControlNet-aux annotator weights
    if ("openpose" in norm or "dwpose" in norm
            or "body_pose" in norm or "hand_pose" in norm
            or ("pose" in tokens and tokens & {"body", "hand", "model"})):
        return "controlnet_aux"
    # Depth / edge / segmentation ESTIMATORS (lllyasviel/Annotators et al) -> the same
    # controlnet_aux tree. Named families only -- deliberately NOT a bare "depth" token,
    # which belongs to the ControlNet rule above (control_v11f1p_sd15_depth is a
    # ControlNet, not an annotator). These stay BELOW that rule on purpose: control_sd15_hed
    # and control_v11p_sd15_mlsd are ControlNets named after the annotator they consume,
    # so the ControlNet spelling must get first refusal. Families that cannot collide
    # that way live in ANNOTATOR_NAME_RE and are tested earlier.
    if tokens & {"midas", "dpt", "zoe", "leres", "hed", "pidinet", "mlsd",
                 "uniformer", "oneformer", "normalbae"}:
        return "controlnet_aux"
    # Face RESTORATION (CodeFormer / GFPGAN / RestoreFormer) -> models/facerestore_models,
    # where ReActor and the facerestore nodes look. Distinct from facedetection above,
    # which holds the parsing/detection weights.
    # Substring, not token: these ship with the version welded to the name
    # (GFPGANv1.4.pth normalizes to "gfpganv1_4", so "gfpgan" is never its own token).
    if "codeformer" in norm or "gfpgan" in norm or "restoreformer" in norm:
        return "facerestore_models"
    # ESRGAN-family upscalers, incl. arch-unknown 4x/2x/x4 .pth files
    if ("esrgan" in norm or tokens & {"upscale", "upscaler"}
            or UPSCALE_SCALE_RE.search(norm)):
        return "upscale_models"
    if tokens & {"embedding", "embeddings"} or "textual_inversion" in norm:
        return "embeddings"
    if "hypernetwork" in norm:
        return "hypernetworks"
    if "photomaker" in tokens:
        return "photomaker"
    if "gligen" in tokens:
        return "gligen"
    return None


def classify_safetensors_header(header: dict) -> str | None:
    meta = header.get("__metadata__") or {}
    arch = str(meta.get("modelspec.architecture", "")).lower()
    if arch:
        if "lora" in arch:
            return "loras"
        if "controlnet" in arch:
            return "controlnet"
        if arch.endswith("vae") or "/vae" in arch:
            return "vae"

    # ONE normalization pass, ahead of every rule: a checkpoint saved off a
    # torch.nn.DataParallel model has `module.` welded to the front of every key, which
    # blinds all of the prefix rules below at once (see DATAPARALLEL_PREFIX).
    keys = strip_dataparallel(k for k in header if k != "__metadata__")
    # Only DOTTED keys have a prefix. Tensor names are always module-scoped, so this
    # costs nothing there -- but object-pickles reach this classifier through
    # classify_pickle with plain ATTRIBUTE names harvested from __setstate__, and a bare
    # `encoder`/`decoder` attribute pair would otherwise synthesize "encoder."/"decoder."
    # and be read as an autoencoder state dict.
    prefixes = {k.split(".", 1)[0] + "." for k in keys if "." in k}

    def any_start(*pfx):
        return any(k.startswith(pfx) for k in keys)

    # loras first: lora tensor names embed base-model names (double_blocks etc.)
    if any(k.startswith(("lora_unet_", "lora_te")) or ".lora_A" in k
           or ".lora_B" in k or ".lora_down" in k or ".lora_up" in k for k in keys):
        return "loras"
    if any_start("model.diffusion_model."):        # full checkpoint bundle
        return "checkpoints"
    # AnimateDiff motion modules ride inside a UNet-shaped state dict (down_blocks./
    # mid_block./up_blocks.), so they must be tested BEFORE any generic block rule --
    # the giveaway is the temporal stack hanging off each block (ANIMATEDIFF_KEY_RE).
    if any(ANIMATEDIFF_KEY_RE.search(k) for k in keys):
        # ...and a motion LORA has the SAME layout as the motion module it adapts, so the
        # only thing separating them is the LoRA processor hanging off each attention
        # block. Without this the whole AnimateDiff-Motion-LoRAs family filed as motion
        # MODULES, where the loader that wants them (AnimateDiffLoraLoader) never looks.
        if any(m in k for k in keys for m in MOTION_LORA_MARKERS):
            return "animatediff_motion_lora"
        return "animatediff_models"
    if any_start("control_model."):
        return "controlnet"
    # diffusers-format ControlNet: the zero-conv trunk that makes it a ControlNet rather
    # than the UNet it is otherwise shaped like. `controlnet_blocks.` /
    # `controlnet_x_embedder.` are the DiT-era spelling of the same idea (InstantX's
    # Qwen-Image ControlNets) -- and they must keep their place ABOVE the bare-DiT rules
    # below, which see img_in./txt_in./transformer_blocks. and call it a diffusion model
    # at 0.99: a DiT ControlNet has all of those too, plus the trunk that overrides them.
    if any_start("controlnet_cond_embedding.", "controlnet_down_blocks.",
                 "controlnet_mid_block.", "controlnet_blocks.",
                 "controlnet_x_embedder."):
        return "controlnet"
    # ---- auxiliary DETECTOR / ESTIMATOR architectures. They sit above the generic model
    # shapes below because they are unmistakable -- nothing else names a tensor `BboxHead`
    # or `Mconv3_stage4` -- and because both families ship as bare .pth files whose only
    # other signal is a filename that can be actively misleading (`facenet.pth` is a pose
    # model, not a face-recognition net).
    if any_start(*RETINAFACE_HEAD_PREFIXES):
        return "facedetection"
    if any(POSE_STAGE_KEY_RE.match(k) for k in keys):
        return POSE_STAGE_CATEGORY
    # A vision tower is evidence that a model CAN SEE, not that it IS an image encoder.
    # A multimodal LLM ships one bolted onto a language decoder (model.layers./
    # language_model.) through a projector -- and one of those, a gemma-3-12b shipped as
    # an LTX-2 text encoder, scored clip_vision@0.99 purely because `vision_model.` was
    # present (Jei's verdict, s30: it is a text encoder). The decoder is what settles it;
    # a real CLIP-Vision / IP-Adapter image_encoder has a vision tower and NOTHING else.
    if any_start("vision_model."):
        if any_start("model.layers.", "language_model.", "multi_modal_projector."):
            return "text_encoders"
        return "clip_vision"
    # LTX-2 projection layer: bridges text embeddings into the AV transformer. Loads from
    # ComfyUI/models/text_encoders despite not being an encoder itself.
    if any_start("text_embedding_projection."):
        return "text_encoders"
    if any_start("diffusion_model.", "double_blocks.", "joint_blocks."):
        return "diffusion_models"
    # BARE DENOISERS. A *checkpoint* is defined by carrying several components at once
    # (unet + first_stage_model + conditioner); a file holding only the denoiser is a
    # diffusion model however big it is. These are the modern DiT layouts: Qwen-Image
    # (transformer_blocks. + img_in/txt_in), Wan (patch_embedding. + time_embedding.),
    # and the `net.`-rooted stacks with adaLN modulation.
    if any_start("transformer_blocks.") and any_start("img_in.", "txt_in."):
        return "diffusion_models"
    if any_start("patch_embedding.") and any_start("time_embedding."):
        return "diffusion_models"
    if any(k.startswith("net.blocks.") and "adaln_modulation" in k for k in keys):
        return "diffusion_models"
    if any_start("encoder.block.", "decoder.block."):   # T5-style, before generic vae
        return "text_encoders"
    if any_start("first_stage_model."):
        return "vae"
    # An encoder/decoder PAIR is a shape, not an identity: it must be backed by real
    # autoencoder internals before it may claim `vae` (see VAE_ANATOMY_PREFIXES). Bare
    # encoder./decoder. falls through to abstain, and naming gets to decide.
    if ("decoder." in prefixes and "encoder." in prefixes
            and _has_vae_anatomy(keys)):
        return "vae"
    if any_start("text_model.", "t5.", "enc."):
        return "text_encoders"
    return None


# torch's LEGACY (pre-1.6, `_use_new_zipfile_serialization=False`) container is not a zip:
# it is several pickles written back to back -- MAGIC_NUMBER, PROTOCOL_VERSION, sys_info,
# THEN the payload, then the storage-key list, then raw tensor bytes. A reader that loads
# one pickle and stops therefore gets the magic NUMBER and nothing else, which is exactly
# how facenet.pth and detection_Resnet50_Final.pth surfaced as "(none)" on 150 MB files.
# These two constants identify the preamble so the payload can be told apart from it.
TORCH_LEGACY_MAGIC = 0x1950A86A20F9469CFC6C
TORCH_LEGACY_SYSINFO_KEYS = {"protocol_version", "little_endian", "type_sizes"}
# 4 covers magic + version + sys_info + payload; a couple spare for writer variations.
LEGACY_MAX_PICKLES = 6


def _is_legacy_preamble(obj) -> bool:
    """True for the header objects torch writes AHEAD of the payload."""
    if isinstance(obj, bool):
        return False
    if isinstance(obj, int):
        return True                      # MAGIC_NUMBER / PROTOCOL_VERSION
    if isinstance(obj, dict) and obj and set(obj) <= TORCH_LEGACY_SYSINFO_KEYS:
        return True                      # sys_info -- its keys are NOT tensor names
    return False


def _restricted_unpickle(fileobj, max_objects: int = 1) -> tuple[set, set]:
    """Recover a pickle's state-dict KEYS and the MODULE paths it references, without
    executing any of its payload.

    `max_objects` > 1 reads pickles SEQUENTIALLY from one stream (the legacy torch
    layout above), skipping preamble objects and stopping at the first payload that
    yields keys. Every object goes through the same restricted machinery.

    SECURITY: `.pt`/`.pth` are Python pickles, and a normal load executes arbitrary code
    -- unacceptable for files pulled off the internet. Here `find_class` never imports or
    resolves anything: it records the module path (a strong classification signal in its
    own right -- ultralytics.nn.tasks.DetectionModel et al) and returns an inert stub.
    `persistent_load` (torch tensor storages) returns one too. Every REDUCE / NEWOBJ
    therefore lands on the stub, never attacker code. Ported from droste-civitai-adopt's
    `_restricted_unpickle_keys`, which has been in service on real CivitAI downloads.

    The stub is a dynamically-built TYPE, not an instance. `NEWOBJ`/`NEWOBJ_EX` -- what
    protocol >= 2 emits for an ordinary object, and so what `torch.save` writes for a
    serialized MODEL rather than a state dict -- require the class argument to be a real
    type and abort the whole load otherwise. Returning an instance therefore made every
    object-pickle (Ultralytics, segment_anything, gfpgan) unreadable before it could
    yield a single module path -- exactly the files this pass exists for. Subclassing
    per (module, name) satisfies the opcodes while still importing nothing.
    """
    keys: set = set()
    modules: set = set()

    class _Inert:
        def __new__(cls, *a, **k):
            return object.__new__(cls)        # NEWOBJ forwards ctor args here
        def __init__(self, *a, **k):
            pass                              # ... and REDUCE forwards them here
        def __call__(self, *a, **k):
            return self                       # call on an inert instance -> inert
        def __setitem__(self, key, value):
            if isinstance(key, str):
                keys.add(key)
        def __setstate__(self, state):
            if isinstance(state, dict):
                keys.update(k for k in state if isinstance(k, str))
        def append(self, *a):
            pass
        def extend(self, *a):
            pass
        def __getattr__(self, name):
            return self                       # any attribute -> inert

    stubs: dict = {}

    class _Restricted(pickle.Unpickler):
        def find_class(self, module, name):
            modules.add(f"{module}.{name}".lower())
            stub = stubs.get((module, name))
            if stub is None:                  # a TYPE, and still NEVER imported
                stub = stubs[(module, name)] = type(name, (_Inert,),
                                                    {"__module__": module})
            return stub
        def persistent_load(self, pid):
            return _Inert()

    for n in range(max_objects):
        try:
            obj = _Restricted(fileobj).load()
        except Exception:
            # Past the payload a legacy stream is RAW STORAGE BYTES, so the read that
            # walks off the end is expected once objects have come back. Failing on the
            # FIRST one is different: the file is not a pickle at all, and that error is
            # the most informative thing we have -- raise it so the caller warns instead
            # of recording a silent blank. (A stream that reads cleanly but yields
            # nothing is caught by _signals_or_raise, which can say so precisely.)
            if n == 0:
                raise
            break
        if max_objects > 1 and _is_legacy_preamble(obj):
            continue
        if max_objects > 1 and isinstance(obj, list):
            break     # the storage-key list: the payload is behind us and what follows
                      # is RAW TENSOR BYTES, which must never be fed to the unpickler
                      # (a stray length-prefixed opcode there could ask for a huge read)
        # a plain dict / OrderedDict may come back concrete; harvest its keys (and one
        # level of nesting, e.g. {"state_dict": {...}}).
        stack, seen = [obj], 0
        while stack and seen < 8:
            cur = stack.pop()
            seen += 1
            if isinstance(cur, dict):
                keys.update(k for k in cur if isinstance(k, str))
                stack.extend(v for v in cur.values() if isinstance(v, dict))
        if keys:
            break
    return keys, modules


def _is_ct2_layout(src: SourceFile) -> bool:
    """A .bin sitting beside a CTranslate2 signature vocabulary file.

    Deliberately NOT keyed on the filename being exactly `model.bin`. That was the
    original test and it missed real files -- a faster-whisper export renamed to
    `faster_whisper_large_v2.bin` sat next to its own `vocabulary.txt` and still fell
    through to unclassified. The sibling was always the evidence; the filename never was.
    """
    return (Path(src.display).suffix.lower() == ".bin"
            and any((src.config_dir / v).is_file() for v in CT2_SIBLINGS))


def _signals_or_raise(keys: set, modules: set, what: str) -> tuple[set, set]:
    """Nothing harvested is a RESULT that must be reported, never a silent blank.

    A read that succeeds and yields nothing looked identical to a file with no
    recognisable structure -- both printed `(none)` and cast no vote -- so a 150 MB
    weight file could report exactly as much as an empty one. Raising puts the reason in
    front of whoever is looking (WARN on sync, `pickle read FAILED ...` in inspect);
    callers already treat a raise as warn-and-continue, so nothing becomes fatal.
    """
    if not keys and not modules:
        raise ValueError(f"empty: {what} yielded no state-dict keys "
                         f"and no module names")
    return keys, modules


def read_pickle_signals(path: Path) -> tuple[set, set]:
    """(state-dict keys, referenced module paths) for a pickled checkpoint.

    Modern torch files are zip archives holding a small `data.pkl`; legacy ones
    (pre-1.6, or `_use_new_zipfile_serialization=False`) are a SEQUENCE of pickles --
    magic number, protocol version, sys_info, payload -- followed by the raw storages.
    Either way only the pickle STRUCTURE is read, never the tensor payload, so cost is
    bounded regardless of file size.
    """
    with open(path, "rb") as f:
        head = f.read(8)
    if head[:2] == b"PK":                      # zip archive (modern torch.save)
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if n.endswith("data.pkl")]
            if not names:
                # RAISE, do not return empty. Silently yielding no signals made an
                # unreadable archive indistinguishable from one that genuinely holds
                # nothing recognisable -- both surfaced as "no measure could form a
                # judgement", which hid the failure. Callers already treat a raise as
                # warn-and-continue, so this is loud without being fatal.
                raise ValueError(
                    "zip archive with no data.pkl member; contains: "
                    + ", ".join(z.namelist()[:8]))
            with z.open(names[0]) as fh:
                return _signals_or_raise(*_restricted_unpickle(fh),
                                         what=f"zip member {names[0]}")
    # Non-zip: read the stream as a legacy multi-pickle container. A plain single
    # pickle (what the rest of the world writes, and what the tests hand-build) is just
    # the degenerate case -- its payload is object #1 and the loop stops there.
    with open(path, "rb") as f:
        keys, modules = _restricted_unpickle(f, max_objects=LEGACY_MAX_PICKLES)
    return _signals_or_raise(
        keys, modules,
        what=f"legacy (non-zip) pickle stream, first bytes {head!r},")


# Module paths that identify a model by the code that produced it -- a far stronger
# signal than any filename, and the only content signal for object-pickles (Ultralytics
# serializes a whole model, not a state dict, so there are no tensor-name keys).
PICKLE_MODULE_SIGNALS = (
    ("ultralytics", "segmentationmodel", "ultralytics/segm"),
    ("ultralytics", None, "ultralytics/bbox"),
    ("segment_anything", None, "sams"),
    ("gfpgan", None, "facerestore_models"),
    ("basicsr.archs.rrdbnet_arch", None, "upscale_models"),
)


def classify_pickle(keys: set, modules: set) -> str | None:
    """Classify a pickled checkpoint from its recovered signals."""
    joined = " ".join(sorted(modules))
    for needle, refine, cat in PICKLE_MODULE_SIGNALS:
        if needle in joined:
            if refine is None or refine in joined:
                return cat
            continue
    # State dicts share their tensor-name vocabulary with the safetensors path, so reuse
    # ONE classifier rather than maintaining a parallel set of prefix rules.
    if keys:
        return classify_safetensors_header({k: {} for k in keys})
    return None


# --------------------------------------------------- confidence model (Jei's scheme)
#
# Every applicable measure votes, each emitting (category, rating 0..1). Two tiers:
#
#   HIGH SIGNAL -- evidence EMBEDDED in the weight file (safetensors header, pickle
#   opcodes, GGUF KV). Cannot be altered without rewriting the model itself.
#
#   LOW FIDELITY ("LoFi") -- evidence that lives OUTSIDE it: sidecar files (config.json,
#   model_index.json, CT2 vocabulary siblings) and names (path segments, filename, repo).
#   All independently editable, and routinely edited -- someone forcing a class name to
#   make a loader accept a file produces a sidecar that points confidently at the WRONG
#   answer, which is worse than no sidecar at all. Hence the hard 0.6 ceiling: LoFi is
#   never permitted to express certainty.
#
# Score is computed PER CANDIDATE CATEGORY -- measures vote for different categories, so
# one pooled sum would answer "how much evidence exists" rather than "which answer is
# right". The denominator is ALL applicable parts, so disagreement visibly depresses the
# winner's confidence.
#
# Weights are Jei's, from his judgement of trustworthiness. The arithmetic they produce
# (since Step 2 lowered LOFI_MAX_RATING to 0.3): all six LoFi measures agreeing tops out
# at 6*5*0.3 = 9, while any single embedded measure reaches 18-29.7 even at the generic
# 0.6 rating -- so content always wins, and names decide only where content is absent.
MEASURE_PARTS = {
    "safetensors": 30,   # embedded
    "pickle": 20,        # embedded
    "gguf": 20,          # embedded
    "ct2": 5,            # LoFi: sibling vocabulary files
    "config": 5,         # LoFi: sidecar config.json
    "component": 5,      # LoFi: diffusers component DIR NAME (never opens model_index)
    "segments": 5,       # LoFi: path segments
    "filename": 5,       # LoFi: filename keywords
    "repo": 5,           # LoFi: repo name
}
LOFI_MEASURES = {"ct2", "config", "component", "segments", "filename", "repo"}
# LoFi may never express certainty. Lowered 0.6 -> 0.3 at Step 2 (owner decision, 2026-08-12):
# "directory and file names are simply nothing more than a guess with a slight bias toward
# truth" and "keeping the information is good; trusting it? less so." So the LoFi measures all
# still VOTE and are all still recorded in `signals` -- only what they may CLAIM drops. Parts
# (how much we listen to a KIND of evidence) are untouched; the rating (how sure this instance
# is) is where a "slight bias toward truth" belongs. Effect: six LoFi measures in unanimous
# agreement now total 30x0.3 = 9.0 against a single GENERIC content read at 30x0.6 = 18.0 --
# content wins 2:1 where it used to tie. One constant; retune here if a re-scan argues for it.
LOFI_MAX_RATING = 0.3
EMBEDDED_MAX_RATING = 0.99   # nor may anything else claim absolute certainty

# Tensor-name prefixes that identify a model outright, vs the generic encoder+decoder
# shape that merely suggests an autoencoder (plenty of models have both).
DISTINCTIVE_PREFIXES = (
    "model.diffusion_model.", "control_model.", "vision_model.", "diffusion_model.",
    "double_blocks.", "joint_blocks.", "encoder.block.", "decoder.block.",
    "first_stage_model.", "text_model.", "t5.", "enc.",
    # diffusers-format ControlNet zero-conv trunk; LTX-2 projection layer; the bare-DiT
    # roots (Qwen-Image / Wan / adaLN `net.` stacks). Each names its model outright, so
    # they belong at the top rating rather than the generic 0.6 inference.
    "controlnet_cond_embedding.", "controlnet_down_blocks.", "controlnet_mid_block.",
    "controlnet_blocks.", "controlnet_x_embedder.",
    "text_embedding_projection.", "transformer_blocks.", "patch_embedding.",
    # ...and the RetinaFace heads, which name their architecture as squarely as any of
    # the above (defined once, up with the rule that matches them).
) + RETINAFACE_HEAD_PREFIXES


def rate_safetensors(header: dict) -> tuple[str, float] | None:
    """Category + how much the evidence deserves to be believed."""
    cat = classify_safetensors_header(header)
    if not cat:
        return None
    # Same normalization the classifier ran on, for the same reason: a DataParallel
    # `module.` wrapper must not cost a file its confidence rating either.
    keys = strip_dataparallel(k for k in header if k != "__metadata__")
    if (any(k.startswith(DISTINCTIVE_PREFIXES) for k in keys)
            # a CPM/OpenPose stage conv names its architecture outright, but it is a
            # PATTERN rather than a fixed prefix, so it cannot live in the tuple above
            or any(POSE_STAGE_KEY_RE.match(k) for k in keys)
            # ...and so is the AnimateDiff temporal stack. Its BLOCK roots (down_blocks./
            # mid_block./up_blocks.) are the generic UNet skeleton and must NEVER join
            # DISTINCTIVE_PREFIXES -- half the collection would inherit 0.99 off them.
            # The composite is the opposite: a temporal_transformer hanging off a UNet
            # block names AnimateDiff as squarely as `control_model.` names a ControlNet,
            # and rating the 8 motion LoRAs + the motion modules at the generic 0.6 left
            # them scoring 0.4-0.45 -- looking like guesses when the shape is conclusive.
            or any(ANIMATEDIFF_KEY_RE.search(k) for k in keys)
            or any(k.startswith(("lora_unet_", "lora_te")) or ".lora_A" in k
                   or ".lora_B" in k or ".lora_down" in k or ".lora_up" in k
                   for k in keys)):
        return cat, EMBEDDED_MAX_RATING
    meta = header.get("__metadata__") or {}
    if str(meta.get("modelspec.architecture", "")):
        return cat, 0.95            # author-declared, but inside the file
    return cat, 0.6                 # generic encoder+decoder inference


def rate_pickle(keys: set, modules: set) -> tuple[str, float] | None:
    """Module paths name the producing code outright; keys inherit the prefix rules."""
    joined = " ".join(sorted(modules))
    for needle, refine, cat in PICKLE_MODULE_SIGNALS:
        if needle in joined and (refine is None or refine in joined):
            return cat, EMBEDDED_MAX_RATING
    if keys:
        # ONE seam: every key-side rating tier (distinctive prefixes, pose stages, the
        # AnimateDiff temporal stack, lora processors) reaches the pickle path through
        # this call, so a lift there needs no twin here -- it arrives capped at 0.95.
        rated = rate_safetensors({k: {} for k in keys})
        if rated:
            # keys are strong but one step below a module path naming the class
            return rated[0], min(rated[1], 0.95)
    return None


def gather_votes(src: SourceFile) -> list[dict]:
    """Run EVERY applicable measure and collect its judgement.

    Since Step 2 these votes DECIDE the category (see sync()); the ladder is only a
    fallback and the source of the naming-vs-content comparison. Deliberately independent
    of classify(): the ladder short-circuits at the first hit, this runs everything, which
    is the whole point -- disagreement is only visible if every measure is asked.

    Costs one extra content read per NEW file -- classification is cached by content
    identity, so it is paid once per file, never on a steady-state re-scan (there is a test
    asserting that). Collapsing the two passes into one is now possible but deliberately
    deferred: measured cost is 0.48 s for 184 files, and correctness comes first.
    """
    votes: list[dict] = []

    def add(measure: str, verdict, rating: float):
        if not verdict:
            return
        if measure in LOFI_MEASURES:
            rating = min(rating, LOFI_MAX_RATING)
        votes.append({"measure": measure, "category": verdict,
                      "rating": round(rating, 3), "parts": MEASURE_PARTS[measure]})

    if src.component:
        add("component", DIFFUSERS_COMPONENT_MAP.get(src.component.lower()), 0.4)
    add("segments", classify_by_segments(src), 0.5)
    add("filename", classify_by_filename(src.link_name), 0.5)
    if src.origin == "hf":
        add("repo", classify_by_filename(repo_of(src.display)), 0.4)
    if _is_ct2_layout(src):
        add("ct2", "asr", 0.6)

    ext = Path(src.link_name).suffix.lower()
    if ext == ".safetensors":
        try:
            rated = rate_safetensors(read_safetensors_header(src.path))
            if rated:
                add("safetensors", rated[0], rated[1])
        except (OSError, ValueError, json.JSONDecodeError):
            pass
    cfg = src.config_dir / "config.json"
    if cfg.is_file():
        try:
            add("config", classify_config(read_config_json(cfg)), 0.6)
        except (OSError, ValueError, json.JSONDecodeError):
            pass
    if ext in PICKLE_EXTS:
        try:
            rated = rate_pickle(*read_pickle_signals(src.path))
            if rated:
                add("pickle", rated[0], rated[1])
        except (OSError, ValueError, EOFError, pickle.UnpicklingError,
                zipfile.BadZipFile, AttributeError, ImportError, IndexError):
            pass
    if ext == ".gguf":
        try:
            cat = classify_gguf(read_gguf_metadata(src.path))
            if cat != UNCLASSIFIED:
                add("gguf", cat, 0.95)
        except (OSError, ValueError, struct.error):
            pass
    if read_ggml_magic(src.path):
        add("gguf", "asr", 0.95)   # container magic, embedded evidence
    return votes


def score_votes(votes: list[dict]) -> tuple[str | None, float, dict]:
    """(winner, confidence, per-category scores). Denominator = ALL applicable parts."""
    if not votes:
        return None, 0.0, {}
    total_parts = sum(v["parts"] for v in votes)
    scores: dict[str, float] = {}
    for v in votes:
        scores[v["category"]] = scores.get(v["category"], 0.0) + v["parts"] * v["rating"]
    scores = {c: round(s / total_parts, 3) for c, s in scores.items()}
    winner = max(scores, key=lambda c: scores[c])
    return winner, scores[winner], scores


def classify_config(config: dict) -> str | None:
    archs = config.get("architectures") or []
    for a in archs:
        if a in CONFIG_TEXT_ARCHS:
            return "text_encoders"
        if a in CONFIG_VISION_ARCHS:
            return "clip_vision"
        if a.startswith("Autoencoder"):
            return "vae"
        if a.endswith(CONFIG_LLM_SUFFIXES):
            return "llm"  # HF-format LLM repo: vllm's model, inventory-only
    return None


def classify_gguf(meta: dict) -> str:
    arch = str(meta.get("general.architecture", "")).lower()
    if arch in GGUF_DIFFUSION_ARCHS:
        return "diffusion_models"
    if arch in GGUF_TEXT_ARCHS:
        return "text_encoders"
    if arch in GGUF_LLM_ARCHS:
        return "llm"  # llama/ds4's models, inventory-only
    # STRUCTURAL fallback for an architecture we have never heard of. Enumerating model
    # families is a losing race -- `step35` and `minimax-m2` both landed as unclassified
    # simply because they are new -- but a language model is recognisable from its own
    # metadata: it ships a tokenizer AND a transformer block count. Image/video GGUFs
    # carry neither, so this cannot swallow them.
    if arch and (meta.get("__tokenizer__")
                 or any(k.endswith(".block_count") for k in meta)):
        return "llm"
    return UNCLASSIFIED  # unknown architecture: a true heuristics gap


# whisper.cpp / ggml files are NOT GGUF and NOT pickles -- the pickle reader was merely
# the last thing to be tried, which is why they surfaced as "unreadable pickle" warnings.
# The container announces itself in its first four bytes.
GGML_MAGICS = (b"ggml", b"lmgg", b"ggmf", b"ggjt")


def read_ggml_magic(path: Path) -> bytes | None:
    """First four bytes when the file is a ggml container, else None."""
    try:
        with open(path, "rb") as f:
            head = f.read(4)
    except OSError:
        return None
    return head if head in GGML_MAGICS else None


def detect_format(src: SourceFile) -> str | None:
    """CONTAINER format, recorded in the registry beside the role `category` so role
    and container stop fighting for one string (heuristics 9).

    Derived from extension + magic + sibling evidence, reusing the detectors the
    classifier already has (read_ggml_magic, _is_ct2_layout) rather than re-detecting.
    Order matters for the pickle extensions: a ggml container and a CTranslate2 blob
    both ship as `.bin`, and neither is a pickle. Repo-level diffusers units are not
    SourceFiles and record `format: diffusers` directly in cmd_sync.
    """
    ext = Path(src.link_name).suffix.lower()
    if ext == ".gguf":
        return "gguf"
    if ext == ".safetensors":
        return "safetensors"
    if read_ggml_magic(src.path):
        return "ggml"
    if _is_ct2_layout(src):
        return "ctranslate2"
    if ext in PICKLE_EXTS:
        return "pickle"
    return None  # unreachable for WEIGHT_EXTS sources; safe for anything else


def classify(src: SourceFile) -> str:
    """Heuristic ladder, cheapest first; no confident signal -> unclassified."""
    ext = Path(src.link_name).suffix.lower()

    # 0. diffusers component role (repo has a root model_index.json)
    if src.component:
        cat = DIFFUSERS_COMPONENT_MAP.get(src.component.lower())
        if cat:
            return cat

    cat = classify_by_segments(src)
    if cat:
        return cat

    cat = classify_by_filename(src.link_name)
    if cat:
        return cat

    # REPO-NAME signal (hf provenance only). Many weights are named for their position
    # inside a repo rather than their family -- vivym/face-parsing-bisenet/79999_iter.pth,
    # vladmandic/yolo-detailers/eyes-full-v1.pt -- so the repo carries the family name and
    # the filename does not. Reuse the SAME rule set against the repo name: it runs after
    # the segment and filename passes, so a specific signal always wins, and a repo whose
    # name matches nothing (Wan_2.2_ComfyUI_Repackaged, FLUX.1-Fill-dev, *-GGUF) simply
    # falls through as before. hf-only because a local file's display is a filesystem path,
    # whose directory names are already handled by classify_by_segments.
    if src.origin == "hf":
        cat = classify_by_filename(repo_of(src.display))
        if cat:
            return cat

    # CTranslate2 layout: a .bin beside a signature vocabulary sibling (cheap stats)
    if _is_ct2_layout(src):
        return "asr"

    if ext == ".safetensors":
        try:
            cat = classify_safetensors_header(read_safetensors_header(src.path))
            if cat:
                return cat
        except (OSError, ValueError, json.JSONDecodeError) as e:
            log(f"WARN  unreadable safetensors header {src.display}: {e}")

    cfg = src.config_dir / "config.json"
    if cfg.is_file():
        try:
            cat = classify_config(read_config_json(cfg))
            if cat:
                return cat
        except (OSError, ValueError, json.JSONDecodeError) as e:
            log(f"WARN  unreadable config.json next to {src.display}: {e}")

    # ggml container (whisper.cpp et al). Checked before the pickle attempt because a
    # ggml file is not a pickle and would otherwise WARN its way to unclassified.
    if read_ggml_magic(src.path):
        return "asr"

    # Pickle content sniff LAST among the content signals: an HF-format repo is settled
    # by its config.json above (one small read), so only weights with no sibling config
    # -- the loose .pt/.pth checkpoints this pass exists for -- reach the unpickler.
    if ext in PICKLE_EXTS:
        try:
            cat = classify_pickle(*read_pickle_signals(src.path))
            if cat:
                return cat
        except (OSError, ValueError, EOFError, pickle.UnpicklingError,
                zipfile.BadZipFile, AttributeError, ImportError, IndexError) as e:
            # Never fatal: a pickle we cannot read is just an unclassified file.
            log(f"WARN  unreadable pickle {src.display}: {e}")

    if ext == ".gguf":
        try:
            cat = classify_gguf(read_gguf_metadata(src.path))
            if cat != UNCLASSIFIED:
                return cat
        except (OSError, ValueError, struct.error) as e:
            log(f"WARN  unreadable GGUF metadata {src.display}: {e}")
        if src.sharded:
            return "gguf-split"  # identified as a split-GGUF part, role unknown
        return UNCLASSIFIED

    return UNCLASSIFIED


# --------------------------------------------------------------------------- registry

@dataclass
class Registry:
    entries: dict = field(default_factory=dict)   # identity -> entry dict
    heuristics: int = HEURISTICS_VERSION

    def owned_links(self) -> set[str]:
        owned: set[str] = set()
        for e in self.entries.values():
            owned.update(e.get("links") or [])
        return owned


def load_registry(path: Path) -> Registry:
    if not path.is_file():
        return Registry()
    try:
        data = yaml.safe_load(path.read_text()) or {}
        entries = data.get("entries") or {}
        if not isinstance(entries, dict):
            raise ValueError("entries is not a mapping")
        return Registry(entries=entries,
                        heuristics=int(data.get("heuristics", 0)))
    except Exception as e:  # corrupt registry -> start fresh; links fail safe to "user's"
        log(f"WARN  unreadable registry {path} ({e}); starting fresh "
            f"(existing links are treated as user-owned)")
        return Registry()


def save_registry(path: Path, reg: Registry) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    doc = {"version": REGISTRY_VERSION, "heuristics": HEURISTICS_VERSION,
           "entries": reg.entries}
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(yaml.safe_dump(doc, sort_keys=True, default_flow_style=False))
    tmp.replace(path)


# ------------------------------------------------------------------------ linking core
# Classification-agnostic: a future manifest-driven explicit layer can reuse these.

def link_matches(dst: Path, target: Path, hardlink: bool) -> bool:
    if dst.is_symlink():
        try:
            return dst.resolve() == target
        except OSError:
            return False
    if hardlink and dst.is_file():
        try:
            return dst.stat().st_ino == target.stat().st_ino
        except OSError:
            return False
    return False


def ensure_link(target: Path, dst: Path, owned: bool, hardlink: bool, dry: bool) -> str:
    """Returns: ok | linked | relinked | conflict."""
    if dst.is_symlink() or dst.exists():
        if link_matches(dst, target, hardlink):
            return "ok"
        if not owned:
            return "conflict"       # unowned file/link already there: never clobber
        if not dst.is_symlink():
            # A non-matching REGULAR file is never replaced, even if the path is
            # owned: we cannot tell a stale hardlink of ours from a real file the
            # user dropped over our link. Safety wins.
            return "conflict"
        if not dry:
            dst.unlink()
            (os.link if hardlink else os.symlink)(target, dst)
        return "relinked"
    if not dry:
        dst.parent.mkdir(parents=True, exist_ok=True)
        (os.link if hardlink else os.symlink)(target, dst)
    return "linked"


def prune_link(tree: Path, rel: str, dry: bool) -> str:
    """Remove an OWNED link whose source vanished. Returns: pruned | kept | gone."""
    dst = tree / rel
    if dst.is_symlink():
        if not dry:
            dst.unlink()
        return "pruned"
    if dst.exists():
        return "kept"   # real file (user replacement or hardlink holding data): keep
    return "gone"


# ------------------------------------------------------------------------------- sync

def linkable(src: SourceFile, category: str) -> bool:
    # The INVENTORY_CATEGORIES guard is belt-and-braces: none of them are in CATEGORIES
    # today, but an inventory category must stay unlinkable even if one is ever
    # (re-)added to the linkable set by mistake.
    return (category in CATEGORIES
            and category not in INVENTORY_CATEGORIES
            and not src.sharded)


def plan_links(sources: list[SourceFile], categories: dict[str, str]) -> dict[str, SourceFile]:
    """Map tree-relative link path -> source. Name collisions between two different
    sources get a deterministic provenance-prefixed name."""
    desired: dict[str, SourceFile] = {}
    for src in sources:
        cat = categories[src.identity]
        if not linkable(src, cat):
            continue
        rel = f"{cat}/{src.link_name}"
        if rel in desired and desired[rel].identity != src.identity:
            prefix = _sanitize(str(Path(src.display).parent))
            alt = f"{cat}/{prefix}--{src.link_name}" if prefix else None
            if not alt or alt in desired:
                log(f"SKIP  name collision for {src.display} -> {rel}")
                continue
            rel = alt
        if rel not in desired:
            desired[rel] = src
    return desired


def cmd_sync(args) -> int:
    t0 = time.monotonic()
    tree: Path = args.tree
    dry = args.dry_run

    old = load_registry(args.registry)
    reuse_cache = old.heuristics == HEURISTICS_VERSION
    if old.entries and not reuse_cache:
        log(f"INFO  heuristics changed ({old.heuristics} -> {HEURISTICS_VERSION}); "
            f"reclassifying everything")
    owned = old.owned_links()

    files, units = collect_sources(args.cache_dir, args.models_dir)

    # classify only the DELTA; known identities skip straight to link-verify
    categories: dict[str, str] = {}
    formats: dict[str, str | None] = {}   # identity -> container format
    confidences: dict[str, dict] = {}     # identity -> {confidence, signals, disputed?}
    n_new = 0
    for src in files:
        prev = old.entries.get(src.identity) if reuse_cache else None
        if prev and prev.get("category"):
            categories[src.identity] = prev["category"]
            # carried forward like the category; the detect_format fallback is for an
            # entry written before the field existed (cheap: ext-only or a 4-byte read)
            formats[src.identity] = prev.get("format") or detect_format(src)
            carried = {k: prev[k] for k in ("confidence", "signals", "disputed")
                       if k in prev}
            if carried:
                confidences[src.identity] = carried
        else:
            n_new += 1
            # STEP 2 -- THE SCORE DECIDES. Every applicable measure votes and the weighted
            # winner is what gets recorded; the heuristic ladder is retained for exactly two
            # jobs: a fallback when NO measure votes, and the naming-vs-content comparison
            # that populates `disputed`.
            #
            # Rationale (owner, 2026-08-12): "we really should be looking at the data; humans
            # can already look at filenames and directories easily." The ladder consulted
            # names FIRST and short-circuited, so a name could veto the file's own contents --
            # e.g. a full SD checkpoint named `..._Real+VAE.safetensors` was recorded `vae`
            # while its tensors carried conditioner./first_stage_model./model.diffusion_model.
            #
            # Safe by construction: rate_safetensors/rate_pickle delegate to the SAME
            # classify_* logic the ladder uses and return None only where those do, and every
            # ladder signal has a vote counterpart -- so promoting the score cannot LOSE a
            # classification, only reorder precedence. `or ladder` is belt-and-braces.
            ladder = classify(src)
            votes = gather_votes(src)
            winner, _, scores = score_votes(votes)
            cat = winner or ladder
            categories[src.identity] = cat
            formats[src.identity] = detect_format(src)
            if votes:
                info = {"confidence": scores.get(cat, 0.0),
                        "signals": [f"{v['measure']}={v['category']}@{v['rating']}"
                                    for v in votes]}
                # Content decides, but it must never SILENCE. An embedded signal can be
                # confident AND wrong (a multimodal LLM's vision tower reads as clip_vision
                # at 0.99 -- the rule cannot tell "HAS a vision encoder" from "IS one"), and
                # in exactly those cases the NAME holds the corrective information. Recording
                # the disagreement is what keeps that class of error findable.
                if ladder != cat and ladder != UNCLASSIFIED:
                    info["disputed"] = f"ladder={ladder}"
                confidences[src.identity] = info
            info = confidences.get(src.identity, {})
            note = " [sharded]" if src.sharded else ""
            if "confidence" in info:
                note += f" (confidence {info['confidence']})"
            if "disputed" in info:
                note += f" DISPUTED -> {info['disputed']}"
            log(f"CLASSIFY  {src.display} -> {cat}{note}")

    desired = plan_links(files, categories)

    # link phase
    new = Registry()
    counts = {"ok": 0, "linked": 0, "relinked": 0, "conflict": 0}
    entry_links: dict[str, list[str]] = {s.identity: [] for s in files}
    for rel in sorted(desired):
        src = desired[rel]
        state = ensure_link(src.path, tree / rel, owned=rel in owned,
                            hardlink=args.hardlink, dry=dry)
        counts[state] += 1
        if state == "conflict":
            log(f"CONFLICT  {rel} exists and is not ours; leaving it alone "
                f"(wanted -> {src.display})")
        else:
            if state != "ok":
                log(f"{'DRY-' if dry else ''}{state.upper()}  {rel} -> {src.path}")
            entry_links[src.identity].append(rel)

    for src in files:
        entry = {
            "origin": src.origin,
            "category": categories[src.identity],
            "format": formats[src.identity],
            "source": str(src.path),
            "display": src.display,
            "links": entry_links[src.identity],
        }
        if src.sharded:
            entry["sharded"] = True
        entry.update(confidences.get(src.identity, {}))
        new.entries[src.identity] = entry
        if categories[src.identity] == UNCLASSIFIED and src.identity not in old.entries:
            log(f"UNCLASSIFIED  {src.display} (not linked; heuristics gap)")
        # DISPUTED is the companion report to UNCLASSIFIED: the file WAS classified, but the
        # naming ladder wanted something else. Since Step 2 the score is authoritative, so a
        # dispute no longer means "we may have recorded the wrong thing" -- it means the names
        # and the data disagree, and the names lost. That is still the single most useful
        # report we have: it is where a confident-but-wrong EMBEDDED reading shows up, which
        # UNCLASSIFIED can never surface because such a file looks settled.
        disputed = confidences.get(src.identity, {}).get("disputed")
        if disputed and src.identity not in old.entries:
            log(f"DISPUTED  {src.display} -> chose {categories[src.identity]} "
                f"@{confidences[src.identity].get('confidence')} from the data; "
                f"naming said {disputed.split('=', 1)[1]}")

    # repo-level diffusers units: re-detected each run (one stat), never linked
    for u in units:
        if u.identity not in old.entries:
            log(f"REPO  {u.display} -> diffusers unit ({len(u.members)} member files)")
        new.entries[u.identity] = {
            "origin": "hf",
            "category": "diffusers",
            "format": "diffusers",
            "source": u.source,
            "display": u.display,
            "links": [],
            "members": u.members,
        }

    # prune phase: owned links whose source vanished or whose target moved category
    n_pruned = 0
    desired_rels = set(desired)
    for ident, entry in old.entries.items():
        stale = [rel for rel in (entry.get("links") or []) if rel not in desired_rels]
        for rel in stale:
            if not args.prune:
                continue
            state = prune_link(tree, rel, dry)
            if state == "pruned":
                n_pruned += 1
                log(f"{'DRY-' if dry else ''}PRUNE  {rel} (source gone or reclassified)")
            elif state == "kept":
                log(f"KEEP  {rel} is a real file now; not pruning (dropped from registry)")
        if not args.prune and ident not in new.entries:
            # keep ownership of not-yet-pruned links for a later prune
            new.entries[ident] = entry

    # report broken symlinks that are NOT ours (never touched)
    if tree.is_dir():
        new_owned = new.owned_links()
        for p in sorted(tree.rglob("*")):
            if p.is_symlink() and not p.exists():
                rel = str(p.relative_to(tree))
                if rel not in new_owned and rel not in owned:
                    log(f"NOTE  broken unowned symlink (left alone): {rel}")

    if not dry:
        save_registry(args.registry, new)

    dt = time.monotonic() - t0
    n_uncls = sum(1 for c in categories.values() if c == UNCLASSIFIED)
    n_inv = sum(1 for s in files
                if categories[s.identity] != UNCLASSIFIED
                and not linkable(s, categories[s.identity])) + len(units)
    log(f"model-scanner: {len(files)} files + {len(units)} repo units ({n_new} new), "
        f"{counts['ok']} ok, {counts['linked']} linked, {counts['relinked']} relinked, "
        f"{n_pruned} pruned, {counts['conflict']} conflicts, "
        f"{n_inv} inventory-only, {n_uncls} unclassified"
        f"{' [dry-run]' if dry else ''} ({dt:.2f}s)")
    return 0


# ------------------------------------------------------------------------------ status

def _inspect_evidence(src: SourceFile) -> list[tuple[str, str]]:
    """Every RAW observation the classifier had available, as (label, value) rows.

    Deliberately separate from gather_votes(): votes are the classifier's CONCLUSIONS,
    this is the material they were drawn from. When a file cannot be identified
    automatically, the material is what a human needs in order to decide -- and it is
    already read during a scan, so surfacing it costs nothing extra.
    """
    rows: list[tuple[str, str]] = []
    ext = Path(src.link_name).suffix.lower()

    def cap(items, n=12, width=160):
        # Cap BOTH the count and each item's length. A single __metadata__ value can be a
        # full licence text or a per-layer quantisation map running to tens of kilobytes,
        # which buries the signal it was printed to reveal.
        items = sorted(items)
        shown = [i if len(i) <= width else i[:width] + f"… (+{len(i) - width} chars)"
                 for i in items[:n]]
        return ", ".join(shown) + (f"  (+{len(items) - n} more)" if len(items) > n else "")

    try:
        rows.append(("size", f"{src.path.stat().st_size / 1e6:,.1f} MB"))
    except OSError:
        pass
    rows.append(("origin", src.origin))
    if src.component:
        rows.append(("diffusers component dir", src.component))

    if ext == ".safetensors":
        try:
            header = read_safetensors_header(src.path)
            keys = [k for k in header if k != "__metadata__"]
            rows.append(("tensor count", str(len(keys))))
            # The top-level prefix set is what every prefix rule actually matches on.
            rows.append(("key prefixes", cap({k.split(".")[0] for k in keys})))
            rows.append(("sample keys", cap(keys[:6], 6)))
            meta = header.get("__metadata__") or {}
            if meta:
                rows.append(("__metadata__", cap([f"{k}={v}" for k, v in meta.items()], 8)))
        except (OSError, ValueError, json.JSONDecodeError) as e:
            rows.append(("safetensors", f"UNREADABLE: {e}"))

    magic = read_ggml_magic(src.path)
    if magic:
        rows.append(("ggml container", magic.decode("ascii", "replace")))

    if ext in PICKLE_EXTS and not magic:
        try:
            keys, modules = read_pickle_signals(src.path)
            rows.append(("pickle modules", cap(modules) or "(none)"))
            # DISPLAY ONLY: a torch `_metadata` OrderedDict carries an entry keyed on the
            # empty string (the root module), which harvests into the key set and renders
            # as a phantom leading item -- ", _metadata, module". The classifier is
            # indifferent to it; a human reading the evidence is not. BOTH rows need the
            # filter: the empty key sorts first, so the sample row led with it too.
            named = [k for k in sorted(keys) if k]
            rows.append(("pickle key prefixes",
                         cap({k.split(".")[0] for k in named}) or "(none)"))
            rows.append(("pickle sample keys", cap(named[:6], 6) or "(none)"))
        except (OSError, ValueError, EOFError, pickle.UnpicklingError,
                zipfile.BadZipFile, AttributeError, ImportError, IndexError) as e:
            # NEVER silent. Both shapes of non-answer land here -- a read that threw and
            # a read that yielded nothing (_signals_or_raise turns the latter into an
            # `empty: ...` reason) -- because `(none)` on a 150 MB file tells a human
            # nothing at all about which of the two happened.
            rows.append(("pickle read", f"FAILED: {e}"))
            # When the pickle cannot be read, what the container actually holds is the
            # next question -- so answer it here rather than in another round trip.
            try:
                with open(src.path, "rb") as f:
                    rows.append(("file magic", repr(f.read(4))))
                if zipfile.is_zipfile(src.path):
                    with zipfile.ZipFile(src.path) as z:
                        rows.append(("zip members", cap(z.namelist(), 15, 80)))
            except (OSError, zipfile.BadZipFile):
                pass

    if ext == ".gguf":
        try:
            meta = read_gguf_metadata(src.path)
            arch = meta.get("general.architecture", "(absent)")
            rows.append(("gguf architecture", str(arch)))
            known = ("known" if arch in (GGUF_DIFFUSION_ARCHS | GGUF_TEXT_ARCHS
                                         | GGUF_LLM_ARCHS) else "UNKNOWN to the scanner")
            rows.append(("gguf arch status", known))
            interesting = {k: v for k, v in meta.items()
                           if k.startswith("general.") or ".block_count" in k
                           or ".context_length" in k or k.startswith("tokenizer.ggml.model")}
            rows.append(("gguf metadata",
                         cap([f"{k}={v}" for k, v in interesting.items()], 10)))
        except (OSError, ValueError, struct.error) as e:
            rows.append(("gguf", f"UNREADABLE: {e}"))

    cfg = src.config_dir / "config.json"
    if cfg.is_file():
        try:
            conf = read_config_json(cfg)
            rows.append(("config.json architectures",
                         cap(conf.get("architectures") or []) or "(none listed)"))
            rows.append(("config.json model_type", str(conf.get("model_type", "(absent)"))))
        except (OSError, ValueError, json.JSONDecodeError) as e:
            rows.append(("config.json", f"UNREADABLE: {e}"))

    siblings = [v for v in CT2_SIBLINGS if (src.config_dir / v).is_file()]
    if siblings:
        rows.append(("CTranslate2 siblings", cap(siblings)))
    return rows


def cmd_inspect(args) -> int:
    """Show the evidence behind a classification -- or behind the lack of one.

    Exists because automatic identification has a floor: some weights carry no signal
    that names them. Rather than guess, print everything that WAS observed so a human
    can decide, then encode that decision as a rule.
    """
    files, _units = collect_sources(args.cache_dir, args.models_dir)
    pats = [p.lower() for p in (args.pattern or [])]

    selected = []
    for src in files:
        cat = classify(src)
        votes = gather_votes(src)
        winner, _, scores = score_votes(votes)
        final = winner or cat
        if args.unclassified and final != UNCLASSIFIED:
            continue
        if pats and not any(p in src.display.lower() for p in pats):
            continue
        selected.append((src, cat, final, votes, scores))

    if not selected:
        log("no files matched")
        return 0

    for src, ladder, final, votes, scores in selected:
        log("")
        log(f"=== {src.display}")
        log(f"    category   {final}"
            + ("" if final == ladder else f"   (naming ladder said: {ladder})"))
        log(f"    link name  {src.link_name}")
        if votes:
            log("    votes:")
            for v in sorted(votes, key=lambda v: -v["parts"] * v["rating"]):
                tier = "LoFi " if v["measure"] in LOFI_MEASURES else "embed"
                log(f"      [{tier}] {v['measure']:<12} -> {v['category']:<22}"
                    f" rating {v['rating']:<5} x {v['parts']:>2} parts")
            log("    scores:    " + ", ".join(f"{c}={s}" for c, s in
                                              sorted(scores.items(), key=lambda kv: -kv[1])))
        else:
            log("    votes:     (none -- no measure could form a judgement)")
        log("    evidence:")
        for label, value in _inspect_evidence(src):
            log(f"      {label:<26} {value}")
    log("")
    log(f"model-scanner: inspected {len(selected)} file(s)")
    return 0


def cmd_status(args) -> int:
    tree: Path = args.tree
    reg = load_registry(args.registry)
    files, units = collect_sources(args.cache_dir, args.models_dir)
    displays = {s.identity: s.display for s in files}
    displays.update({u.identity: u.display for u in units})

    new = [i for i in sorted(displays) if i not in reg.entries]
    gone = [i for i in reg.entries if i not in displays]
    owned = reg.owned_links()

    n_ok = n_broken = n_missing = 0
    for ident, entry in reg.entries.items():
        for rel in entry.get("links") or []:
            dst = tree / rel
            if not (dst.is_symlink() or dst.exists()):
                n_missing += 1
                log(f"MISSING  {rel} (owned link absent; sync will recreate)")
            elif dst.is_symlink() and not dst.exists():
                n_broken += 1
                log(f"BROKEN  {rel} (owned; sync --prune will remove)")
            else:
                n_ok += 1
        if entry.get("category") == UNCLASSIFIED:
            log(f"UNCLASSIFIED  {entry.get('display', ident)}"
                f"{'' if ident in displays else ' (source gone)'}")

    n_user_files = n_user_broken = 0
    if tree.is_dir():
        for p in sorted(tree.rglob("*")):
            if p.is_dir():
                continue
            rel = str(p.relative_to(tree))
            if rel in owned:
                continue
            if p.is_symlink() and not p.exists():
                n_user_broken += 1
                log(f"NOTE  broken unowned symlink (left alone): {rel}")
            else:
                n_user_files += 1
                log(f"USER  {rel} (not ours; never touched)")

    for i in new:
        log(f"NEW  {displays[i]} (will classify on next sync)")
    for i in gone:
        log(f"GONE  {reg.entries[i].get('display', i)} (source vanished; "
            f"sync --prune will clean)")

    log(f"model-scanner status: {len(files)} files + {len(units)} repo units "
        f"({len(new)} new, {len(gone)} gone from registry), "
        f"links: {n_ok} ok / {n_broken} broken / {n_missing} missing, "
        f"user items: {n_user_files} files+links, {n_user_broken} broken")
    return 0


# --------------------------------------------------------------------------------- cli

def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--cache-dir", type=lambda s: Path(s).expanduser(),
                        default=Path(os.environ.get("HF_HUB_CACHE",
                                                    DEFAULT_CACHE_DIR)).expanduser(),
                        help=f"HF hub cache (default {DEFAULT_CACHE_DIR}, "
                             f"honors $HF_HUB_CACHE)")
    common.add_argument("--models-dir", type=lambda s: Path(s).expanduser(),
                        default=Path(DEFAULT_MODELS_DIR),
                        help=f"optional local models dir (default {DEFAULT_MODELS_DIR}; "
                             f"skipped if absent)")
    common.add_argument("--tree", type=lambda s: Path(s).expanduser(),
                        default=Path(DEFAULT_TREE),
                        help=f"symlink tree to maintain (default {DEFAULT_TREE})")
    common.add_argument("--registry", type=lambda s: Path(s).expanduser(),
                        default=Path(DEFAULT_REGISTRY),
                        help=f"registry YAML (default {DEFAULT_REGISTRY})")

    p = argparse.ArgumentParser(
        prog="model-scanner",
        description="Maintain a classified inventory of the shared HF hub cache "
                    "(+ optional local models dir) and a ComfyUI-friendly symlink "
                    "tree over it. Runs at container start; near-instant when "
                    "nothing changed.")
    sub = p.add_subparsers(dest="cmd")

    s = sub.add_parser("sync", parents=[common],
                       help="scan, classify the delta, and reconcile the link tree "
                            "(default verb)")
    s.add_argument("-n", "--dry-run", action="store_true",
                   help="report what would change without touching anything")
    s.add_argument("--no-prune", dest="prune", action="store_false", default=True,
                   help="do not remove owned links whose source vanished")
    s.add_argument("--hardlink", action="store_true",
                   help="hardlink blobs instead of symlinking")
    s.set_defaults(fn=cmd_sync)

    st = sub.add_parser("status", parents=[common],
                        help="report registry vs tree vs sources (read-only)")
    st.set_defaults(fn=cmd_status)

    ins = sub.add_parser("inspect", parents=[common],
                         help="show the evidence behind a file's classification "
                              "(read-only); use --unclassified to review the gaps")
    ins.add_argument("pattern", nargs="*",
                     help="substring(s) matched against the display path; "
                          "omit to select everything")
    ins.add_argument("-u", "--unclassified", action="store_true",
                     help="only files that end up unclassified")
    ins.set_defaults(fn=cmd_inspect)
    return p


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0].startswith("-") and argv[0] not in ("-h", "--help"):
        argv.insert(0, "sync")  # sync is the default verb
    args = build_parser().parse_args(argv)
    if not getattr(args, "fn", None):
        build_parser().print_help()
        return 2
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
