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
things ComfyUI cannot load (HF-format LLM repos -> `llm`, plain-LLM GGUFs -> `gguf-llm`,
CTranslate2 models -> `ctranslate2`, split-GGUF parts, sharded components) -- those are
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
                                           #   (llm, gguf-llm, ctranslate2, gguf-split,
                                           #    diffusers), or "unclassified"
        sharded: true                      # OPTIONAL; multi-part file: classified but
                                           #   never linked (absent = single-file)
        source: /abs/path/to/blobs/<sha>   # resolved source at last sync (informational)
        display: org/repo/vae/diffusion_pytorch_model.safetensors   # provenance
        links:                             # tree-relative links WE own (ownership!)
          - vae/FLUX.1-Fill-dev--vae.safetensors   # [] for inventory-only/unclassified
      "diffusers:org/repo@<rev>":          # repo-level diffusers unit
        origin: hf
        category: diffusers
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
  3. CTranslate2 layout: `model.bin` + a sibling vocabulary file -> ctranslate2
  4. safetensors header (8-byte length + JSON header ONLY -- tensors never read):
     tensor-name prefixes + `__metadata__` modelspec.architecture
  5. sibling config.json (HF-format repos): `architectures` -> category;
     LLM architectures (…ForCausalLM etc.) -> `llm` (vllm's models; inventory-only)
  6. GGUF metadata (`general.architecture`): diffusion archs -> diffusion_models,
     clip/t5 -> text_encoders, LLM archs -> `gguf-llm` (llama/ds4's models;
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
HEURISTICS_VERSION = 7

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
CATEGORIES = {
    "checkpoints", "diffusion_models", "text_encoders", "vae", "loras",
    "controlnet", "clip_vision", "upscale_models", "latent_upscale_models",
    "embeddings", "style_models", "photomaker", "gligen", "hypernetworks",
    "vae_approx", "audio_encoders", "model_patches", "diffusers",
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
}
CATEGORIES |= DETECTOR_CATEGORIES

# Inventory-only categories: real classifications that ComfyUI cannot load.
# Recorded with links:[] so later features are a linking rule, never a re-scan.
INVENTORY_CATEGORIES = {"llm", "gguf-llm", "ctranslate2", "gguf-split", "diffusers"}

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

# CTranslate2 model dirs: model.bin + one of these signature vocabulary files (step 3)
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
            val = read_value(vtype, store=True)
            if val is not None:
                meta[key] = val
            if "general.architecture" in meta:
                break  # all we need; stop early
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

    keys = [k for k in header if k != "__metadata__"]
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
    if any_start("control_model."):
        return "controlnet"
    if any_start("vision_model."):
        return "clip_vision"
    if any_start("diffusion_model.", "double_blocks.", "joint_blocks."):
        return "diffusion_models"
    if any_start("encoder.block.", "decoder.block."):   # T5-style, before generic vae
        return "text_encoders"
    if any_start("first_stage_model."):
        return "vae"
    if "decoder." in prefixes and "encoder." in prefixes:
        return "vae"
    if any_start("text_model.", "t5.", "enc."):
        return "text_encoders"
    return None


def _restricted_unpickle(fileobj) -> tuple[set, set]:
    """Recover a pickle's state-dict KEYS and the MODULE paths it references, without
    executing any of its payload.

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

    obj = _Restricted(fileobj).load()
    # a plain dict / OrderedDict may come back concrete; harvest its keys (and one level
    # of nesting, e.g. {"state_dict": {...}}).
    stack, seen = [obj], 0
    while stack and seen < 8:
        cur = stack.pop()
        seen += 1
        if isinstance(cur, dict):
            keys.update(k for k in cur if isinstance(k, str))
            stack.extend(v for v in cur.values() if isinstance(v, dict))
    return keys, modules


def read_pickle_signals(path: Path) -> tuple[set, set]:
    """(state-dict keys, referenced module paths) for a pickled checkpoint.

    Modern torch files are zip archives holding a small `data.pkl`; legacy ones are a
    bare pickle followed by the raw storages. Either way only the pickle STRUCTURE is
    read -- never the tensor payload -- so cost is bounded regardless of file size.
    """
    with open(path, "rb") as f:
        head = f.read(2)
    if head == b"PK":                          # zip archive (modern torch.save)
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if n.endswith("data.pkl")]
            if not names:
                return set(), set()
            with z.open(names[0]) as fh:
                return _restricted_unpickle(fh)
    with open(path, "rb") as f:                # legacy bare pickle
        return _restricted_unpickle(f)


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
# Weights are Jei's, from his judgement of trustworthiness. The arithmetic they produce:
# all six LoFi measures agreeing tops out at 6*5*0.6 = 18, while any single embedded
# measure at >=0.9 reaches 18-29.7 -- so confident embedded evidence always wins, and
# names/sidecars decide only where embedded evidence is weak or absent.
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
LOFI_MAX_RATING = 0.6    # LoFi may never express certainty
EMBEDDED_MAX_RATING = 0.99   # nor may anything else claim absolute certainty

# Tensor-name prefixes that identify a model outright, vs the generic encoder+decoder
# shape that merely suggests an autoencoder (plenty of models have both).
DISTINCTIVE_PREFIXES = (
    "model.diffusion_model.", "control_model.", "vision_model.", "diffusion_model.",
    "double_blocks.", "joint_blocks.", "encoder.block.", "decoder.block.",
    "first_stage_model.", "text_model.", "t5.", "enc.",
)


def rate_safetensors(header: dict) -> tuple[str, float] | None:
    """Category + how much the evidence deserves to be believed."""
    cat = classify_safetensors_header(header)
    if not cat:
        return None
    keys = [k for k in header if k != "__metadata__"]
    if any(k.startswith(DISTINCTIVE_PREFIXES) for k in keys) or any(
            k.startswith(("lora_unet_", "lora_te")) or ".lora_A" in k or ".lora_B" in k
            or ".lora_down" in k or ".lora_up" in k for k in keys):
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
        rated = rate_safetensors({k: {} for k in keys})
        if rated:
            # keys are strong but one step below a module path naming the class
            return rated[0], min(rated[1], 0.95)
    return None


def gather_votes(src: SourceFile) -> list[dict]:
    """Run EVERY applicable measure and collect its judgement.

    Deliberately independent of classify(): in this (annotate-only) step the ladder
    remains the authority for the recorded category, and these votes only describe it.
    Costs one extra content read per NEW file -- classification is cached by content
    identity, so it is paid once per file, never on a steady-state re-scan. When the
    score becomes authoritative this collapses into a single pass.
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
    if (Path(src.display).name.lower() == "model.bin"
            and any((src.config_dir / v).is_file() for v in CT2_SIBLINGS)):
        add("ct2", "ctranslate2", 0.6)

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
        return "gguf-llm"  # llama/ds4's models, inventory-only
    return UNCLASSIFIED  # unknown architecture: a true heuristics gap


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

    # CTranslate2 layout: model.bin + signature vocabulary sibling (cheap stats)
    if (Path(src.display).name.lower() == "model.bin"
            and any((src.config_dir / v).is_file() for v in CT2_SIBLINGS)):
        return "ctranslate2"

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
    return category in CATEGORIES and not src.sharded


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
    confidences: dict[str, dict] = {}     # identity -> {confidence, signals, disputed?}
    n_new = 0
    for src in files:
        prev = old.entries.get(src.identity) if reuse_cache else None
        if prev and prev.get("category"):
            categories[src.identity] = prev["category"]
            carried = {k: prev[k] for k in ("confidence", "signals", "disputed")
                       if k in prev}
            if carried:
                confidences[src.identity] = carried
        else:
            n_new += 1
            cat = classify(src)
            categories[src.identity] = cat
            # ANNOTATE ONLY: the ladder above stays the authority. The measures merely
            # describe how well-supported its answer is, and record any disagreement.
            votes = gather_votes(src)
            winner, _, scores = score_votes(votes)
            if votes:
                info = {"confidence": scores.get(cat, 0.0),
                        "signals": [f"{v['measure']}={v['category']}@{v['rating']}"
                                    for v in votes]}
                if winner and winner != cat:
                    info["disputed"] = f"{winner}@{scores[winner]}"
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
        # DISPUTED is the companion report to UNCLASSIFIED: the file WAS classified, but
        # the measures do not agree on it. Two disagreeing EMBEDDED measures, or a strong
        # embedded reading contradicted by the ladder's pick, is where misclassification
        # hides -- UNCLASSIFIED can never surface those because they look settled.
        disputed = confidences.get(src.identity, {}).get("disputed")
        if disputed and src.identity not in old.entries:
            log(f"DISPUTED  {src.display} -> kept {categories[src.identity]} "
                f"@{confidences[src.identity].get('confidence')}, measures favour "
                f"{disputed}")

    # repo-level diffusers units: re-detected each run (one stat), never linked
    for u in units:
        if u.identity not in old.entries:
            log(f"REPO  {u.display} -> diffusers unit ({len(u.members)} member files)")
        new.entries[u.identity] = {
            "origin": "hf",
            "category": "diffusers",
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
