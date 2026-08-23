#!/usr/bin/env python3
"""model_formats: shared, EXECUTION-FREE readers for serialized model containers.

Imported by every tool in this directory that has to look inside a weight file --
model_scanner.py (classification) and the two adopt tools (routing + provenance). It
holds the code all of them need and none of them should own a private copy of, starting
with the one piece where a private copy is actively dangerous: the restricted unpickler.

WHY THIS MODULE EXISTS (2026-08-15, s35). `.pt`/`.pth`/`.ckpt`/`.bin` are Python
pickles, and loading one normally EXECUTES arbitrary code -- unacceptable for files
pulled off HuggingFace, CivitAI or a random mirror. The safe reader below never
imports, resolves or calls anything from the payload. It was written once for
droste-civitai-adopt, then ported by hand into model_scanner, and the two copies had
already begun to diverge (the scanner learned to read torch's LEGACY multi-pickle
container and to record MODULE paths; the adopt copy did not). Two implementations of
one security boundary is one implementation too many -- a fix applied to the copy you
happened to be looking at is not a fix. There is now one.

WHAT DELIBERATELY DID NOT MOVE HERE, and why (this is the whole seam, so it is written
down rather than rediscovered):
  * safetensors headers. model_scanner reads them from a PATH and RAISES on trouble;
    the adopt tools parse them out of the bounded PREFIX already captured during their
    single streamed hash pass and return None. Same 8-byte-length-plus-JSON layout, but
    the I/O model and the error contract are genuinely different, and merging them
    would change behaviour on one side or the other.
  * GGUF. model_scanner reads metadata to CLASSIFY (and stops early on a recognised
    `general.architecture`); droste-hf-adopt reads it for PROVENANCE hint keys out of a
    bounded buffer. Different keys, different stopping rules, different failure policy.

THE KEY-SIGNATURE RULES HAVE NOW LANDED HERE (s46). The note that used to sit in this
spot said they were shared knowledge mapped to two different vocabularies, that sharing
them was a real behaviour change rather than a file move, and that this module was where
they should land when the decision was taken. Jei took it ("let's unify them", s41);
the design is `~/canon/notebook/plans/classifier-unification-s41.md`.

THE ONE IDEA THE DESIGN RESTS ON: **the trees are renderings; the KIND is the domain
model.** Neither name set is ours to unify -- the scanner answers in ComfyUI loader
directories (a file in the wrong one is not found by any loader) and the adopt tools
answer in the A1111 layout CivitAI's ecosystem assumes -- so "one vocabulary" can only
mean a THIRD, internal one with a mapping at each edge. That is `KIND_*` below.

Two rules follow, and they decide the edge cases:
  * **The internal kind is at least as fine as the finest consumer.** Collapsing
    fine->coarse at a boundary is free; recovering fine from coarse is impossible. So
    an AnimateDiff motion LORA is its own kind even where a consumer files it with
    motion modules.
  * **Kind answers ROLE.** Everything else -- base-model family, upscaler
    architecture, embedded VAE, EMA weights, dtype, format -- is an ATTRIBUTE of a file,
    not what the file IS.

⚠️ MIGRATION IS DELIBERATELY STAGED (plan build order). This first stage carries the
SCANNER's rules only, verbatim and in the same order, so 93 existing tests can prove no
outcome changed; the adopt tool's rules (t2i-adapter, upscaler architectures) cross
later, WITH the outcome change they imply and the HEURISTICS_VERSION bump that pays for
it. A rule that is here is not automatically used by both tools yet.
"""

from __future__ import annotations

import pickle
import re
import zipfile

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


def is_legacy_preamble(obj) -> bool:
    """True for the header objects torch writes AHEAD of the payload."""
    if isinstance(obj, bool):
        return False
    if isinstance(obj, int):
        return True                      # MAGIC_NUMBER / PROTOCOL_VERSION
    if isinstance(obj, dict) and obj and set(obj) <= TORCH_LEGACY_SYSINFO_KEYS:
        return True                      # sys_info -- its keys are NOT tensor names
    return False


def restricted_unpickle(fileobj, max_objects: int = 1) -> tuple[set, set]:
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
    therefore lands on the stub, never attacker code. In service on real CivitAI and
    HuggingFace downloads since droste-civitai-adopt 0.1.

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
            # nothing is the CALLER's policy call; see model_scanner's
            # _signals_or_raise, which can say so precisely.)
            if n == 0:
                raise
            break
        if max_objects > 1 and is_legacy_preamble(obj):
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


def read_torch_container(path, max_objects: int = 1) -> tuple[set, set, str]:
    """(state-dict keys, referenced module paths, WHAT was read) for a torch checkpoint.

    Modern torch files are zip archives holding a small `data.pkl`; legacy ones (pre-1.6,
    or `_use_new_zipfile_serialization=False`) are a SEQUENCE of pickles -- magic number,
    protocol version, sys_info, payload -- followed by the raw storages. Either way only
    the pickle STRUCTURE is read, never the tensor payload, so cost is bounded regardless
    of file size.

    The third element names the thing that was actually read (`zip member archive/
    data.pkl`, `legacy (non-zip) pickle stream, first bytes b'...',`). A caller that
    harvests nothing needs it to say WHY nothing came back -- "(none)" on a 150 MB file
    is the failure mode this whole reader exists to eliminate -- and only the reader
    knows which branch it took.

    Raises on anything it cannot read. Callers that prefer a soft failure catch it; the
    error text is always more informative than a bare None.
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
                keys, modules = restricted_unpickle(fh, max_objects=1)
                return keys, modules, f"zip member {names[0]}"
    # Non-zip: read the stream as a legacy multi-pickle container. A plain single
    # pickle (what the rest of the world writes, and what the tests hand-build) is just
    # the degenerate case -- its payload is object #1 and the loop stops there.
    with open(path, "rb") as f:
        keys, modules = restricted_unpickle(f, max_objects=max_objects)
    return keys, modules, f"legacy (non-zip) pickle stream, first bytes {head!r},"


# ═══════════════════════════════════════════════════════════════════════════════════════
# KEY-SIGNATURE RULES — what a file IS, from the names inside it
# ═══════════════════════════════════════════════════════════════════════════════════════
# The internal vocabulary. Deliberately NOT either consumer's directory names: the
# scanner answers in ComfyUI loader dirs, the adopt tools in the A1111 layout, and a
# shared rule that returned one of those would silently make that consumer the owner of
# the knowledge again. Each edge keeps its own map (model_scanner.KIND_TO_CATEGORY;
# droste-civitai-adopt's KIND_TO_TYPE / TYPE_DIRS).
#
# FINER THAN EITHER CONSUMER, on purpose. `KIND_ANIMATEDIFF_MOTION_LORA` and
# `KIND_ANIMATEDIFF_MOTION_MODULE` are two kinds even though a consumer may file them in
# one directory, because collapsing at the edge is free and un-collapsing is impossible.
KIND_LORA = "lora"
KIND_ANIMATEDIFF_MOTION_LORA = "animatediff_motion_lora"
KIND_ANIMATEDIFF_MOTION_MODULE = "animatediff_motion_module"
KIND_CHECKPOINT = "checkpoint"
KIND_DIFFUSION_MODEL = "diffusion_model"
KIND_CONTROLNET = "controlnet"
KIND_VAE = "vae"
KIND_TEXT_ENCODER = "text_encoder"
KIND_CLIP_VISION = "clip_vision"
KIND_FACE_DETECTOR = "face_detector"
KIND_POSE_ESTIMATOR = "pose_estimator"
# Crossed over from the adopt tool (s46). Its `KIND_TO_TYPE` whitelist already spells
# them exactly like this, which is not a coincidence -- these names ARE the internal
# vocabulary that tool had been keeping privately.
KIND_T2I_ADAPTER = "t2i_adapter"
KIND_UPSCALER = "upscaler"

# AnimateDiff motion modules ride inside a UNet-shaped state dict, so the block prefix
# plus the temporal stack hanging off it IS the discriminator -- a depth model's
# `head.`/`pretrained.` trunk cannot reach that shape.
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
# ONCE, here, ahead of all rules -- doing it per-rule would oblige every future rule to
# remember to. Only the CLASSIFIER sees the stripped names; a tool that PRINTS evidence
# still prints the raw keys, because what is on disk is what a human is matching against.
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
# to offer. Both halves of that pair are now CONFIRMED against real files (s43: Wan 2.1
# and Qwen-Image), retiring the "inferred" note this comment used to carry for
# `encoder.downsamples.`.
VAE_ANATOMY_PREFIXES = ("encoder.down.", "decoder.up.",
                        "encoder.down_blocks.", "decoder.up_blocks.",
                        "encoder.downsamples.", "decoder.upsamples.")


def has_vae_anatomy(keys) -> bool:
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
# like `Mconv1_stage2.bias`. The openpose annotators already routed BY NAME
# (body_pose_model.pth / hand_pose_model.pth) are the same architecture family and spell
# their stages `model1_1.0.weight`, so one rule covers both -- and now covers them by
# CONTENT, which is what a renamed or oddly-named copy needs. Anchored at the start of the
# key and requiring the stage digits, so an ordinary `model.`/`model0.` prefix cannot match.
POSE_STAGE_KEY_RE = re.compile(r"^(?:Mconv\d+_stage\d+|model\d+_\d+)\.")


def classify_metadata(meta: dict) -> str | None:
    """KIND from a safetensors `__metadata__` block (`modelspec.architecture`).

    Separate from the key rules because it is a DECLARATION rather than evidence: the
    writer said what this is. Callers that have no metadata simply skip it.
    """
    # ⭐ A `<name>_te={...}` KEY IS A DECLARATION THAT THIS FILE IS A TEXT ENCODER,
    # and it generalizes past the file that surfaced it (s47): a repacked encoder
    # carries its own config blob under a key naming itself, and `_te` is the
    # ecosystem's abbreviation. Measured on qwen3vl_32b_minimax_h3_int8_convrot
    # (`minimax_h3_te={"num_hidden_layers": 50, ...}`). The `{` test is what keeps it
    # a declaration rather than a name that merely ends in those two letters.
    # ⭐ EXTENDED s47 (second pass): the same shape declares a VAE.
    # minimax_h3_audio_vae={"latents_mean": ..., "decoder_type": "bigvgan"} -- a
    # repacked component carries its own config blob under a key that names what it
    # is, and the ecosystem's two abbreviations are `_te` and `_vae`. Measured on
    # both real files. The `{` test is what keeps this a declaration rather than a
    # name that merely ends in those letters.
    for k, v in (meta or {}).items():
        if not str(v).lstrip().startswith("{"):
            continue
        if k.endswith("_te"):
            return KIND_TEXT_ENCODER
        if k.endswith("_vae"):
            return KIND_VAE
    arch = str((meta or {}).get("modelspec.architecture", "")).lower()
    if not arch:
        return None
    if "lora" in arch:
        return KIND_LORA
    if "controlnet" in arch:
        return KIND_CONTROLNET
    if arch.endswith("vae") or "/vae" in arch:
        return KIND_VAE
    return None


def classify_keys(keys) -> str | None:
    """KIND from tensor/attribute names, or None to abstain.

    ⚠️ ORDER IS LOAD-BEARING THROUGHOUT and each hop is justified where it sits. The
    short version: specific packaging beats generic shape, and unmistakable detector
    architectures beat both. Reordering this function silently reclassifies files.

    ⚠️ MATCHING IS ANCHORED (`startswith`), never substring, after the DataParallel
    strip. The adopt tool historically matched anywhere in a key; unifying on the looser
    form would wreck rules here (`enc.` would match `encoder.`). Anchored is the rule.

    Abstains rather than guessing: None means "the names say nothing", and the caller's
    other evidence -- filename, sidecars, API type -- decides.
    """
    # ONE normalization pass, ahead of every rule (see DATAPARALLEL_PREFIX).
    keys = strip_dataparallel(keys)
    # Only DOTTED keys have a prefix. Tensor names are always module-scoped, so this
    # costs nothing there -- but object-pickles reach this classifier with plain
    # ATTRIBUTE names harvested from __setstate__, and a bare `encoder`/`decoder`
    # attribute pair would otherwise synthesize "encoder."/"decoder." and be read as an
    # autoencoder state dict.
    prefixes = {k.split(".", 1)[0] + "." for k in keys if "." in k}

    def any_start(*pfx):
        return any(k.startswith(pfx) for k in keys)

    # loras first: lora tensor names embed base-model names (double_blocks etc.)
    if any(k.startswith(("lora_unet_", "lora_te")) or ".lora_A" in k
           or ".lora_B" in k or ".lora_down" in k or ".lora_up" in k for k in keys):
        return KIND_LORA
    if any_start("model.diffusion_model."):        # full checkpoint bundle
        return KIND_CHECKPOINT
    # AnimateDiff motion modules ride inside a UNet-shaped state dict (down_blocks./
    # mid_block./up_blocks.), so they must be tested BEFORE any generic block rule --
    # the giveaway is the temporal stack hanging off each block (ANIMATEDIFF_KEY_RE).
    if any(ANIMATEDIFF_KEY_RE.search(k) for k in keys):
        # ...and a motion LORA has the SAME layout as the motion module it adapts, so the
        # only thing separating them is the LoRA processor hanging off each attention
        # block. Without this the whole AnimateDiff-Motion-LoRAs family filed as motion
        # MODULES, where the loader that wants them (AnimateDiffLoraLoader) never looks.
        if any(m in k for k in keys for m in MOTION_LORA_MARKERS):
            return KIND_ANIMATEDIFF_MOTION_LORA
        return KIND_ANIMATEDIFF_MOTION_MODULE
    # T2I-adapter ABOVE the ControlNet rules: they are sibling conditioning mechanisms
    # and the adapter is the more specific claim. This is where the adopt tool always had
    # it; the scanner joined that order in s46 when the kind gained a destination, which
    # is what made the move free (before that, a T2I kind mapped to nothing, so hoisting
    # the rule turned chimeric files unclassified).
    # `adapter.body.` is MEASURED on real files (TencentARC t2i-adapter-canny-sdxl and
    # -depth-midas-sdxl: 38 tensors, every one under `adapter.`), so it anchors.
    # `adapter_down` is a SUBSTRING and is UNVERIFIED -- it crossed over from the adopt
    # tool, no specimen was found for it, and narrowing it silently would drop coverage
    # on a guess.
    if any_start("adapter.body.") or any("adapter_down" in k for k in keys):
        return KIND_T2I_ADAPTER
    if any_start("control_model."):
        return KIND_CONTROLNET
    # diffusers-format ControlNet: the zero-conv trunk that makes it a ControlNet rather
    # than the UNet it is otherwise shaped like. `controlnet_blocks.` /
    # `controlnet_x_embedder.` are the DiT-era spelling of the same idea (InstantX's
    # Qwen-Image ControlNets) -- and they must keep their place ABOVE the bare-DiT rules
    # below, which see img_in./txt_in./transformer_blocks. and call it a diffusion model
    # at 0.99: a DiT ControlNet has all of those too, plus the trunk that overrides them.
    if any_start("controlnet_cond_embedding.", "controlnet_down_blocks.",
                 "controlnet_mid_block.", "controlnet_blocks.",
                 "controlnet_x_embedder."):
        return KIND_CONTROLNET
    # ---- auxiliary DETECTOR / ESTIMATOR architectures. They sit above the generic model
    # shapes below because they are unmistakable -- nothing else names a tensor `BboxHead`
    # or `Mconv3_stage4` -- and because both families ship as bare .pth files whose only
    # other signal is a filename that can be actively misleading (`facenet.pth` is a pose
    # model, not a face-recognition net).
    if any_start(*RETINAFACE_HEAD_PREFIXES):
        return KIND_FACE_DETECTOR
    if any(POSE_STAGE_KEY_RE.match(k) for k in keys):
        return KIND_POSE_ESTIMATOR
    # A vision tower is evidence that a model CAN SEE, not that it IS an image encoder.
    # A multimodal LLM ships one bolted onto a language decoder (model.layers./
    # language_model.) through a projector -- and one of those, a gemma-3-12b shipped as
    # an LTX-2 text encoder, scored clip_vision@0.99 purely because `vision_model.` was
    # present (Jei's verdict, s30: it is a text encoder). The decoder is what settles it;
    # a real CLIP-Vision / IP-Adapter image_encoder has a vision tower and NOTHING else.
    # ⚠️ TWO SPELLINGS OF ONE TOWER (s47): HF's CLIP/SigLIP ships `vision_model.`,
    # open_clip and the Qwen-VL family ship `visual.`. Measured on a real file --
    # qwen3vl_32b_minimax_h3_int8_convrot has `model.layers.` + `visual.` and nothing
    # else, and classified as NOTHING because only the first spelling was listed.
    if any_start("vision_model.", "visual."):
        if any_start("model.layers.", "language_model.", "multi_modal_projector."):
            return KIND_TEXT_ENCODER
        return KIND_CLIP_VISION
    # LTX-2 projection layer: bridges text embeddings into the AV transformer. Loads from
    # ComfyUI/models/text_encoders despite not being an encoder itself.
    if any_start("text_embedding_projection."):
        return KIND_TEXT_ENCODER
    if any_start("diffusion_model.", "double_blocks.", "joint_blocks."):
        return KIND_DIFFUSION_MODEL
    # BARE DENOISERS. A *checkpoint* is defined by carrying several components at once
    # (unet + first_stage_model + conditioner); a file holding only the denoiser is a
    # diffusion model however big it is. These are the modern DiT layouts: Qwen-Image
    # (transformer_blocks. + img_in/txt_in), Wan (patch_embedding. + time_embedding.),
    # and the `net.`-rooted stacks with adaLN modulation.
    if any_start("transformer_blocks.") and any_start("img_in.", "txt_in."):
        return KIND_DIFFUSION_MODEL
    if any_start("patch_embedding.") and any_start("time_embedding."):
        return KIND_DIFFUSION_MODEL
    if any(k.startswith("net.blocks.") and "adaln_modulation" in k for k in keys):
        return KIND_DIFFUSION_MODEL
    # AV/video DiT (MiniMax-H3 FL2VA measured s47): a patchifier for video and/or audio
    # feeding a transformer stack with an output head. The patch projection is an INPUT
    # STEM -- only a denoiser has one -- and the second half of the test keeps a future
    # video VAE (which patchifies but has no `blocks.`/`final_layer.` roots, it has
    # encoder./decoder.) from landing here. Upstream agrees with the reading: Comfy-Org
    # publishes this file under diffusion_models/.
    if (any_start("video_patch_proj.", "audio_patch_proj.")
            and any_start("blocks.", "final_layer.")):
        return KIND_DIFFUSION_MODEL
    # 🚨 `encoder.block.` IS NOT A T5 FINGERPRINT ON ITS OWN, and this rule claimed a
    # VAE for months because it sat before the VAE check and matched on the prefix
    # alone. MEASURED (s47, range-fetched header): MiniMax-H3's audio VAE is a
    # DAC/BigVGAN autoencoder whose CONVOLUTION stack is also called `encoder.block.N`
    # -- 110 of them, with no SelfAttention, no relative_attention_bias, and
    # `mean_proj`/`logs_proj`/`latents_*` at the root. T5 names its TRANSFORMER stack
    # the same way (`encoder.block.0.layer.0.SelfAttention.q.weight`), so the block
    # prefix is a collision, not evidence. Ask for the attention that makes it T5.
    if (any_start("encoder.block.", "decoder.block.")
            and (any_start("shared.")
                 or any("SelfAttention" in k or "relative_attention_bias" in k
                        or "DenseReluDense" in k for k in keys))):
        return KIND_TEXT_ENCODER
    # `first_stage_model.` alone is a VAE still wearing a checkpoint's packaging; WITH
    # `model.diffusion_model.` it is that checkpoint's VAE section, which is why the
    # checkpoint rule above runs first. Measured, not argued (s43): it is ComfyUI's
    # base-class `vae_key_prefix`, stripped on load and re-added on save.
    # A VAE by DEFINITION projects to a mean and a log-variance and samples between
    # them; a plain autoencoder does not. Those projections (or the latent statistics
    # published beside them) are therefore a general VAE signature and not a MiniMax
    # special case -- and this is the rule that catches such a file when it arrives
    # with no metadata to declare itself.
    if (any_start("mean_proj.", "logs_proj.")
            or any_start("latents_mean", "latents_std")):
        return KIND_VAE
    if any_start("first_stage_model."):
        return KIND_VAE
    # An encoder/decoder PAIR is a shape, not an identity: it must be backed by real
    # autoencoder internals before it may claim `vae` (see VAE_ANATOMY_PREFIXES). Bare
    # encoder./decoder. falls through to abstain, and naming gets to decide.
    if ("decoder." in prefixes and "encoder." in prefixes
            and has_vae_anatomy(keys)):
        return KIND_VAE
    if any_start("text_model.", "t5.", "enc."):
        return KIND_TEXT_ENCODER
    # ---- LAST, on merit rather than staging: an architecture fingerprint says which
    # NETWORK this is, not what job it does, so it may only speak where every role rule
    # above has abstained. (An ESRGAN carries none of those roots, so nothing real is
    # shadowed by the position.)
    # ⚠️ ABSOLUTE ONLY. An uncertain architecture (DAT's spatial blocks, a bare SwinIR
    # window-attention table) abstains rather than returning a weak kind, because this
    # function is SHARED and the adopt tool stamps whatever it gets back as `absolute`
    # for routing -- a kind returned on uncertain evidence would override the CivitAI
    # API's word for the file. Both consumers still have naming rules for those files.
    if detect_upscaler_arch(keys)[1] == "absolute":
        return KIND_UPSCALER
    return None


# ── ARCHITECTURE fingerprints ─────────────────────────────────────────────────────────
# ⚠️ THESE MATCH AS SUBSTRINGS, AND THAT IS THE ONE PLACE THE ANCHORING RULE BENDS.
# Jei ruled anchored prefixes for the ROLE rules above (s46) and that ruling stands: a
# role announces itself at the ROOT of a state dict (`control_model.`, `first_stage_
# model.`), so anchoring costs nothing and stops `enc.` matching `encoder.`.
# An architecture does the opposite. `relative_position_bias_table` lives at
# `layers.0.residual_group.blocks.0.attn.relative_position_bias_table`; RealESRGAN's RDBs
# hang under `body.`. A fingerprint is a component NAME somewhere in the module tree, and
# anchoring it would simply delete the rule.
# ⭐ THAT ASYMMETRY IS WHY THE TWO TOOLS HAD DIFFERENT MATCHING SEMANTICS IN THE FIRST
# PLACE: the scanner mostly asks "what ROLE does this file play", the adopt tool mostly
# asks "which ARCHITECTURE is this upscaler". Neither was wrong; they were answering
# different questions and the difference was never written down.
#
# ⚠️ ORDER IS LOAD-BEARING (verbatim from the adopt tool): ScuNET first; HAT before
# SwinIR (HAT adds conv blocks to the same window attention); ESRGAN before RealESRGAN.
def detect_upscaler_arch(keys) -> tuple:
    """Super-resolution architecture from key signatures -> (arch, confidence).

    An ATTRIBUTE, not a kind: it says which network a file is, not what role it plays.
    The caller decides what to do with it -- the adopt tool routes on it
    (UPSCALER_ARCH_DIRS), the scanner does not link by architecture at all.
    """
    has = lambda sub: any(sub in k for k in keys)
    starts = lambda pre: any(k.startswith(pre) for k in keys)
    if starts("m_head") and has("m_body") and has("m_tail"):
        return ("ScuNET", "absolute")
    if has("relative_position_bias_table"):
        # SwinIR-family window attention; HAT adds conv blocks per group
        if has("conv_block") or has("conv_after_body"):
            return ("HAT", "absolute")
        if has("residual_group"):
            return ("SwinIR", "absolute")
        return ("SwinIR", "uncertain")
    if has("spatial_block") or has(".dat_"):
        return ("DAT", "uncertain")
    if has("model.1.sub.") or has("RRDB_trunk"):
        return ("ESRGAN", "absolute")
    if has("conv_first") and (has("rdb") or has("RDB") or has("conv_body")):
        return ("RealESRGAN", "absolute")
    return (None, None)


def detect_base_model(keys) -> tuple | None:
    """Base diffusion family from key signatures -> (family, confidence) or None.

    Another ATTRIBUTE. Distinct architectures (FLUX/SD3/SDXL) are absolute; SD1.x vs SD2
    is uncertain, because they differ by text-encoder plumbing rather than by shape.
    ⭐ THE s41 AUDIT FLAGGED `double_blocks.` -> FLUX.1 AS A POSSIBLE COLLISION WITH
    HunyuanVideo AND IT WAS RIGHT -- MEASURED s46, both files read over HTTP range
    requests rather than argued about:
      * Comfy-Org/flux1-dev-fp8: `model.diffusion_model.double_blocks.*` and a txt_in
        that is a plain linear -- exactly two keys, `txt_in.weight` / `txt_in.bias`.
      * Comfy-Org/HunyuanVideo_repackaged (t2v 720p): `model.model.double_blocks.*`
        (480 keys) AND `single_blocks.*` (320) -- so the FLUX rule fired on it at
        `absolute`, and the adopt tool would have rewritten a correct HunyuanVideo
        `baseModel` to FLUX.1.
    They are the same DiT family, so the block names cannot separate them; the text
    pathway can. HunyuanVideo refines text tokens through a stack
    (`txt_in.individual_token_refiner.`, plus c_embedder / t_embedder / input_embedder),
    where FLUX projects them once. That is why the HunyuanVideo test runs FIRST and is
    keyed on the refiner rather than on anything about the blocks.
    """
    has = lambda sub: any(sub in k for k in keys)
    if has("txt_in.individual_token_refiner."):
        return ("HunyuanVideo", "absolute")
    if has("double_blocks.") or has("single_blocks."):
        return ("FLUX.1", "absolute")
    if has("joint_blocks."):
        return ("SD3", "absolute")
    if has("conditioner.embedders.1"):
        return ("SDXL", "absolute")
    if has("cond_stage_model.model."):
        return ("SD2", "uncertain")
    if has("model.diffusion_model.") or has("cond_stage_model.transformer"):
        return ("SD1.x", "uncertain")
    return None


def packaged_vae(keys) -> bool:
    """True when a VAE section is present under a CHECKPOINT's packaging prefix.

    ⭐ SHARED DATA, ruled by Jei (s46), and it is the last signature the two tools were
    each spelling for themselves. It is a fact about the CONTAINER, not about the VAE:
    `first_stage_model.` is ComfyUI's base-class `vae_key_prefix`, stripped on load and
    re-added on save (measured s43, `supported_models_base.py:45` / `sd.py:2210`).
    Consumers read it differently ON PURPOSE and both are right: with a denoiser present
    it means "this checkpoint carries its VAE" (the adopt tool's `embedded_vae`);
    without one it means "this VAE is still wearing checkpoint packaging", which
    ComfyUI's VAELoader will not load -- the scanner's WARN.
    ⚠️ ANCHORED, per the role rule. The adopt tool matched it as a substring until s46.
    """
    return any(k.startswith("first_stage_model.") for k in strip_dataparallel(keys))


# Signatures that name a model OUTRIGHT, as opposed to the generic encoder+decoder shape
# that merely suggests an autoencoder (plenty of models have both).
#
# ⚠️ THIS EXISTS TO STOP A DRIFT THAT HAD ALREADY STARTED. It is the same knowledge the
# rules above encode, asked a different question -- not "what is this?" but "is this
# signature conclusive?" -- and until s46 the scanner kept a hand-maintained SECOND copy
# of the prefix list for its confidence model. Two lists of one fact drift in the usual
# way: add a rule, forget the other list, and a file whose shape is conclusive quietly
# rates as a guess. Callers keep their own scales; what a conclusive signature is WORTH
# is a policy question and stays with the tool that has a policy.
CONCLUSIVE_PREFIXES = (
    "model.diffusion_model.", "control_model.", "vision_model.", "diffusion_model.",
    "double_blocks.", "joint_blocks.", "encoder.block.", "decoder.block.",
    "first_stage_model.", "text_model.", "t5.", "enc.",
    # diffusers-format ControlNet zero-conv trunk; LTX-2 projection layer; the bare-DiT
    # roots (Qwen-Image / Wan / adaLN `net.` stacks). Each names its model outright.
    "controlnet_cond_embedding.", "controlnet_down_blocks.", "controlnet_mid_block.",
    "controlnet_blocks.", "controlnet_x_embedder.",
    "text_embedding_projection.", "transformer_blocks.", "patch_embedding.",
    # ...and the RetinaFace heads, which name their architecture as squarely as any of
    # the above (defined once, up with the rule that matches them).
) + RETINAFACE_HEAD_PREFIXES

LORA_KEY_MARKERS = (".lora_A", ".lora_B", ".lora_down", ".lora_up")
LORA_KEY_PREFIXES = ("lora_unet_", "lora_te")


def is_lora_key_set(keys) -> bool:
    """The generic LoRA spellings, in one place because three call sites want them."""
    return any(k.startswith(LORA_KEY_PREFIXES) or any(m in k for m in LORA_KEY_MARKERS)
               for k in keys)


def names_its_architecture(keys) -> bool:
    """True when the key set names what the file is, leaving nothing to infer.

    Prefix list plus the two signatures that are PATTERNS rather than fixed prefixes:
      * CPM/OpenPose stage convs name their architecture outright but vary per stage;
      * the AnimateDiff temporal stack is a COMPOSITE -- its block roots (down_blocks./
        mid_block./up_blocks.) are the generic UNet skeleton and must NEVER be treated as
        conclusive on their own, or half a collection inherits certainty from them. A
        temporal_transformer hanging off one of those blocks is a different matter: it
        names AnimateDiff as squarely as `control_model.` names a ControlNet.
    Expects keys with any DataParallel wrapper already stripped.
    """
    return (any(k.startswith(CONCLUSIVE_PREFIXES) for k in keys)
            or any(POSE_STAGE_KEY_RE.match(k) for k in keys)
            or any(ANIMATEDIFF_KEY_RE.search(k) for k in keys)
            or is_lora_key_set(keys)
            # an upscaler architecture identified ABSOLUTELY names the network as
            # squarely as any prefix above -- `model.1.sub.` is RRDB's own layout, not a
            # coincidence of naming. The uncertain tier (a bare SwinIR window-attention
            # table, DAT's spatial blocks) deliberately does NOT qualify.
            or detect_upscaler_arch(keys)[1] == "absolute")
