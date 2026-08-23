#!/usr/bin/env python3
"""Tests for model_scanner.py using a fully synthetic fixture:

- a fake HF hub cache (models--org--repo/snapshots/<rev>/... symlinking into blobs/<sha>)
  populated with tiny REAL-format files (valid safetensors headers + tiny tensors,
  minimal GGUF with magic + general.architecture, config.json repos, model_index.json
  diffusers repos, a CTranslate2 layout);
- a fake /opt/models local dir.

Exercised: fresh sync, incremental no-op (asserting NO header/metadata reads on the
second run via monkeypatched readers), user-file never-clobber, prune on blob removal,
--no-prune ownership carry-forward, dry-run, status, name collisions, and the v2
behaviors: classify-everything inventory (llm / asr / gguf-split),
repo-level diffusers units with member lists, sharded classified-not-linked, the
generic-filename provenance rule, and UNCLASSIFIED restricted to true unknowns --
including a reproduction of the Raiju field-test scenario.

Run:  python3 targets/comfyui/scripts/tests/test_model_scanner.py -v
"""

import ast
import contextlib
import hashlib
import io
import json
import os
import pickle
import pickletools
import shutil
import struct
import sys
import unittest
import zipfile
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import model_scanner as ms  # noqa: E402

import yaml  # noqa: E402


# ------------------------------------------------------------------ fixture builders

def safetensors_bytes(tensor_names, metadata=None) -> bytes:
    header, off = {}, 0
    for n in tensor_names:
        header[n] = {"dtype": "F32", "shape": [1], "data_offsets": [off, off + 4]}
        off += 4
    if metadata:
        header["__metadata__"] = metadata
    hj = json.dumps(header).encode()
    return len(hj).to_bytes(8, "little") + hj + b"\x00" * off


# --- torch LEGACY serialization (pre-1.6 / _use_new_zipfile_serialization=False) -------
# Not a zip: a SEQUENCE of pickles -- magic number, protocol version, sys_info, payload,
# storage-key list -- followed by the raw storage bytes. Hand-built because there is no
# torch in this environment (and none is wanted: the reader must never need one).
TORCH_LEGACY_MAGIC = 0x1950A86A20F9469CFC6C
TORCH_LEGACY_PROTOCOL_VERSION = 1001


class _StoragePickler(pickle.Pickler):
    """Emits BINPERSID for the ('storage', ...) tuples torch writes per tensor, which is
    what forces the reader's persistent_load to hand back an inert placeholder."""

    def persistent_id(self, obj):
        if isinstance(obj, tuple) and obj and obj[0] == "storage":
            return obj
        return None


def storage_ref(key="0", numel=4) -> tuple:
    return ("storage", "FloatStorage", key, "cpu", numel)


def torch_legacy_bytes(payload=None, *, preamble=True, trailer=True) -> bytes:
    """payload=None builds a stream that is PREAMBLE ONLY -- the truncated/corrupt case."""
    buf = io.BytesIO()
    if preamble:
        pickle.dump(TORCH_LEGACY_MAGIC, buf, protocol=2)
        pickle.dump(TORCH_LEGACY_PROTOCOL_VERSION, buf, protocol=2)
        pickle.dump({"protocol_version": TORCH_LEGACY_PROTOCOL_VERSION,
                     "little_endian": True,
                     "type_sizes": {"short": 2, "int": 4, "long": 8}},
                    buf, protocol=2)
    if payload is not None:
        _StoragePickler(buf, protocol=2).dump(payload)
    if trailer:
        pickle.dump(["0"], buf, protocol=2)     # serialized_storage_keys
        buf.write(b"\x00" * 128)                # raw storage bytes: NOT a pickle
    return buf.getvalue()


# The AnimateDiff motion-LORA tensor shape, verbatim from Jei's collection: a motion
# module's layout with a LoRA processor hanging off each attention block.
def motion_lora_keys() -> list:
    base = ("down_blocks.0.motion_modules.0.temporal_transformer"
            ".transformer_blocks.0.attention_blocks.0.processor")
    return [f"{base}.{proj}_lora.{d}.weight"
            for proj in ("to_q", "to_k", "to_v", "to_out") for d in ("down", "up")] + [
        "mid_block.motion_modules.0.temporal_transformer.norm.weight",
        "up_blocks.1.motion_modules.0.temporal_transformer"
        ".transformer_blocks.0.attention_blocks.1.processor.to_k_lora.up.weight",
    ]


# ...and the motion MODULE shape that must not move with it (same family, no processor).
def motion_module_keys() -> list:
    return ["down_blocks.0.motion_modules.0.temporal_transformer"
            ".transformer_blocks.0.attention_blocks.0.to_q.weight",
            "mid_block.motion_modules.0.temporal_transformer.norm.bias",
            "up_blocks.2.motion_modules.1.temporal_transformer.proj_out.weight"]


# A REAL latent autoencoder's insides, in both spellings that actually ship. Used
# wherever a fixture has to BE a VAE rather than merely be SHAPED like one: since
# heuristics 11 an encoder/decoder pair alone abstains (ParseNet has one too), so a
# fixture carrying only `encoder.conv_in`/`decoder.conv_out` is no longer a VAE fixture --
# it is the counterexample. Verbatim-shaped from the ldm and diffusers key vocabularies.
def ldm_vae_keys() -> list:
    return ["encoder.conv_in.weight",
            "encoder.down.0.block.0.conv1.weight",
            "decoder.conv_out.weight",
            "decoder.up.3.block.0.conv1.weight",
            "quant_conv.weight", "post_quant_conv.weight"]


def diffusers_vae_keys() -> list:
    return ["encoder.conv_in.weight",
            "encoder.down_blocks.0.resnets.0.conv1.weight",
            "decoder.conv_out.weight",
            "decoder.up_blocks.0.resnets.0.conv1.weight",
            "quant_conv.weight", "post_quant_conv.weight"]


# ...and the THIRD spelling, from Jei's field dump of the real wan_2.1_vae.safetensors
# (s33): a causal-video autoencoder. Two things make it its own case -- the resample
# stacks are spelled `upsamples`/`downsamples`, and there is NO quant_conv /
# post_quant_conv anywhere in the file, so the ldm/diffusers anatomy finds nothing to
# match. Its top-level prefixes are `conv1, conv2, decoder, encoder`, hence the bare
# root convs here. PROVENANCE: the `decoder.upsamples.` keys are verbatim from the dump;
# `encoder.downsamples.` was the symmetric encoder spelling, inferred --
# ✅ CONFIRMED s43 by range-reading the real header from
# Comfy-Org/Wan_2.1_ComfyUI_repackaged split_files/vae/wan_2.1_vae.safetensors:
# 194 tensors, prefixes exactly `conv1. conv2. decoder. encoder.`, and 62 keys under
# `encoder.downsamples.` (`encoder.downsamples.0.residual.0.gamma`, ...). The same read
# showed Qwen-Image's VAE is the IDENTICAL layout, so this is a family, not one file.
def wan_vae_keys() -> list:
    return ["conv1.weight", "conv2.weight",
            "decoder.upsamples.0.residual.0.gamma",
            "decoder.upsamples.0.residual.2.bias",
            "encoder.downsamples.0.residual.0.gamma",
            "encoder.conv1.weight", "decoder.conv2.bias"]


# ...and the counterexample itself: ParseNet (parsing_parsenet.pth, 85.3 MB), a face-
# PARSING/segmentation net. Prefixes verbatim from Jei's field dump -- `body, decoder,
# encoder, out_img_conv, out_mask_conv`, sample key `body.0.conv1.conv2d`.
def parsenet_keys() -> list:
    return ["body.0.conv1.conv2d.weight", "body.1.conv2.conv2d.weight",
            "encoder.0.weight", "encoder.2.weight",
            "decoder.0.weight", "decoder.2.weight",
            "out_img_conv.weight", "out_mask_conv.weight"]


# RetinaFace (facexlib) detection_Resnet50_Final.pth, DataParallel-wrapped exactly as it
# ships: torch welds `module.` onto every key, so the file inspects as prefixes
# `_metadata, module` and nothing else. The `_metadata` OrderedDict is included because
# it is where the phantom EMPTY prefix comes from -- its root module is keyed on "".
def retinaface_state_dict() -> dict:
    d = {f"module.{k}": storage_ref() for k in (
        "body.conv1.weight", "fpn.output1.0.weight", "ssh1.conv3X3.0.weight",
        "ClassHead.0.conv1x1.weight", "BboxHead.0.conv1x1.weight",
        "LandmarkHead.0.conv1x1.weight")}
    d["_metadata"] = {"": {}, "module": {}, "module.body": {}}
    return d


# facenet.pth (153.7 MB): a Convolutional Pose Machine landmark model, whatever its
# filename claims. Prefixes `Mconv1_stage2 ... Mconv7_stage6` (+44 more in the field).
def cpm_state_dict() -> dict:
    d = {f"Mconv{i}_stage{s}.{p}": storage_ref()
         for s in (2, 6) for i in (1, 7) for p in ("weight", "bias")}
    d["conv1_1.weight"] = storage_ref()
    return d


def gguf_bytes(architecture=None, extra_kv=None) -> bytes:
    """Minimal valid GGUF: magic, v3, 0 tensors, metadata kv (string type only)."""
    def s(x: str) -> bytes:
        b = x.encode()
        return len(b).to_bytes(8, "little") + b
    kvs = []
    if architecture is not None:
        kvs.append(("general.architecture", architecture))
    for k, v in (extra_kv or {}).items():
        kvs.append((k, v))
    out = b"GGUF" + struct.pack("<I", 3) + struct.pack("<QQ", 0, len(kvs))
    for k, v in kvs:
        out += s(k) + struct.pack("<I", 8) + s(v)
    return out


class Fixture:
    """Builds a synthetic HF cache + local models dir + data dir in a tmp root."""

    REV = "0123456789abcdef0123456789abcdef01234567"

    def __init__(self, root: Path):
        self.root = root
        self.cache = root / "hub"
        self.models = root / "opt-models"
        self.tree = root / "data" / "model-tree"
        self.registry = root / "data" / "model-registry.yaml"
        self.cache.mkdir(parents=True)

    def add_hf_file(self, repo: str, relpath: str, content: bytes) -> Path:
        """Standard hub layout: blobs/<sha256> + snapshots/<rev>/<relpath> symlink."""
        repo_dir = self.cache / ("models--" + repo.replace("/", "--"))
        sha = hashlib.sha256(content).hexdigest()
        blob = repo_dir / "blobs" / sha
        blob.parent.mkdir(parents=True, exist_ok=True)
        blob.write_bytes(content)
        (repo_dir / "refs").mkdir(exist_ok=True)
        (repo_dir / "refs" / "main").write_text(self.REV)
        link = repo_dir / "snapshots" / self.REV / relpath
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(os.path.relpath(blob, link.parent))
        return blob

    def add_hf_aux(self, repo: str, relpath: str, text: str) -> Path:
        """Non-weight sidecar (config.json, model_index.json, vocabulary.txt, ...)."""
        f = (self.cache / ("models--" + repo.replace("/", "--"))
             / "snapshots" / self.REV / relpath)
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
        return f

    def add_local_file(self, relpath: str, content: bytes) -> Path:
        f = self.models / relpath
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(content)
        return f

    def args(self, *extra: str) -> list:
        return ["--cache-dir", str(self.cache), "--models-dir", str(self.models),
                "--tree", str(self.tree), "--registry", str(self.registry),
                *extra]

    def sync(self, *extra: str) -> tuple[int, str]:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = ms.main(["sync", *self.args(*extra)])
        return rc, buf.getvalue()

    def status(self) -> tuple[int, str]:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = ms.main(["status", *self.args()])
        return rc, buf.getvalue()

    def inspect(self, *extra: str) -> tuple[int, str]:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = ms.main(["inspect", *self.args(*extra)])
        return rc, buf.getvalue()

    def rename(self, *extra: str) -> tuple[int, str]:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = ms.main(["rename", *self.args(*extra)])
        return rc, buf.getvalue()

    def load_registry(self) -> dict:
        return yaml.safe_load(self.registry.read_text())


def populate_standard(fx: Fixture) -> None:
    """The standard menagerie used by most tests (one file per ladder step)."""
    # step 1: path segment (Comfy-Org split_files repack)
    fx.add_hf_file("Comfy-Org/flux-repack", "split_files/vae/ae.safetensors",
                   safetensors_bytes(["blah.weight"]))
    # step 2: filename keyword
    fx.add_hf_file("acme/style-pack", "pixel-style-lora.safetensors",
                   safetensors_bytes(["whatever.weight"]))
    # step 4: safetensors header (neutral name/path)
    fx.add_hf_file("acme/flux-dev", "flux1-dev.safetensors",
                   safetensors_bytes(["double_blocks.0.img_attn.qkv.weight",
                                      "single_blocks.1.linear1.weight"]))
    fx.add_hf_file("acme/full-sd", "sd15-full.safetensors",
                   safetensors_bytes(["model.diffusion_model.input_blocks.0.0.weight",
                                      "first_stage_model.decoder.conv_in.weight",
                                      "cond_stage_model.transformer.x.weight"]))
    fx.add_hf_file("acme/vision", "model2.safetensors",
                   safetensors_bytes(["vision_model.encoder.layers.0.mlp.fc1.weight"]))
    # step 5: sibling config.json -> HF LLM repo -> inventory category `llm`
    fx.add_hf_file("meta/tiny-llm", "pytorch_model.bin", b"\x80\x02junkjunk")
    fx.add_hf_aux("meta/tiny-llm", "config.json",
                  json.dumps({"architectures": ["LlamaForCausalLM"]}))
    # step 6: GGUF metadata (neutral names so earlier steps pass through)
    fx.add_hf_file("city96/mystery-diffusion", "mystery-model-q4.gguf",
                   gguf_bytes("flux"))
    fx.add_hf_file("bartowski/assistant", "assistant-8b-q4.gguf",
                   gguf_bytes("llama"))
    # unclassifiable safetensors: no signal anywhere -> a TRUE unknown
    fx.add_hf_file("acme/enigma", "mystery.safetensors",
                   safetensors_bytes(["foo.bar"]))
    # local /opt/models: segment-classified + filename-classified (.pth: no header)
    fx.add_local_file("loras/local-thing.safetensors",
                      safetensors_bytes(["anything.weight"]))
    fx.add_local_file("misc/esrgan-4x.pth", b"\x00" * 64)


EXPECTED_LINKS = {
    "vae/ae.safetensors",
    "loras/pixel-style-lora.safetensors",
    "diffusion_models/flux1-dev.safetensors",
    "checkpoints/sd15-full.safetensors",
    "clip_vision/model2.safetensors",
    "diffusion_models/mystery-model-q4.gguf",
    "loras/local-thing.safetensors",
    "upscale_models/esrgan-4x.pth",
}
# v2: only genuinely unknown files stay unclassified
EXPECTED_UNCLASSIFIED_DISPLAYS = {"acme/enigma/mystery.safetensors"}
# v2: identifiable-but-not-comfyui files get real inventory categories, links:[]
EXPECTED_INVENTORY = {
    "meta/tiny-llm/pytorch_model.bin": "llm",
    "bartowski/assistant/assistant-8b-q4.gguf": "llm",
}


def populate_raiju(fx: Fixture) -> dict:
    """Reproduce the Raiju field-test cache: a diffusers-format FLUX.1-Fill-dev repo
    (generic component filenames) + a CTranslate2 faster-whisper model.bin."""
    flux = "black-forest-labs/FLUX.1-Fill-dev"
    # A real AutoencoderKL, anatomy included (heuristics 11): the fixture used to carry a
    # bare encoder./decoder. pair, which no longer identifies a VAE by content -- so the
    # raiju assertions would have silently started passing on NAMING alone.
    vae_blob = fx.add_hf_file(flux, "vae/diffusion_pytorch_model.safetensors",
                              safetensors_bytes(diffusers_vae_keys()))
    te_blob = fx.add_hf_file(flux, "text_encoder/model.safetensors",
                             safetensors_bytes(["text_model.encoder.layers.0.q.weight"]))
    fx.add_hf_aux(flux, "model_index.json",
                  json.dumps({"_class_name": "FluxFillPipeline"}))
    fx.add_hf_aux(flux, "vae/config.json",
                  json.dumps({"_class_name": "AutoencoderKL"}))
    fx.add_hf_aux(flux, "text_encoder/config.json",
                  json.dumps({"architectures": ["CLIPTextModel"]}))

    whisper = "Systran/faster-whisper-large-v2"
    wh_blob = fx.add_hf_file(whisper, "model.bin", b"ct2-binary-not-a-torch-file")
    fx.add_hf_aux(whisper, "config.json",
                  json.dumps({"alignment_heads": [[5, 3]], "lang_ids": [50259]}))
    fx.add_hf_aux(whisper, "vocabulary.txt", "<|token|>\n")
    fx.add_hf_aux(whisper, "tokenizer.json", "{}")
    return {"vae": "hf:" + vae_blob.name, "text_encoder": "hf:" + te_blob.name,
            "whisper": "hf:" + wh_blob.name,
            "unit": f"diffusers:{flux}@{Fixture.REV}"}


def tree_links(tree: Path) -> set:
    if not tree.is_dir():
        return set()
    return {str(p.relative_to(tree)) for p in tree.rglob("*") if not p.is_dir()}


def no_read_patches():
    return (mock.patch.object(ms, "read_safetensors_header",
                              side_effect=AssertionError("header read on no-op")),
            mock.patch.object(ms, "read_gguf_metadata",
                              side_effect=AssertionError("gguf read on no-op")),
            mock.patch.object(ms, "read_config_json",
                              side_effect=AssertionError("config read on no-op")))


class ScannerTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory(prefix="scanner-test-")
        self.fx = Fixture(Path(self._tmp.name))
        self.addCleanup(self._tmp.cleanup)

    # ------------------------------------------------------------------ fresh sync
    def test_fresh_sync_builds_expected_tree(self):
        populate_standard(self.fx)
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), EXPECTED_LINKS)
        for rel in EXPECTED_LINKS:
            dst = self.fx.tree / rel
            self.assertTrue(dst.is_symlink(), rel)
            resolved = dst.resolve()
            self.assertTrue(resolved.is_file(), rel)
            # HF links must point at the resolved blob path (realpath)
            if not rel.startswith(("loras/local-", "upscale_models/")):
                self.assertEqual(resolved.parent.name, "blobs", rel)

        reg = self.fx.load_registry()
        # 3 since s35 (the top-level `renames` ledger). Entries are unchanged from v2,
        # which the assertions below this line are the standing proof of.
        self.assertEqual(reg["version"], 3)
        # ...and a store nobody has renamed anything in does not grow the key at all
        self.assertNotIn("renames", reg)
        cats = {e["display"]: e["category"] for e in reg["entries"].values()}
        for display, want in EXPECTED_INVENTORY.items():
            self.assertEqual(cats[display], want, display)
        uncls = {d for d, c in cats.items() if c == "unclassified"}
        self.assertEqual(uncls, EXPECTED_UNCLASSIFIED_DISPLAYS)
        for e in reg["entries"].values():  # inventory + unclassified: never linked
            if e["category"] == "unclassified" or e["category"] in ms.INVENTORY_CATEGORIES:
                self.assertEqual(e["links"], [])
        owned = {l for e in reg["entries"].values() for l in e["links"]}
        self.assertEqual(owned, EXPECTED_LINKS)

    def test_unclassified_report_lists_only_true_unknowns(self):
        populate_standard(self.fx)
        rc, out = self.fx.sync()
        uncls_lines = [l for l in out.splitlines() if l.startswith("UNCLASSIFIED")]
        self.assertEqual(len(uncls_lines), 1, out)
        self.assertIn("acme/enigma/mystery.safetensors", uncls_lines[0])
        # identifiable non-comfyui files are counted as inventory, not unclassified
        self.assertIn("1 unclassified", out)

    # ------------------------------------------------------------- raiju scenario
    def test_raiju_scenario_diffusers_plus_ctranslate2(self):
        ids = populate_raiju(self.fx)
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        # generic component filenames -> provenance-derived link names
        self.assertEqual(tree_links(self.fx.tree), {
            "vae/FLUX.1-Fill-dev--vae.safetensors",
            "text_encoders/FLUX.1-Fill-dev--text_encoder.safetensors",
        })
        reg = self.fx.load_registry()
        ent = reg["entries"]
        # component entries: role-classified, provenance-named links
        self.assertEqual(ent[ids["vae"]]["category"], "vae")
        self.assertEqual(ent[ids["vae"]]["links"],
                         ["vae/FLUX.1-Fill-dev--vae.safetensors"])
        self.assertEqual(ent[ids["text_encoder"]]["category"], "text_encoders")
        # repo-level diffusers unit with explicit member relationship
        unit = ent[ids["unit"]]
        self.assertEqual(unit["category"], "diffusers")
        self.assertEqual(unit["links"], [])
        self.assertEqual(sorted(unit["members"]),
                         sorted([ids["vae"], ids["text_encoder"]]))
        # CTranslate2-container whisper: role-named `asr`, inventory-only
        self.assertEqual(ent[ids["whisper"]]["category"], "asr")
        self.assertEqual(ent[ids["whisper"]]["links"], [])
        # nothing is unclassified in this cache
        self.assertNotIn("UNCLASSIFIED", out)
        self.assertIn("0 unclassified", out)
        self.assertIn("REPO  black-forest-labs/FLUX.1-Fill-dev@", out)
        # steady state: no re-inspection
        p1, p2, p3 = no_read_patches()
        with p1 as h, p2 as g, p3 as c:
            rc, out2 = self.fx.sync()
        self.assertEqual((h.call_count, g.call_count, c.call_count), (0, 0, 0))
        self.assertIn("0 new", out2)

    def test_detector_aux_family_routes_to_conventional_dirs(self):
        """Raiju s26 gap: adetailer/YOLO, SAM, face-parsing, pose, and arch-unknown
        upscaler .pt/.pth files used to fall through to `unclassified`; they must now
        land in the Impact-Pack / ReActor / ControlNet-aux conventional subdirs."""
        # local /opt/models drop-ins (bare .pt/.pth, never content-sniffed)
        self.fx.add_local_file("face_yolov8n.pt", b"\x80\x02yolo-pickle")
        self.fx.add_local_file("person_yolov8m-seg.pt", b"\x80\x02yolo-pickle")
        self.fx.add_local_file("sam_vit_b_01ec64.pth", b"\x00" * 32)
        self.fx.add_local_file("parsing_parsenet.pth", b"\x00" * 32)
        self.fx.add_local_file("body_pose_model.pth", b"\x00" * 32)
        self.fx.add_local_file("4x-ClearRealityV1.pth", b"\x00" * 32)
        # a HF-cache adetailer detector (Bingsu) reaches the same rule
        self.fx.add_hf_file("Bingsu/adetailer", "hand_yolov8s.pt", b"\x80\x02yolo")
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), {
            "ultralytics/bbox/face_yolov8n.pt",
            "ultralytics/bbox/hand_yolov8s.pt",
            "ultralytics/segm/person_yolov8m-seg.pt",
            "sams/sam_vit_b_01ec64.pth",
            "facedetection/parsing_parsenet.pth",
            "controlnet_aux/body_pose_model.pth",
            "upscale_models/4x-ClearRealityV1.pth",
        })
        # every one is a real classification now -- nothing left unclassified
        self.assertNotIn("UNCLASSIFIED", out)
        self.assertIn("0 unclassified", out)
        reg = self.fx.load_registry()
        cats = {e["display"]: e["category"] for e in reg["entries"].values()}
        self.assertEqual(cats["face_yolov8n.pt"], "ultralytics/bbox")
        self.assertEqual(cats["person_yolov8m-seg.pt"], "ultralytics/segm")
        self.assertEqual(cats["sam_vit_b_01ec64.pth"], "sams")
        self.assertEqual(cats["parsing_parsenet.pth"], "facedetection")
        self.assertEqual(cats["body_pose_model.pth"], "controlnet_aux")
        self.assertEqual(cats["4x-ClearRealityV1.pth"], "upscale_models")

    def test_sharded_diffusers_component_classified_not_linked(self):
        repo = "acme/big-pipeline"
        self.fx.add_hf_aux(repo, "model_index.json",
                           json.dumps({"_class_name": "SomePipeline"}))
        b1 = self.fx.add_hf_file(
            repo, "transformer/diffusion_pytorch_model-00001-of-00002.safetensors",
            safetensors_bytes(["part1.weight"]))
        b2 = self.fx.add_hf_file(
            repo, "transformer/diffusion_pytorch_model-00002-of-00002.safetensors",
            safetensors_bytes(["part2.weight"]))
        self.fx.add_hf_aux(repo,
                           "transformer/diffusion_pytorch_model.safetensors.index.json",
                           "{}")
        rc, out = self.fx.sync()
        self.assertEqual(tree_links(self.fx.tree), set())  # never linked
        reg = self.fx.load_registry()
        for blob in (b1, b2):
            e = reg["entries"]["hf:" + blob.name]
            self.assertEqual(e["category"], "diffusion_models")  # role still known
            self.assertTrue(e.get("sharded"))
            self.assertEqual(e["links"], [])
        unit = reg["entries"][f"diffusers:{repo}@{Fixture.REV}"]
        self.assertEqual(sorted(unit["members"]),
                         sorted(["hf:" + b1.name, "hf:" + b2.name]))
        self.assertNotIn("UNCLASSIFIED", out)

    def test_sharded_llm_repo_is_llm_not_linked(self):
        repo = "meta/big-llm"
        self.fx.add_hf_aux(repo, "config.json",
                           json.dumps({"architectures": ["Qwen2ForCausalLM"]}))
        b1 = self.fx.add_hf_file(repo, "model-00001-of-00002.safetensors",
                                 safetensors_bytes(["model.layers.0.q.weight"]))
        b2 = self.fx.add_hf_file(repo, "model-00002-of-00002.safetensors",
                                 safetensors_bytes(["model.layers.9.q.weight"]))
        rc, out = self.fx.sync()
        self.assertEqual(tree_links(self.fx.tree), set())
        reg = self.fx.load_registry()
        for blob in (b1, b2):
            e = reg["entries"]["hf:" + blob.name]
            self.assertEqual(e["category"], "llm")
            self.assertTrue(e.get("sharded"))
            self.assertEqual(e["links"], [])
        self.assertNotIn("UNCLASSIFIED", out)

    def test_split_gguf_parts(self):
        b1 = self.fx.add_hf_file("tng/huge-llm", "huge-00001-of-00002.gguf",
                                 gguf_bytes("llama", {"split.tensors.count": "42"}))
        # part 2 carries no general.architecture -> identified as a split part
        b2 = self.fx.add_hf_file("tng/huge-llm", "huge-00002-of-00002.gguf",
                                 gguf_bytes(None, {"split.no": "2"}))
        rc, out = self.fx.sync()
        self.assertEqual(tree_links(self.fx.tree), set())
        reg = self.fx.load_registry()
        e1 = reg["entries"]["hf:" + b1.name]
        self.assertEqual(e1["category"], "llm")
        self.assertTrue(e1.get("sharded"))
        e2 = reg["entries"]["hf:" + b2.name]
        self.assertEqual(e2["category"], "gguf-split")
        self.assertTrue(e2.get("sharded"))
        self.assertNotIn("UNCLASSIFIED", out)
        # a sharded DIFFUSION gguf is role-classified but still not linked
        b3 = self.fx.add_hf_file("tng/huge-flux", "flux-00001-of-00002.gguf",
                                 gguf_bytes("flux"))
        rc, out = self.fx.sync()
        e3 = self.fx.load_registry()["entries"]["hf:" + b3.name]
        self.assertEqual(e3["category"], "diffusion_models")
        self.assertTrue(e3.get("sharded"))
        self.assertEqual(e3["links"], [])
        self.assertEqual(tree_links(self.fx.tree), set())

    # ------------------------------------------------------- generic-filename rule
    def test_generic_name_rule(self):
        # generic basename, no subdir: repo-tail--stem
        self.fx.add_hf_file("acme/cool-vae", "model.safetensors",
                            safetensors_bytes(["first_stage_model.decoder.w"]))
        # generic basename, subdir provenance (non-diffusers repo)
        self.fx.add_hf_file("acme/bundle", "vae/diffusion_pytorch_model.safetensors",
                            safetensors_bytes(["decoder.a", "encoder.b"]))
        # non-generic basename keeps its plain name
        self.fx.add_hf_file("acme/named", "nice-vae.safetensors",
                            safetensors_bytes(["x.weight"]))
        # local generic file under a category subdir: provenance from dirs
        self.fx.add_local_file("vae/model.fp16.safetensors",
                               safetensors_bytes(["y.weight"]))
        rc, out = self.fx.sync()
        self.assertEqual(tree_links(self.fx.tree), {
            "vae/cool-vae--model.safetensors",
            "vae/bundle--vae.safetensors",
            "vae/nice-vae.safetensors",
            "vae/vae--model.fp16.safetensors",
        })

    def test_preferred_link_name_unit(self):
        self.assertEqual(ms.preferred_link_name(
            "FLUX.1-Fill-dev", Path("vae/diffusion_pytorch_model.safetensors")),
            "FLUX.1-Fill-dev--vae.safetensors")
        self.assertEqual(ms.preferred_link_name(
            "FLUX.1-Fill-dev", Path("text_encoder/model.safetensors")),
            "FLUX.1-Fill-dev--text_encoder.safetensors")
        self.assertEqual(ms.preferred_link_name("repo", Path("pytorch_model.bin")),
                         "repo--pytorch_model.bin")
        self.assertEqual(ms.preferred_link_name("repo", Path("flux1-dev.safetensors")),
                         "flux1-dev.safetensors")
        # local file at models root: no provenance to derive -> plain name kept
        self.assertEqual(ms.preferred_link_name(None, Path("model.bin")), "model.bin")
        self.assertEqual(ms.preferred_link_name(None, Path("whisper/model.bin")),
                         "whisper--model.bin")

    # ---------------------------------------------------------- incremental no-op
    def test_incremental_noop_reads_no_headers(self):
        populate_standard(self.fx)
        self.fx.sync()
        p1, p2, p3 = no_read_patches()
        with p1 as h, p2 as g, p3 as c:
            rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual((h.call_count, g.call_count, c.call_count), (0, 0, 0))
        self.assertIn("0 new", out)
        self.assertIn("0 linked", out)
        self.assertEqual(tree_links(self.fx.tree), EXPECTED_LINKS)

    def test_incremental_classifies_only_delta(self):
        populate_standard(self.fx)
        self.fx.sync()
        # Repo name is deliberately NEUTRAL (no family keyword): the safetensors header
        # must stay the deciding signal here, or the repo-name pass would classify it
        # first and this test would stop measuring what it means to measure.
        self.fx.add_hf_file("acme/shiny-things", "shiny.safetensors",
                            safetensors_bytes(["first_stage_model.decoder.w"]))
        real_read = ms.read_safetensors_header
        with mock.patch.object(ms, "read_safetensors_header",
                               side_effect=real_read) as h:
            rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        # TWO reads for the ONE new file, and none for anything else: the ladder reads
        # the header to classify, then gather_votes reads it again to score confidence.
        # That is the deliberate cost of annotate-only mode, where the ladder stays the
        # authority and the measures only describe its answer; when the score becomes
        # authoritative the two passes collapse into one. The property under test --
        # cached files are never re-inspected -- is unaffected.
        self.assertEqual(h.call_count, 2)  # only the new file, ladder + confidence pass
        self.assertIn("vae/shiny.safetensors", tree_links(self.fx.tree))

    # ------------------------------------------- s29 Raiju classification gaps
    def test_pth_family_rules(self):
        """.pt/.pth pickles are never content-sniffed, so the filename rules are the
        only signal. These six were `unclassified` on Raiju (2026-08-08)."""
        for name, want in {
            "control_v11p_sd15_softedge.pth": "controlnet",
            "control_v11p_sd15s2_lineart_anime.pth": "controlnet",
            "control_sd15_canny.pth": "controlnet",
            "control_lora_rank128_v11f1e_sd15_tile.safetensors": "controlnet",
            "dpt_hybrid-midas-501f0c75.pt": "controlnet_aux",
            "codeformer-v0.1.0.pth": "facerestore_models",
            "GFPGANv1.4.pth": "facerestore_models",
        }.items():
            self.assertEqual(ms.classify_by_filename(name), want, name)

    def test_repo_name_signal(self):
        """The repo names the family when the filename cannot -- and stays silent for
        repos that name no family, so neutral repos still fall through to the sniffers."""
        self.assertEqual(ms.repo_of("vivym/face-parsing-bisenet/79999_iter.pth"),
                         "face-parsing-bisenet")
        for repo, want in {
            "face-parsing-bisenet": "facedetection",   # file is a bare iteration count
            "yolo-detailers": "ultralytics/bbox",      # file is eyes-full-v1.pt
            "ControlNet-v1-1": "controlnet",
        }.items():
            self.assertEqual(ms.classify_by_filename(repo), want, repo)
        for neutral in ("Wan_2.2_ComfyUI_Repackaged", "FLUX.1-Fill-dev",
                        "Step-3.5-Flash-REAP-121B-A11B-i1-GGUF", "IP-Adapter",
                        "shiny-things"):
            self.assertIsNone(ms.classify_by_filename(neutral), neutral)

    def test_repo_name_pass_is_hf_only_and_last(self):
        """Repo-name is the weakest signal: filename wins over it, and local files
        (whose display is a filesystem path) never consult it."""
        self.assertEqual(ms.classify_by_filename("yolo11x-seg.pt"), "ultralytics/segm")

    # ------------------------------------- s31 naming-rule gaps (real 190-file scan)
    def test_depth_anything_is_an_annotator_not_a_controlnet(self):
        """Three real files that scanned as `controlnet`. The family name is only ever
        visible as a SUBSTRING (`depth_anything` is never one token), and the ControlNet
        rule claimed the bare `depth` token before the annotator rule was ever reached."""
        for name in ("depth_anything_vitl14.pth",
                     "metric_video_depth_anything_vitl.pth",
                     "depth_anything_v2_vitl_fp16.safetensors"):
            self.assertEqual(ms.classify_by_filename(name), "controlnet_aux", name)
        # ...while the ControlNets that share the token, or are named after the annotator
        # they consume, must keep it -- that is why only unmistakable families are hoisted.
        for name in ("control_v11f1p_sd15_depth.pth", "control_sd15_depth.pth",
                     "control_sd15_hed.pth", "control_v11p_sd15_mlsd.pth",
                     "flux1-canny-dev.safetensors"):
            self.assertEqual(ms.classify_by_filename(name), "controlnet", name)
        # and an explicit ControlNet spelling outranks the family name outright
        self.assertEqual(ms.classify_by_filename("depth_anything_controlnet.safetensors"),
                         "controlnet")

    def test_annotators_repo_names_the_family(self):
        """Four real files from lllyasviel/Annotators that scanned as unclassified: three
        carry no signal whatsoever, and `ZoeD` normalizes to `zoed` so the `zoe` token rule
        missed it. The repo name answers for all four at once."""
        self.assertEqual(ms.classify_by_filename("ZoeD_M12_N.pt"), "controlnet_aux")
        for signal_free in ("erika.pth", "netG.pth", "sk_model.pth"):
            self.assertIsNone(ms.classify_by_filename(signal_free), signal_free)
        self.assertEqual(ms.repo_of("lllyasviel/Annotators/erika.pth"), "Annotators")
        self.assertEqual(ms.classify_by_filename("Annotators"), "controlnet_aux")
        # end to end: the repo-name pass is what rescues the signal-free three
        names = ("ZoeD_M12_N.pt", "erika.pth", "netG.pth", "sk_model.pth")
        for name in names:
            self.fx.add_hf_file("lllyasviel/Annotators", name,
                                b"\x00" * 32 + name.encode())
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree),
                         {f"controlnet_aux/{n}" for n in names})
        self.assertNotIn("UNCLASSIFIED", out)

    def test_qualified_path_segment_matches_by_suffix(self):
        """nai_hypernetworks/nai_*.pt scanned as unclassified: the segment match was EXACT,
        so a dir that merely QUALIFIES the category name missed it."""
        def seg(*parts):
            return SimpleNamespace(rel_dir_parts=parts)

        self.assertEqual(ms.classify_by_segments(seg("nai_hypernetworks")),
                         "hypernetworks")
        self.assertEqual(ms.classify_by_segments(seg("sdxl-loras")), "loras")
        # THE BOUNDARY, pinned: a separator is required (else `unclip` reads as `clip`),
        # the match is a SUFFIX only (a dir parked as `hypernetworks_disabled` stays out),
        # and a control_lora dir keeps the precedence the filename rules give it.
        self.assertIsNone(ms.classify_by_segments(seg("unclip")))
        self.assertIsNone(ms.classify_by_segments(seg("my_models")))
        self.assertIsNone(ms.classify_by_segments(seg("hypernetworks_disabled")))
        self.assertEqual(ms.classify_by_segments(seg("control_lora")), "controlnet")
        # an EXACT match anywhere in the path still outranks a qualified one
        self.assertEqual(ms.classify_by_segments(seg("nai_hypernetworks", "loras")),
                         "loras")
        # end to end through the local models dir
        names = ("nai_aini.pt", "nai_sxd.pt", "nai_anime_v1.pt", "nai_anime_v2.pt")
        for name in names:
            self.fx.add_local_file(f"nai_hypernetworks/{name}",
                                   b"\x00" * 32 + name.encode())
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree),
                         {f"hypernetworks/{n}" for n in names})
        self.assertNotIn("UNCLASSIFIED", out)

    # ------------------------------------------------- s29 pickle content sniffing
    @staticmethod
    def _global_reduce(module, name):
        """Hand-built pickle: GLOBAL <module>.<name>; EMPTY_TUPLE; REDUCE; STOP.
        Hand-built because Python refuses to PICKLE a class it cannot import -- which
        is precisely the situation these files put us in."""
        return b'\x80\x04c' + f"{module}\n{name}\n".encode() + b')R.'

    @staticmethod
    def _object_pickle(module, name, zipped=True) -> bytes:
        """A REAL object-pickle -- what `torch.save` writes when a whole MODEL was
        serialized instead of a state dict, and the shape every Ultralytics `.pt` has.

        Built by defining the class in a throwaway module so that `pickle` emits genuine
        NEWOBJ opcodes, then deleting the module again so the fixture is as unimportable
        as a real download. `_global_reduce` above cannot stand in for this: it only ever
        produces GLOBAL/REDUCE, which is exactly why the s29 tests missed that NEWOBJ
        rejects a non-type stub and aborted the whole load."""
        created = []
        parts = module.split(".")
        for i in range(1, len(parts) + 1):
            dotted = ".".join(parts[:i])
            if dotted not in sys.modules:
                sys.modules[dotted] = ModuleType(dotted)
                created.append(dotted)
        try:
            cls = type(name, (), {"__module__": module})
            setattr(sys.modules[module], name, cls)
            obj = cls.__new__(cls)
            obj.__dict__.update(yaml={"nc": 80}, names={0: "person"}, stride=[8, 16, 32])
            raw = pickle.dumps({"model": obj, "epoch": 3}, protocol=2)
        finally:
            for dotted in reversed(created):
                del sys.modules[dotted]
        if not zipped:
            return raw
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:      # torch.save's modern layout
            z.writestr("archive/data.pkl", raw)
            z.writestr("archive/data/0", b"\x00" * 8)
        return buf.getvalue()

    def test_pickle_state_dict_is_classified_by_tensor_keys(self):
        """Both torch layouts: legacy bare pickle and modern zip-with-data.pkl."""
        d = self.fx.root
        legacy = d / "legacy.pth"
        legacy.write_bytes(pickle.dumps({"first_stage_model.decoder.conv.weight": 1}))
        self.assertEqual(ms.classify_pickle(*ms.read_pickle_signals(legacy)), "vae")

        modern = d / "modern.pt"
        with zipfile.ZipFile(modern, "w") as z:
            z.writestr("archive/data.pkl",
                       pickle.dumps({"lora_unet_down_blocks.lora_up": 1}))
        self.assertEqual(ms.classify_pickle(*ms.read_pickle_signals(modern)), "loras")

    def test_pickle_module_signals_and_no_import(self):
        """Object-pickles (Ultralytics et al) carry no tensor keys, so the referenced
        MODULE path is the signal -- and reading it must never import that module."""
        d = self.fx.root
        for mod, name, want in [
            ("ultralytics.nn.tasks", "DetectionModel", "ultralytics/bbox"),
            ("ultralytics.nn.tasks", "SegmentationModel", "ultralytics/segm"),
            ("segment_anything.modeling.sam", "Sam", "sams"),
            ("gfpgan.archs.gfpganv1_clean_arch", "GFPGANv1Clean", "facerestore_models"),
        ]:
            p = d / f"{name}.pt"
            p.write_bytes(self._global_reduce(mod, name))
            self.assertEqual(ms.classify_pickle(*ms.read_pickle_signals(p)), want, name)
        # THE security property: none of the above may be imported.
        for forbidden in ("ultralytics", "segment_anything", "gfpgan"):
            self.assertNotIn(forbidden, sys.modules)

    def test_object_pickle_is_readable_and_votes(self):
        """REGRESSION (s31): object-pickles must survive NEWOBJ.

        `find_class` used to hand back an inert INSTANCE, but NEWOBJ/NEWOBJ_EX require a
        type -- so every real Ultralytics/SAM/GFPGAN `.pt` aborted with `NEWOBJ class
        argument must be a type` and the 20-part embedded pickle measure never voted on
        the very files it was written for. They scored 0.25-0.5 off names alone."""
        d = self.fx.root
        for mod, name, want in [
            ("ultralytics.nn.tasks", "DetectionModel", "ultralytics/bbox"),
            ("ultralytics.nn.tasks", "SegmentationModel", "ultralytics/segm"),
            ("segment_anything.modeling.sam", "Sam", "sams"),
            ("gfpgan.archs.gfpganv1_clean_arch", "GFPGANv1Clean", "facerestore_models"),
        ]:
            for zipped in (True, False):        # modern zip and legacy bare pickle
                blob = self._object_pickle(mod, name, zipped=zipped)
                # guard the fixture: without NEWOBJ this test proves nothing.
                if zipped:
                    inner = zipfile.ZipFile(io.BytesIO(blob)).read("archive/data.pkl")
                else:
                    inner = blob
                self.assertIn("NEWOBJ",
                              {op.name for op, _, _ in pickletools.genops(inner)})
                p = d / f"{name}-{'zip' if zipped else 'bare'}.pt"
                p.write_bytes(blob)
                signals = ms.read_pickle_signals(p)
                self.assertEqual(ms.classify_pickle(*signals), want, p.name)
                # and it must now cast an EMBEDDED vote, not merely classify
                self.assertEqual(ms.rate_pickle(*signals),
                                 (want, ms.EMBEDDED_MAX_RATING), p.name)
        for forbidden in ("ultralytics", "segment_anything", "gfpgan"):
            self.assertNotIn(forbidden, sys.modules)

    def test_bare_attribute_names_are_not_read_as_a_state_dict(self):
        """Object-pickles feed ATTRIBUTE names into the tensor-key classifier. A model
        object with `self.encoder`/`self.decoder` must not be mistaken for a VAE -- only
        dotted keys carry a prefix. Dotted tensor names still do."""
        self.assertIsNone(ms.classify_safetensors_header(
            {"encoder": {}, "decoder": {}, "config": {}}))
        # (heuristics 11: the dotted half of this pair now needs real autoencoder
        # anatomy too, so the fixture carries it -- the property under test is still
        # DOTTED vs BARE, not what the dotted names happen to say.)
        self.assertEqual(ms.classify_safetensors_header(
            {k: {} for k in ldm_vae_keys()}), "vae")

    # ---------------------------------------------- heuristics 14 (s47, real files)
    def test_av_video_dit_is_a_diffusion_model(self):
        """MiniMax-H3 FL2VA: a video/audio patchifier feeding a transformer
        stack. Upstream publishes it under diffusion_models/."""
        hdr = {k: {} for k in (
            "adaln_t_table", "audio_patch_proj.weight", "video_patch_proj.weight",
            "blocks.0.attn.qkv_proj.weight_scale", "final_layer.weight",
            "condition_proj.weight", "rope.freqs", "token_refiner.weight")}
        self.assertEqual(ms.classify_safetensors_header(hdr), "diffusion_models")

    def test_patch_proj_alone_does_not_claim_a_file(self):
        """CONTROL for the rule above: the second half of the test is what
        stops a patchifying VAE landing in diffusion_models."""
        self.assertIsNone(ms.classify_safetensors_header(
            {"video_patch_proj.weight": {}, "something_else.weight": {}}))

    def test_qwen_vl_spelling_of_the_vision_tower(self):
        """`visual.` is the open_clip / Qwen-VL spelling of `vision_model.`.
        With a decoder beside it the file is a text encoder..."""
        self.assertEqual(ms.classify_safetensors_header({k: {} for k in (
            "model.layers.0.self_attn.q_proj.weight_scale",
            "visual.blocks.0.attn.qkv.weight")}), "text_encoders")

    def test_visual_tower_alone_is_clip_vision(self):
        """...and ALONE it is a CLIP-Vision tower, exactly as the
        `vision_model.` spelling already was. This one was unclassified
        before s47 -- an unplanned but correct consequence of listing both
        spellings, and it is asserted so it cannot regress silently."""
        self.assertEqual(ms.classify_safetensors_header({k: {} for k in (
            "visual.transformer.resblocks.0.attn.in_proj_weight",
            "visual.conv1.weight")}), "clip_vision")

    def test_metadata_te_key_declares_a_text_encoder(self):
        hdr = {"model.layers.0.mlp.down_proj.weight_scale": {},
               "__metadata__": {"minimax_h3_te": '{"num_hidden_layers": 50}'}}
        self.assertEqual(ms.classify_safetensors_header(hdr), "text_encoders")

    def test_metadata_te_needs_a_config_blob(self):
        """CONTROL: a key that merely ENDS in those two letters is not a
        declaration. Without the `{` test this rule would fire on a name."""
        hdr = {"some.weight": {},
               "__metadata__": {"trained_on_te": "yes"}}
        self.assertIsNone(ms.classify_safetensors_header(hdr))

    def test_audio_vae_is_not_a_t5(self):
        """`encoder.block.` is a COLLISION, not a T5 fingerprint: MiniMax-H3's
        audio VAE is a DAC/BigVGAN autoencoder whose convolution stack carries
        110 of them. Keys and metadata are the real ones, range-fetched."""
        keys = ["latents_mean", "latents_std", "dec_in_proj.weight",
                "mean_proj.weight", "logs_proj.weight",
                "encoder.block.0.block.0.alpha", "decoder.activation_post.act.alpha"]
        self.assertEqual(ms.classify_safetensors_header({k: {} for k in keys}), "vae")
        # ...and by its own declaration, which is consulted first.
        self.assertEqual(ms.classify_safetensors_header(
            {"encoder.block.0.block.0.alpha": {},
             "__metadata__": {"minimax_h3_audio_vae": '{"sample_rate": 32000}'}}),
            "vae")

    def test_real_t5_still_classifies(self):
        """CONTROL for the rule above -- and the fixtures are now the key
        shapes a real t5xxl has (220 tensors: 97 SelfAttention, 72
        DenseReluDense, 1 relative_attention_bias, shared.)."""
        for extra in ("encoder.block.0.layer.0.SelfAttention.q.weight",
                      "encoder.block.0.layer.1.DenseReluDense.wi_0.weight",
                      "encoder.block.0.layer.0.SelfAttention.relative_attention_bias.weight"):
            self.assertEqual(ms.classify_safetensors_header(
                {extra: {}, "shared.weight": {}}), "text_encoders", extra)

    def test_block_prefix_alone_claims_nothing(self):
        """The collision in its purest form: encoder.block. with none of T5's
        markers and none of the VAE ones must abstain, not guess."""
        self.assertIsNone(ms.classify_safetensors_header(
            {"encoder.block.0.weight": {}, "decoder.block.0.weight": {}}))

    def test_object_pickle_executes_nothing(self):
        """The stub is now a real type, so it is instantiated rather than merely called.
        It must still be inert -- construction, attribute access and state application
        may not reach the payload."""
        marker = self.fx.root / "PWNED"

        class _Evil:
            def __reduce__(self):
                import os as _os
                return (_os.system, (f"touch {marker}",))

        p = self.fx.root / "evil.pt"
        p.write_bytes(pickle.dumps({"model": _Evil()}, protocol=2))
        ms.read_pickle_signals(p)
        self.assertFalse(marker.exists(), "restricted unpickler executed code")

    def test_unreadable_pickle_is_not_fatal(self):
        """A file that is not a pickle raises -- classify() catches it and the file is
        merely unclassified, never a scan failure."""
        p = self.fx.root / "junk.pth"
        p.write_bytes(b"not a pickle at all")
        with self.assertRaises(Exception):
            ms.read_pickle_signals(p)

    # ------------------------- heuristics 10: legacy torch serialization (s32 field)
    def test_legacy_torch_stream_is_read_not_silently_skipped(self):
        """THE BUG: `facenet.pth` (153.7 MB) and `detection_Resnet50_Final.pth`
        (109.5 MB) inspected as `pickle modules (none) / key prefixes (none) / sample
        keys (none)` -- no votes, no error, nothing. They are LEGACY torch containers
        (pre-1.6, not a zip): magic number, protocol version, sys_info and only THEN the
        payload. The reader loaded exactly one pickle, got the magic NUMBER, harvested
        nothing from an int, and reported success. Reading the stream sequentially --
        skipping the preamble, through the same restricted unpickler -- is the fix."""
        d = self.fx.root
        # guard the fixture: object #1 really is the preamble, not the payload
        blob = torch_legacy_bytes({"state_dict": {
            k: storage_ref() for k in ldm_vae_keys()}})
        self.assertEqual(pickle.loads(blob), TORCH_LEGACY_MAGIC)
        self.assertFalse(blob.startswith(b"PK"))

        p = d / "legacy-state-dict.pth"
        p.write_bytes(blob)
        keys, modules = ms.read_pickle_signals(p)
        # the payload's keys are harvested, the sys_info preamble's keys are NOT
        self.assertIn("encoder.conv_in.weight", keys)
        self.assertIn("state_dict", keys)
        for preamble_key in ("protocol_version", "little_endian", "type_sizes"):
            self.assertNotIn(preamble_key, keys)
        self.assertEqual(ms.classify_pickle(keys, modules), "vae")

        # ...and the module path of an object-pickle payload survives the same journey,
        # without importing anything: preamble, then an unimportable class.
        q = d / "legacy-object.pth"
        q.write_bytes(torch_legacy_bytes(None, trailer=False)
                      + self._global_reduce("segment_anything.modeling.sam", "Sam"))
        keys, modules = ms.read_pickle_signals(q)
        self.assertIn("segment_anything.modeling.sam.sam", modules)
        self.assertEqual(ms.classify_pickle(keys, modules), "sams")
        self.assertNotIn("segment_anything", sys.modules)

    def test_legacy_stream_end_to_end_classifies_and_votes(self):
        self.fx.add_local_file("mystery/legacy-vae.pth", torch_legacy_bytes(
            {"first_stage_model.decoder.conv_in.weight": storage_ref()}))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), {"vae/legacy-vae.pth"})
        entry = next(iter(self.fx.load_registry()["entries"].values()))
        self.assertEqual(entry["category"], "vae")
        self.assertTrue(any(s.startswith("pickle=vae@") for s in entry["signals"]),
                        entry["signals"])
        # What this line has always meant is "the READER did not complain". Narrowed in
        # s43 because the fixture -- `first_stage_model.` and nothing else -- is itself an
        # instance of the checkpoint-packaged VAE, so it now draws that warn legitimately.
        self.assertNotIn("unreadable", out)

    def test_a_read_that_yields_nothing_is_reported_not_hidden(self):
        """`(none)` on a 150 MB file is the failure mode. Whatever the reason -- a
        truncated legacy stream, a zip with a data.pkl that holds nothing -- the reason
        itself must reach `inspect`, and the file must still cast no vote and not crash
        the scan."""
        # (a) legacy container with the preamble and no payload at all
        truncated = torch_legacy_bytes(None)
        with self.assertRaises(ValueError) as cm:
            p = self.fx.root / "truncated.pth"
            p.write_bytes(truncated)
            ms.read_pickle_signals(p)
        self.assertIn("empty:", str(cm.exception))
        self.assertIn("legacy", str(cm.exception))
        # (b) the zip path is held to the same rule
        z = self.fx.root / "hollow.pt"
        with zipfile.ZipFile(z, "w") as zf:
            zf.writestr("archive/data.pkl", pickle.dumps(1234))
        with self.assertRaises(ValueError) as cm:
            ms.read_pickle_signals(z)
        self.assertIn("empty:", str(cm.exception))

        # end to end: it surfaces in inspect, casts no vote, and the sync survives it
        self.fx.add_local_file("signal_free.pth", truncated)
        rc, out = self.fx.inspect("signal_free")
        self.assertEqual(rc, 0)
        self.assertRegex(out, r"pickle read\s+FAILED: empty:")
        self.assertNotIn("(none)", out)          # never a silent blank
        self.assertIn("file magic", out)         # what the container actually holds
        self.assertIn("(none -- no measure could form a judgement)", out)
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), set())
        self.assertIn("UNCLASSIFIED  signal_free.pth", out)

    # ------------------- heuristics 10: AnimateDiff motion LORAS vs motion MODULES
    def test_animatediff_motion_lora_is_its_own_category(self):
        """8 real `AnimateDiff-Motion-LoRAs_*.ckpt` filed as `animatediff_models`: the
        motion-module rule fires on `.motion_modules.` and the plain lora rule cannot
        help (these spell it `.to_k_lora.down.`, never `.lora_down`). AnimateDiff-Evolved
        registers `animatediff_motion_lora` as a SEPARATE folder and a separate loader
        node, so a motion LoRA in the motion-module dir is invisible to the only thing
        that loads it."""
        self.assertIn("animatediff_motion_lora", ms.CATEGORIES)
        self.assertEqual(ms.SEGMENT_MAP["animatediff_motion_lora"],
                         "animatediff_motion_lora")
        lora_hdr = {k: {} for k in motion_lora_keys()}
        self.assertEqual(ms.classify_safetensors_header(lora_hdr),
                         "animatediff_motion_lora")
        # each processor spelling on its own is enough
        for proj in ("to_q", "to_k", "to_v", "to_out"):
            k = ("down_blocks.0.motion_modules.0.temporal_transformer"
                 f".transformer_blocks.0.attention_blocks.0.processor.{proj}_lora"
                 ".down.weight")
            self.assertEqual(ms.classify_safetensors_header({k: {}}),
                             "animatediff_motion_lora", proj)
        # THE case that must NOT move: motion modules carry no processor keys
        self.assertEqual(
            ms.classify_safetensors_header({k: {} for k in motion_module_keys()}),
            "animatediff_models")

    def test_motion_modules_signal_requires_unet_block_context(self):
        """A second field counterexample: Metric-Video-Depth-Anything-Large calls its
        temporal head `head.motion_modules.0.temporal_transformer.*` (prefixes: head,
        pretrained) and was filed `animatediff_models`@0.4 off the bare substring. Real
        AnimateDiff weights hang off a UNet's down_blocks/mid_block/up_blocks; a depth
        model's head cannot. With the block context required, the file carries no content
        signal at all and its NAME correctly makes it an annotator."""
        depth = {k: {} for k in (
            "head.motion_modules.0.temporal_transformer.norm.bias",
            "head.motion_modules.1.temporal_transformer.proj_in.weight",
            "pretrained.blocks.0.attn.qkv.weight")}
        self.assertIsNone(ms.classify_safetensors_header(depth))
        self.assertIsNone(ms.rate_safetensors(depth))
        # end to end: the pickle carries the same keys, and naming settles it
        self.fx.add_local_file(
            "metric_video_depth_anything_vitl.pth",
            torch_legacy_bytes({k: storage_ref() for k in depth}))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree),
                         {"controlnet_aux/metric_video_depth_anything_vitl.pth"})
        entry = next(iter(self.fx.load_registry()["entries"].values()))
        self.assertEqual(entry["category"], "controlnet_aux")
        self.assertFalse([s for s in entry["signals"] if s.startswith("pickle=")],
                         entry["signals"])

    def test_dit_controlnet_outranks_the_bare_dit_rule(self):
        """InstantX/Qwen-Image-ControlNet-Inpainting is a ControlNet built ON a DiT, so
        it has every bare-DiT prefix (img_in./txt_in./transformer_blocks.) that scores
        diffusion_models@0.99 -- plus the controlnet trunk that overrides them. The
        zero-conv rule already sat above the DiT rules; it just did not know the DiT-era
        spelling (controlnet_blocks. / controlnet_x_embedder.)."""
        dit_controlnet = {k: {} for k in (
            "controlnet_blocks.0.weight", "controlnet_x_embedder.weight",
            "img_in.weight", "txt_in.weight", "txt_norm.weight",
            "time_text_embed.timestep_embedder.linear_1.weight",
            "transformer_blocks.0.attn.to_q.weight")}
        self.assertEqual(ms.classify_safetensors_header(dit_controlnet), "controlnet")
        self.assertEqual(ms.rate_safetensors(dit_controlnet),
                         ("controlnet", ms.EMBEDDED_MAX_RATING))
        # the trunk alone names the model outright, so it rates as a DISTINCTIVE prefix
        # in its own right (not merely on the transformer_blocks. it shares with a DiT)
        self.assertEqual(
            ms.rate_safetensors({"controlnet_blocks.0.weight": {},
                                 "controlnet_x_embedder.weight": {}}),
            ("controlnet", ms.EMBEDDED_MAX_RATING))
        # REGRESSION GUARD: a pure DiT (Qwen-Image-Edit shape) stays diffusion_models
        pure_dit = {k: {} for k in (
            "img_in.weight", "txt_in.weight", "txt_norm.weight",
            "transformer_blocks.0.attn.to_q.weight")}
        self.assertEqual(ms.classify_safetensors_header(pure_dit), "diffusion_models")
        # end to end, with the generic component filename the repo actually ships
        self.fx.add_hf_file("InstantX/Qwen-Image-ControlNet-Inpainting",
                            "diffusion_pytorch_model.safetensors",
                            safetensors_bytes(list(dit_controlnet)))
        self.fx.add_hf_file("Comfy-Org/Qwen-Image-Edit-2511_FP8",
                            "qwen-image-edit-2511-fp8.safetensors",
                            safetensors_bytes(list(pure_dit)))
        rc, out = self.fx.sync()
        self.assertEqual(tree_links(self.fx.tree), {
            "controlnet/Qwen-Image-ControlNet-Inpainting--diffusion_pytorch_model"
            ".safetensors",
            "diffusion_models/qwen-image-edit-2511-fp8.safetensors"})

    def test_motion_lora_split_reaches_both_readers(self):
        """The discriminator lives in the SHARED key classifier, so the pickle path
        (the 8 `.ckpt` bundles) and the safetensors path (`aidma-RUN-Motion Lora`) both
        get it -- and both land in the tree under the right folder."""
        # pickle side: the .ckpt shape, keys nested under state_dict beside epoch/global_step
        ckpt = torch_legacy_bytes({
            "epoch": 0, "global_step": 1,
            "state_dict": {k: storage_ref() for k in motion_lora_keys()}})
        names = [f"AnimateDiff-Motion-LoRAs_v2_lora_{m}.ckpt" for m in
                 ("PanLeft", "PanRight", "RollingAnticlockwise", "RollingClockwise",
                  "TiltDown", "TiltUp", "ZoomIn", "ZoomOut")]
        for n in names:
            self.fx.add_local_file(n, ckpt + n.encode())   # distinct identities
        # ...and the motion MODULE bundle in the same drop, which must stay put
        self.fx.add_local_file("AnimateDiff-Motion-Modules_v1.5-v2.ckpt",
                               torch_legacy_bytes({"state_dict": {
                                   k: storage_ref() for k in motion_module_keys()}}))
        # safetensors side. The field file carries `model_type=motion_director, rank=64`
        # in __metadata__; it is here to prove the KEY rule suffices without it (nothing
        # reads model_type -- only modelspec.architecture is consulted).
        self.fx.add_local_file("aidma-RUN-Motion Lora.safetensors",
                               safetensors_bytes(motion_lora_keys(),
                                                 {"model_type": "motion_director",
                                                  "rank": "64"}))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree),
                         {f"animatediff_motion_lora/{n}" for n in names}
                         | {"animatediff_motion_lora/aidma-RUN-Motion Lora.safetensors",
                            "animatediff_models/AnimateDiff-Motion-Modules_v1.5-v2.ckpt"})
        entries = {e["display"]: e
                   for e in self.fx.load_registry()["entries"].values()}
        cats = {d: e["category"] for d, e in entries.items()}
        self.assertEqual(cats["AnimateDiff-Motion-Modules_v1.5-v2.ckpt"],
                         "animatediff_models")
        for n in names:
            self.assertEqual(cats[n], "animatediff_motion_lora", n)
        self.assertNotIn("UNCLASSIFIED", out)
        # heuristics 12: the shape is CONCLUSIVE, so both readers rate at the top tier --
        # the pickle side one step down, as every key-derived pickle rating is. Under 11
        # these were the generic 0.6 and scored 0.48 / 0.6.
        self.assertIn("pickle=animatediff_motion_lora@0.95", entries[names[0]]["signals"])
        self.assertIn("pickle=animatediff_models@0.95",
                      entries["AnimateDiff-Motion-Modules_v1.5-v2.ckpt"]["signals"])
        self.assertIn("safetensors=animatediff_motion_lora@0.99",
                      entries["aidma-RUN-Motion Lora.safetensors"]["signals"])
        self.assertEqual(entries[names[0]]["confidence"], 0.76)
        self.assertEqual(entries["aidma-RUN-Motion Lora.safetensors"]["confidence"], 0.849)
        # ...and the disagreement with the NAME (both read `lora`) is untouched by the
        # lift: raising content's confidence must not silence the naming measures.
        for n in names + ["aidma-RUN-Motion Lora.safetensors"]:
            self.assertEqual(entries[n]["disputed"], "ladder=loras", n)
            self.assertIn("filename=loras@0.3", entries[n]["signals"])

    # ------------------- heuristics 10: a vision tower is not always a vision model
    def test_multimodal_llm_vision_tower_is_a_text_encoder_not_clip_vision(self):
        """A confident FALSE POSITIVE: gemma-3-12b NVFP4 (12.1 GB, 1864 tensors) shipped
        as an LTX-2 text encoder scored clip_vision@0.99 because `vision_model.` was
        present. The decoder beside it (model.layers. / multi_modal_projector) is what
        says the vision tower is a COMPONENT, not the model (Jei's verdict, s30)."""
        gemma = {k: {} for k in (
            "model.layers.10.mlp.down_proj.weight_scale_2",
            "model.layers.0.self_attn.q_proj.weight",
            "multi_modal_projector.mm_input_projection_weight",
            "vision_model.vision_model.encoder.layers.0.mlp.fc1.weight")}
        self.assertEqual(ms.classify_safetensors_header(gemma), "text_encoders")
        # high confidence, not a hedge: `vision_model.` is still a distinctive prefix
        self.assertEqual(ms.rate_safetensors(gemma),
                         ("text_encoders", ms.EMBEDDED_MAX_RATING))
        # each decoder spelling on its own is enough
        for decoder in ("model.layers.0.mlp.up_proj.weight",
                        "language_model.layers.0.mlp.up_proj.weight",
                        "multi_modal_projector.linear.weight"):
            self.assertEqual(ms.classify_safetensors_header(
                {"vision_model.encoder.layers.0.mlp.fc1.weight": {}, decoder: {}}),
                "text_encoders", decoder)
        # REGRESSION GUARD: the two real IP-Adapter image encoders are vision-ONLY and
        # must stay clip_vision at 0.99 -- this rule may only fire on co-occurrence.
        for ip_adapter in (
            {"vision_model.encoder.layers.0.mlp.fc1.weight": {},
             "vision_model.post_layernorm.weight": {},
             "visual_projection.weight": {}},
            {"vision_model.embeddings.patch_embedding.weight": {}},
        ):
            self.assertEqual(ms.classify_safetensors_header(ip_adapter), "clip_vision")
            self.assertEqual(ms.rate_safetensors(ip_adapter),
                             ("clip_vision", ms.EMBEDDED_MAX_RATING))
        # a pure LLM (no vision tower) is untouched by this rule: config.json still
        # decides, so sharded LLM repos keep classifying `llm`.
        self.assertIsNone(ms.classify_safetensors_header(
            {"model.layers.0.mlp.up_proj.weight": {}}))

    def test_multimodal_text_encoder_end_to_end(self):
        self.fx.add_hf_file("Lightricks/LTX-2", "text_encoder/gemma-3-12b-nvfp4.safetensors",
                            safetensors_bytes([
                                "model.layers.10.mlp.down_proj.weight_scale_2",
                                "multi_modal_projector.mm_input_projection_weight",
                                "vision_model.encoder.layers.0.mlp.fc1.weight"]))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(
            tree_links(self.fx.tree),
            {"text_encoders/gemma-3-12b-nvfp4.safetensors"})
        entry = next(iter(self.fx.load_registry()["entries"].values()))
        self.assertEqual(entry["category"], "text_encoders")
        self.assertTrue(any(s == "safetensors=text_encoders@0.99"
                            for s in entry["signals"]), entry["signals"])

    # ------------- heuristics 11: an encoder+decoder pair is a SHAPE, not an identity
    def test_vae_vote_requires_real_autoencoder_anatomy(self):
        """A fresh field FALSE POSITIVE: parsing_parsenet.pth (ParseNet, a face-PARSING
        /segmentation net, 85.3 MB) has key prefixes `body, decoder, encoder,
        out_img_conv, out_mask_conv` and won vae@0.6 x 20 parts against its own correct
        filename (facedetection, LoFi-capped at 0.3 x 5). Plenty of models have an encoder
        and a decoder; only an autoencoder has an autoencoder's INSIDES."""
        parsenet = {k: {} for k in parsenet_keys()}
        self.assertIsNone(ms.classify_safetensors_header(parsenet))
        # ABSTAIN means no vote at all -- not a vote for some other category.
        self.assertIsNone(ms.rate_safetensors(parsenet))
        # ...and both real VAE spellings still pass, at the generic content rating.
        for shape in (ldm_vae_keys(), diffusers_vae_keys()):
            hdr = {k: {} for k in shape}
            self.assertEqual(ms.classify_safetensors_header(hdr), "vae", shape[1])
            self.assertEqual(ms.rate_safetensors(hdr), ("vae", 0.6), shape[1])
        # each anatomy marker is sufficient ON ITS OWN, in either spelling
        for anatomy in ("encoder.down.0.block.0.conv1.weight",
                        "decoder.up.3.block.0.conv1.weight",
                        "encoder.down_blocks.0.resnets.0.conv1.weight",
                        "decoder.up_blocks.0.resnets.0.conv1.weight",
                        "quant_conv.weight", "post_quant_conv.weight"):
            self.assertEqual(ms.classify_safetensors_header(
                {"encoder.conv_in.weight": {}, "decoder.conv_out.weight": {},
                 anatomy: {}}), "vae", anatomy)
        # the explicit ldm bundle prefix never needed the pair and is untouched
        self.assertEqual(ms.classify_safetensors_header(
            {"first_stage_model.decoder.conv_in.weight": {}}), "vae")

    def test_parsenet_shape_classifies_by_naming_not_content(self):
        """End to end, as the file ships: a legacy torch pickle carrying ParseNet's keys
        under the facexlib name. Content abstains, so naming -- which is right here --
        decides, and NO pickle vote is on the record."""
        self.fx.add_hf_file("xinntao/facexlib", "parsing_parsenet.pth",
                            torch_legacy_bytes({k: storage_ref()
                                                for k in parsenet_keys()}))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree),
                         {"facedetection/parsing_parsenet.pth"})
        entry = next(iter(self.fx.load_registry()["entries"].values()))
        self.assertEqual(entry["category"], "facedetection")
        self.assertFalse([s for s in entry["signals"] if s.startswith("pickle=")],
                         entry["signals"])

    def test_autoencoderkl_inside_a_lightning_checkpoint_is_a_vae(self):
        """The other side of the same rule (AlexSmileface_mixG.v1.pt): a pytorch-lightning
        bundle whose junk keys sit beside a real AutoencoderKL. The anatomy is there, the
        name says nothing at all, so content must carry it -- tightening the vae rule may
        not cost a genuine VAE its classification."""
        self.fx.add_local_file("AlexSmileface_mixG.v1.pt", torch_legacy_bytes({
            "epoch": 0, "global_step": 1, "pytorch-lightning_version": "1.4.2",
            "state_dict": {k: storage_ref() for k in diffusers_vae_keys()}}))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), {"vae/AlexSmileface_mixG.v1.pt"})
        entry = next(iter(self.fx.load_registry()["entries"].values()))
        self.assertEqual(entry["category"], "vae")
        self.assertTrue(any(s.startswith("pickle=vae@") for s in entry["signals"]),
                        entry["signals"])

    # --------------- heuristics 11: the DataParallel `module.` wrapper is PACKAGING
    def test_dataparallel_module_prefix_is_stripped_before_every_rule(self):
        """torch.nn.DataParallel welds `module.` onto every key, and a checkpoint saved
        off one keeps it forever (detection_Resnet50_Final.pth: prefixes `_metadata,
        module`). It says nothing about what the model IS, and it blinds every prefix rule
        at once -- so it is normalized away ONCE, in the shared classifier."""
        self.assertEqual(
            ms.strip_dataparallel(["module.body.conv1.weight", "_metadata", "module"]),
            ["body.conv1.weight", "_metadata", "module"])
        # REGRESSION GUARD: wrapped keys must classify AND rate identically to unwrapped.
        for shape, want in (
            (["model.diffusion_model.input_blocks.0.0.weight",
              "first_stage_model.decoder.conv_in.weight"], "checkpoints"),
            (ldm_vae_keys(), "vae"),
            (["lora_unet_down_blocks.lora_down.weight"], "loras"),
            (["control_model.zero_convs.0.weight"], "controlnet"),
        ):
            plain = {k: {} for k in shape}
            wrapped = {"module." + k: {} for k in shape}
            self.assertEqual(ms.classify_safetensors_header(wrapped), want, shape[0])
            self.assertEqual(ms.classify_safetensors_header(plain),
                             ms.classify_safetensors_header(wrapped), shape[0])
            self.assertEqual(ms.rate_safetensors(plain),
                             ms.rate_safetensors(wrapped), shape[0])

    # ------------------- heuristics 11: RetinaFace / facexlib heads -> facedetection
    def test_retinaface_heads_are_facedetection(self):
        """detection_Resnet50_Final.pth inspects as prefixes `_metadata, module` with
        sample keys like `module.BboxHead.0.conv1x1...`. Once the DataParallel wrapper is
        off, the three heads together ARE the RetinaFace signature."""
        for head in ms.RETINAFACE_HEAD_PREFIXES:
            self.assertEqual(ms.classify_safetensors_header(
                {"body.conv1.weight": {}, head + "0.conv1x1.weight": {}}),
                "facedetection", head)
        wrapped = {"module." + k: {} for k in (
            "body.conv1.weight", "fpn.output1.0.weight",
            "ClassHead.0.conv1x1.weight", "BboxHead.0.conv1x1.weight",
            "LandmarkHead.0.conv1x1.weight")}
        self.assertEqual(ms.classify_safetensors_header(wrapped), "facedetection")
        self.assertEqual(ms.rate_safetensors(wrapped),
                         ("facedetection", ms.EMBEDDED_MAX_RATING))
        # end to end through the pickle path, which is the one that matters: .pth files
        self.fx.add_hf_file("xinntao/facexlib", "detection_Resnet50_Final.pth",
                            torch_legacy_bytes(retinaface_state_dict()))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree),
                         {"facedetection/detection_Resnet50_Final.pth"})
        entry = next(iter(self.fx.load_registry()["entries"].values()))
        self.assertEqual(entry["category"], "facedetection")
        self.assertTrue(any(s.startswith("pickle=facedetection@")
                            for s in entry["signals"]), entry["signals"])
        # COSMETIC: the `_metadata` root entry is keyed on "", which rendered as a
        # phantom leading item (", _metadata, module"). Gone from the DISPLAY -- while
        # the RAW keys, wrapper and all, are still exactly what is printed.
        rc, ins = self.fx.inspect("detection_Resnet50")
        self.assertEqual(rc, 0)
        self.assertRegex(ins, r"pickle key prefixes\s+_metadata, module")
        self.assertNotRegex(ins, r"pickle key prefixes\s+,")
        # heuristics 12: the SAMPLE row had the same phantom -- the empty key sorts
        # first, so it led every sample list too. Same filter, same display-only scope.
        self.assertRegex(ins, r"pickle sample keys\s+_metadata, module,")
        self.assertNotRegex(ins, r"pickle sample keys\s+,")
        self.assertIn("module.BboxHead.0.conv1x1.weight", ins)

    # ------------------- heuristics 11: CPM / OpenPose stage convs -> controlnet_aux
    def test_cpm_stage_convs_are_controlnet_aux(self):
        """`facenet.pth` (153.7 MB) is a Convolutional Pose Machine LANDMARK model, not a
        face-recognition net: prefixes `Mconv1_stage2 ... Mconv7_stage6`, keys like
        `Mconv1_stage2.bias`. Its name is actively misleading, so only content can place
        it -- and the openpose annotators already routed here by NAME (body_pose_model /
        hand_pose_model) are the same family, spelled `model1_1.0.weight`."""
        # the placement is ONE constant, so confirming or flipping it is one line
        self.assertEqual(ms.POSE_STAGE_CATEGORY, "controlnet_aux")
        for key in ("Mconv1_stage2.bias", "Mconv7_stage6.weight",
                    "model1_1.0.weight", "model6_2.12.bias"):
            hdr = {key: {}, "conv1_1.weight": {}}
            self.assertEqual(ms.classify_safetensors_header(hdr),
                             ms.POSE_STAGE_CATEGORY, key)
            self.assertEqual(ms.rate_safetensors(hdr),
                             (ms.POSE_STAGE_CATEGORY, ms.EMBEDDED_MAX_RATING), key)
        # anchored at the key root and requiring the stage digits, so an ordinary
        # `model.`/`model0.` prefix or a mid-key occurrence cannot be swept in
        for miss in ("model0.0.weight", "model.diffusion_model.input_blocks.0.0.weight",
                     "backbone.model1_1.0.weight", "Mconv_stage.weight"):
            self.assertIsNone(ms.POSE_STAGE_KEY_RE.match(miss), miss)
        self.assertEqual(ms.classify_safetensors_header(
            {"model.diffusion_model.x": {}, "first_stage_model.y": {}}), "checkpoints")
        # end to end, under the misleading name
        self.fx.add_local_file("facenet.pth", torch_legacy_bytes(cpm_state_dict()))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), {"controlnet_aux/facenet.pth"})
        entry = next(iter(self.fx.load_registry()["entries"].values()))
        self.assertEqual(entry["category"], "controlnet_aux")
        self.assertTrue(any(s.startswith("pickle=controlnet_aux@")
                            for s in entry["signals"]), entry["signals"])

    # ------------- heuristics 12: the causal-video autoencoder spells its anatomy
    def test_wan_causal_video_vae_anatomy_votes_vae(self):
        """Field dump of the real wan_2.1_vae.safetensors (Jei, s33): top-level prefixes
        `conv1, conv2, decoder, encoder`, keys like `decoder.upsamples.0.residual.0.gamma`
        -- and NO quant_conv / post_quant_conv anywhere. Under heuristics 11 that file had
        an encoder/decoder pair and NOTHING the anatomy rule recognised, so it abstained
        and fell to naming. `upsamples`/`downsamples` is the third spelling that ships."""
        wan = {k: {} for k in wan_vae_keys()}
        # the premise of the case: no quantisation convs to fall back on
        self.assertFalse([k for k in wan if "quant_conv." in k])
        self.assertEqual({k.split(".")[0] for k in wan},
                         {"conv1", "conv2", "decoder", "encoder"})
        self.assertEqual(ms.classify_safetensors_header(wan), "vae")
        self.assertEqual(ms.rate_safetensors(wan), ("vae", 0.6))
        # each spelling is sufficient on its own. The decoder half is PROVEN from the
        # dump; the encoder half is the symmetric inference, asserted so a later field
        # dump that contradicts it fails here rather than silently drifting.
        for anatomy, proven in (("decoder.upsamples.0.residual.0.gamma", True),
                                ("encoder.downsamples.0.residual.0.gamma", False)):
            self.assertEqual(ms.classify_safetensors_header(
                {"encoder.conv1.weight": {}, "decoder.conv2.weight": {},
                 anatomy: {}}), "vae", anatomy)
        # REGRESSION GUARD: widening the anatomy must not revive the false positive the
        # rule was built for. ParseNet has neither spelling and still abstains outright.
        parsenet = {k: {} for k in parsenet_keys()}
        self.assertIsNone(ms.classify_safetensors_header(parsenet))
        self.assertIsNone(ms.rate_safetensors(parsenet))
        # ...nor may it disturb the two spellings that already worked.
        for shape in (ldm_vae_keys(), diffusers_vae_keys()):
            self.assertEqual(ms.rate_safetensors({k: {} for k in shape}),
                             ("vae", 0.6), shape[1])
        # end to end, under a name that says nothing: content has to carry it
        self.fx.add_local_file("wan_2.1_vae.safetensors",
                               safetensors_bytes(wan_vae_keys()))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), {"vae/wan_2.1_vae.safetensors"})

    # ------------- heuristics 12: the AnimateDiff temporal stack is CONCLUSIVE evidence
    def test_animatediff_shape_rates_at_the_distinctive_tier(self):
        """The 8 motion-LoRA .ckpt bundles and `aidma-RUN-Motion Lora.safetensors` were
        classified right but rated at the GENERIC 0.6 encoder-shape tier, scoring 0.4-0.45
        -- reading as guesses when the shape is conclusive. A temporal_transformer hanging
        off a UNet block names AnimateDiff as squarely as `control_model.` names a
        ControlNet, so it rates with the distinctive prefixes."""
        for keys, want in ((motion_lora_keys(), "animatediff_motion_lora"),
                           (motion_module_keys(), "animatediff_models")):
            hdr = {k: {} for k in keys}
            self.assertEqual(ms.rate_safetensors(hdr),
                             (want, ms.EMBEDDED_MAX_RATING), want)
            # the pickle rater derives from the same helper, so the .ckpt side is lifted
            # by the same change -- one step down, as any key-derived pickle rating is
            self.assertEqual(ms.rate_pickle(set(keys), set()), (want, 0.95), want)
        # ...and the lift is the COMPOSITE, never the block roots. Those are the generic
        # UNet skeleton -- half the collection has them -- so they must stay OUT of the
        # conclusive-signature list and must not rate above the generic tier on their
        # own. (That list was ms.DISTINCTIVE_PREFIXES until s46; it is now shared, as
        # model_formats.CONCLUSIVE_PREFIXES. Same assertion, new home.)
        import model_formats
        for root in ("down_blocks.", "mid_block.", "up_blocks."):
            self.assertNotIn(root, model_formats.CONCLUSIVE_PREFIXES)
        plain_unet = {"down_blocks.0.resnets.0.conv1.weight": {},
                      "mid_block.attentions.0.proj_in.weight": {},
                      "up_blocks.1.resnets.0.conv2.weight": {}}
        self.assertIsNone(ms.rate_safetensors(plain_unet))
        # the depth model that borrowed the substring is still not AnimateDiff, and so is
        # still not lifted: its temporal head hangs off `head.`, not off a UNet block
        depth = {"pretrained.blocks.0.attn.qkv.weight": {},
                 "head.motion_modules.0.temporal_transformer.norm.bias": {}}
        self.assertIsNone(ms.rate_safetensors(depth))

    # ------------------------------------------------- s29 confidence model (Jei's)
    def test_lofi_cannot_outvote_embedded_evidence(self):
        """The misclassification shape: every NAME says one thing, the file says another.
        Names are correlated -- a mislabelled file usually has a matching bad path and
        repo too -- so unanimity among them is worth about as much as one of them.

        STEP 2: the DATA now wins. This is the synthetic twin of the real field case
        `..._Niji-Muted-Color-Real+VAE.safetensors`, whose name said vae while its tensors
        said checkpoint. Before Step 2 the ladder's naming answer was recorded and the
        disagreement was merely annotated; now the score decides and the naming answer is
        what gets reported as disputed."""
        self.fx.add_hf_file("acme/lora-collection", "loras/super-lora-v2.safetensors",
                            safetensors_bytes(["first_stage_model.decoder.w"]))
        self.fx.sync()
        reg = self.fx.load_registry()
        entry = next(e for e in reg["entries"].values()
                     if e["display"].endswith("super-lora-v2.safetensors"))
        # The file's own contents decide, against a unanimous path+filename+repo.
        self.assertEqual(entry["category"], "vae")
        # The naming disagreement stays ON THE RECORD -- content decides, it does not
        # silence. This report is the only way a confident-but-wrong embedded reading
        # (a multimodal LLM's vision tower reading as clip_vision) stays findable.
        self.assertEqual(entry["disputed"], "ladder=loras")
        # 30x0.99 / (30 + 5 + 5 + 5) == 0.66: content carries the score outright.
        self.assertGreater(entry["confidence"], 0.6)
        self.assertTrue(any(s.startswith("safetensors=vae@0.99") for s in entry["signals"]))
        # ...and every LoFi measure is still RECORDED, just not trusted ("keeping the
        # information is good; trusting it? less so"), each capped at LOFI_MAX_RATING.
        lofi = [s for s in entry["signals"] if s.startswith(("segments=", "filename=",
                                                            "repo="))]
        self.assertEqual(len(lofi), 3)
        self.assertTrue(all(s.endswith(f"@{ms.LOFI_MAX_RATING}") for s in lofi), lofi)

    def test_lofi_unanimity_loses_to_one_generic_content_read(self):
        """The arithmetic behind LOFI_MAX_RATING. All six LoFi measures agreeing is the
        worst realistic case for the naming tier; it must still lose to a single GENERIC
        (0.6) content read -- the weakest thing an embedded measure can say. At the old
        0.6 cap this was an exact tie (30x0.6 == 30x0.6); the field data made the choice."""
        votes = [{"measure": m, "category": "loras", "rating": ms.LOFI_MAX_RATING,
                  "parts": ms.MEASURE_PARTS[m]} for m in sorted(ms.LOFI_MEASURES)]
        votes.append({"measure": "safetensors", "category": "vae", "rating": 0.6,
                      "parts": ms.MEASURE_PARTS["safetensors"]})
        winner, conf, scores = ms.score_votes(votes)
        self.assertEqual(winner, "vae")
        self.assertGreater(scores["vae"], scores["loras"] * 1.9)

    def test_inspect_shows_evidence_including_for_unidentifiable_files(self):
        """Automatic identification has a floor. When the scanner cannot name a file,
        `inspect` must still print the material it observed, so a human can decide and
        the decision can then be encoded as a rule."""
        self.fx.add_local_file("Stable-diffusion/merge_Real+VAE.safetensors",
                               safetensors_bytes([
                                   "model.diffusion_model.input_blocks.0.0.weight",
                                   "first_stage_model.decoder.conv_in.weight"]))
        self.fx.add_local_file("Stable-diffusion/mystery.safetensors",
                               safetensors_bytes(["foo.bar.weight"]))
        rc, out = self.fx.inspect()
        self.assertEqual(rc, 0)
        # The classified file shows the winning measure AND what naming wanted instead.
        self.assertIn("naming ladder said: vae", out)
        self.assertRegex(out, r"safetensors\s+-> checkpoints")
        # Raw material is printed, not just the conclusion.
        self.assertIn("first_stage_model", out)
        # The unidentifiable file is the point: no votes, but evidence regardless.
        self.assertIn("(none -- no measure could form a judgement)", out)
        self.assertIn("foo", out)
        # Filtering narrows to the gaps.
        rc, only = self.fx.inspect("-u")
        self.assertEqual(rc, 0)
        self.assertIn("mystery.safetensors", only)
        self.assertNotIn("merge_Real+VAE", only)

    def test_inspect_is_read_only(self):
        """It is a diagnostic: it must never create a registry or touch the tree."""
        self.fx.add_local_file("loras/x.safetensors", safetensors_bytes(["lora_unet_a"]))
        rc, _ = self.fx.inspect()
        self.assertEqual(rc, 0)
        self.assertFalse(self.fx.registry.exists(), "inspect wrote a registry")
        self.assertFalse(any(self.fx.tree.rglob("*")) if self.fx.tree.is_dir() else False,
                         "inspect touched the link tree")

    def test_score_is_per_category_not_pooled(self):
        votes = [
            {"measure": "safetensors", "category": "vae", "rating": 0.99, "parts": 30},
            {"measure": "filename", "category": "loras", "rating": 0.5, "parts": 5},
            {"measure": "repo", "category": "loras", "rating": 0.4, "parts": 5},
        ]
        winner, conf, scores = ms.score_votes(votes)
        self.assertEqual(winner, "vae")
        # denominator is ALL applicable parts (40), so disagreement depresses the winner
        self.assertAlmostEqual(scores["vae"], round(30 * 0.99 / 40, 3))
        self.assertAlmostEqual(scores["loras"], round((5 * 0.5 + 5 * 0.4) / 40, 3))
        self.assertLess(conf, 0.99)

    def test_lofi_rating_is_capped(self):
        """No LoFi measure may express certainty, however emphatic the name."""
        src = SimpleNamespace(
            display="acme/vae-stuff/vae-model.safetensors",
            link_name="vae-model.safetensors", origin="hf",
            rel_dir_parts=("vae",), component=None,
            path=Path("/nonexistent"), config_dir=Path("/nonexistent"), sharded=False)
        for v in ms.gather_votes(src):
            self.assertLessEqual(v["rating"], ms.LOFI_MAX_RATING, v["measure"])

    def test_agreement_beats_a_lone_signal(self):
        """Content plus names agreeing scores higher than content alone -- the whole
        point of running every measure."""
        agree = ms.score_votes([
            {"measure": "safetensors", "category": "vae", "rating": 0.99, "parts": 30},
            {"measure": "filename", "category": "vae", "rating": 0.5, "parts": 5}])[1]
        alone = ms.score_votes([
            {"measure": "safetensors", "category": "vae", "rating": 0.99, "parts": 30},
            {"measure": "filename", "category": "loras", "rating": 0.5, "parts": 5}])[1]
        self.assertGreater(agree, alone)

    # ------------------------------------------------------------- never-clobber
    def test_never_clobber_user_file(self):
        populate_standard(self.fx)
        user = self.fx.tree / "loras" / "pixel-style-lora.safetensors"
        user.parent.mkdir(parents=True)
        user.write_bytes(b"user data - do not touch")
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertFalse(user.is_symlink())
        self.assertEqual(user.read_bytes(), b"user data - do not touch")
        self.assertIn("CONFLICT", out)
        # the conflicted path must NOT be claimed in the registry
        reg = self.fx.load_registry()
        owned = {l for e in reg["entries"].values() for l in e["links"]}
        self.assertNotIn("loras/pixel-style-lora.safetensors", owned)
        # and stays untouched on a repeat run
        rc, out = self.fx.sync()
        self.assertEqual(user.read_bytes(), b"user data - do not touch")
        self.assertIn("CONFLICT", out)

    def test_user_dropins_and_unowned_broken_links_survive_prune(self):
        populate_standard(self.fx)
        self.fx.sync()
        dropin = self.fx.tree / "checkpoints" / "my-manual.safetensors"
        dropin.write_bytes(b"manual model")
        dangling = self.fx.tree / "vae" / "old-broken-link.safetensors"
        dangling.symlink_to(self.fx.root / "nowhere.safetensors")
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertTrue(dropin.is_file())
        self.assertEqual(dropin.read_bytes(), b"manual model")
        self.assertTrue(dangling.is_symlink())  # reported, never removed
        self.assertIn("broken unowned symlink", out)

    # ------------------------------------------------------------------- pruning
    def test_prune_on_blob_removal(self):
        populate_standard(self.fx)
        self.fx.sync()
        shutil.rmtree(self.fx.cache / "models--acme--flux-dev")
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertIn("PRUNE", out)
        self.assertNotIn("diffusion_models/flux1-dev.safetensors",
                         tree_links(self.fx.tree))
        reg = self.fx.load_registry()
        self.assertNotIn("acme/flux-dev/flux1-dev.safetensors",
                         {e["display"] for e in reg["entries"].values()})

    def test_prune_on_local_file_removed(self):
        populate_standard(self.fx)
        self.fx.sync()
        (self.fx.models / "loras" / "local-thing.safetensors").unlink()
        rc, out = self.fx.sync()
        self.assertNotIn("loras/local-thing.safetensors", tree_links(self.fx.tree))

    def test_no_prune_keeps_ownership_for_later(self):
        populate_standard(self.fx)
        self.fx.sync()
        shutil.rmtree(self.fx.cache / "models--acme--flux-dev")
        rc, out = self.fx.sync("--no-prune")
        stale = self.fx.tree / "diffusion_models" / "flux1-dev.safetensors"
        self.assertTrue(stale.is_symlink())         # kept (broken) ...
        self.assertFalse(stale.exists())
        reg = self.fx.load_registry()               # ... but still OURS
        owned = {l for e in reg["entries"].values() for l in e["links"]}
        self.assertIn("diffusion_models/flux1-dev.safetensors", owned)
        rc, out = self.fx.sync()                    # default prune cleans it up
        self.assertFalse(stale.is_symlink())

    # -------------------------------------------------------------- tree awareness
    # s35: in-box downloaders (ComfyUI-Manager et al) write REAL FILES through the models
    # bind straight into the link tree. Every sync now inventories them -- and does
    # nothing else to them, ever.
    def test_real_files_in_tree_are_inventoried_and_never_touched(self):
        populate_standard(self.fx)
        rc, out = self.fx.sync()
        self.assertIn("0 real files in tree", out)     # a pure link tree reports none

        drop = self.fx.tree / "loras" / "manager-downloaded.safetensors"
        drop.write_bytes(b"pulled in-box by a custom node")
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertIn("1 real files in tree", out)
        self.assertIn("REALFILE  loras/manager-downloaded.safetensors", out)
        # never adopted: not in the registry, so it can never become prunable
        reg = self.fx.load_registry()
        owned = {l for e in reg["entries"].values() for l in e["links"]}
        self.assertNotIn("loras/manager-downloaded.safetensors", owned)
        # ...and still exactly the bytes the downloader wrote, run after run
        for _ in range(2):
            self.fx.sync()
            self.assertTrue(drop.is_file())
            self.assertFalse(drop.is_symlink())
            self.assertEqual(drop.read_bytes(), b"pulled in-box by a custom node")

    def test_prune_never_deletes_a_real_file(self):
        """The dangerous case: a real file sitting at a path the registry OWNS, whose
        source has since vanished. Ownership says prune; the file being real says no,
        and the file wins -- prune_link only ever unlinks a symlink."""
        populate_standard(self.fx)
        self.fx.sync()
        owned_path = self.fx.tree / "diffusion_models" / "flux1-dev.safetensors"
        self.assertTrue(owned_path.is_symlink())
        owned_path.unlink()
        owned_path.write_bytes(b"a real file where our link used to be")
        shutil.rmtree(self.fx.cache / "models--acme--flux-dev")   # source gone: prune!

        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertTrue(owned_path.is_file())
        self.assertFalse(owned_path.is_symlink())
        self.assertEqual(owned_path.read_bytes(), b"a real file where our link used to be")
        self.assertIn("KEEP  diffusion_models/flux1-dev.safetensors", out)
        # counted (it IS a real file in the tree) but explained only once
        self.assertIn("1 real files in tree", out)
        self.assertNotIn("REALFILE  diffusion_models/flux1-dev.safetensors", out)

    def test_real_file_at_a_wanted_path_counts_once_as_a_conflict(self):
        populate_standard(self.fx)
        squatter = self.fx.tree / "loras" / "pixel-style-lora.safetensors"
        squatter.parent.mkdir(parents=True)
        squatter.write_bytes(b"user data - do not touch")
        rc, out = self.fx.sync()
        self.assertIn("CONFLICT  loras/pixel-style-lora.safetensors", out)
        self.assertIn("1 real files in tree", out)
        self.assertNotIn("REALFILE  loras/pixel-style-lora.safetensors", out)

    def test_owned_hardlinks_are_not_reported_as_real_files(self):
        """--hardlink makes every link we own a REGULAR file. Ownership is tested first
        precisely so the census does not accuse the scanner of its own work."""
        populate_standard(self.fx)
        rc, out = self.fx.sync("--hardlink")
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), EXPECTED_LINKS)
        hard = self.fx.tree / "vae" / "ae.safetensors"
        self.assertTrue(hard.is_file())
        self.assertFalse(hard.is_symlink())
        self.assertIn("0 real files in tree", out)

    # ------------------------------------------------- s35: user-driven link renames
    def test_rename_records_and_applies_immediately(self):
        populate_standard(self.fx)
        self.fx.sync()
        rc, out = self.fx.rename("pixel-style-lora.safetensors", "my-pixel-style.safetensors")
        self.assertEqual(rc, 0)
        self.assertIn("RENAME  pixel-style-lora.safetensors -> my-pixel-style.safetensors",
                      out)
        links = tree_links(self.fx.tree)
        self.assertIn("loras/my-pixel-style.safetensors", links)
        self.assertNotIn("loras/pixel-style-lora.safetensors", links)
        # the new link is a real link to the real blob, not a stub
        self.assertTrue((self.fx.tree / "loras" / "my-pixel-style.safetensors").resolve()
                        .is_file())
        reg = self.fx.load_registry()
        self.assertEqual(reg["renames"]["pixel-style-lora.safetensors"]["to"],
                         "my-pixel-style.safetensors")
        self.assertEqual(reg["renames"]["pixel-style-lora.safetensors"]["display"],
                         "acme/style-pack/pixel-style-lora.safetensors")
        owned = {l for e in reg["entries"].values() for l in e["links"]}
        self.assertIn("loras/my-pixel-style.safetensors", owned)

    def test_census_defends_a_rename_instead_of_steamrolling_it(self):
        """THE point of recording it: an ordinary sync must re-assert the user's name,
        and prune must not read the renamed link as an orphan."""
        populate_standard(self.fx)
        self.fx.sync()
        self.fx.rename("loras/pixel-style-lora.safetensors", "keeper.safetensors")
        for _ in range(2):
            rc, out = self.fx.sync()
            self.assertEqual(rc, 0)
            self.assertIn("loras/keeper.safetensors", tree_links(self.fx.tree))
            self.assertNotIn("loras/pixel-style-lora.safetensors",
                             tree_links(self.fx.tree))
            self.assertNotIn("PRUNE", out)        # not an orphan
            self.assertNotIn("RELINKED", out)     # ...and not churn, either

    def test_rename_survives_a_heuristics_bump(self):
        """A reclassification may move a file to another category dir. It may not take
        the owner's name away from it."""
        populate_standard(self.fx)
        self.fx.sync()
        self.fx.rename("pixel-style-lora.safetensors", "keeper.safetensors")
        with mock.patch.object(ms, "HEURISTICS_VERSION", ms.HEURISTICS_VERSION + 1):
            rc, out = self.fx.sync()
        self.assertIn("reclassifying everything", out)
        self.assertIn("loras/keeper.safetensors", tree_links(self.fx.tree))

    def test_rename_back_to_the_derived_name_forgets_it(self):
        populate_standard(self.fx)
        self.fx.sync()
        self.fx.rename("pixel-style-lora.safetensors", "keeper.safetensors")
        rc, out = self.fx.rename("keeper.safetensors", "pixel-style-lora.safetensors")
        self.assertEqual(rc, 0)
        self.assertIn("forgotten", out)
        self.assertIn("loras/pixel-style-lora.safetensors", tree_links(self.fx.tree))
        self.assertNotIn("loras/keeper.safetensors", tree_links(self.fx.tree))
        self.assertNotIn("renames", self.fx.load_registry())

    def test_rename_addresses_a_file_by_the_name_it_currently_wears(self):
        populate_standard(self.fx)
        self.fx.sync()
        self.fx.rename("pixel-style-lora.safetensors", "first.safetensors")
        rc, out = self.fx.rename("first.safetensors", "second.safetensors")
        self.assertEqual(rc, 0)
        self.assertIn("loras/second.safetensors", tree_links(self.fx.tree))
        reg = self.fx.load_registry()
        # ...and the ledger is still keyed on the DERIVED name, not chained
        self.assertEqual(list(reg["renames"]), ["pixel-style-lora.safetensors"])
        self.assertEqual(reg["renames"]["pixel-style-lora.safetensors"]["to"],
                         "second.safetensors")

    def test_rename_refuses_collisions_and_unknown_targets(self):
        populate_standard(self.fx)
        self.fx.sync()
        # (a) the new name is another source's derived name
        rc, out = self.fx.rename("pixel-style-lora.safetensors", "ae.safetensors")
        self.assertEqual(rc, 2)
        self.assertIn("ERROR", out)
        self.assertIn("Comfy-Org/flux-repack", out)
        # (b) something is already sitting at the target path in the tree
        squatter = self.fx.tree / "loras" / "taken.safetensors"
        squatter.write_bytes(b"mine")
        rc, out = self.fx.rename("pixel-style-lora.safetensors", "taken.safetensors")
        self.assertEqual(rc, 2)
        self.assertIn("loras/taken.safetensors already exists", out)
        self.assertEqual(squatter.read_bytes(), b"mine")
        # (c) nothing by that name
        rc, out = self.fx.rename("no-such-model.safetensors", "whatever.safetensors")
        self.assertEqual(rc, 2)
        self.assertIn("nothing named", out)
        # (d) a path, not a name, on the NEW side
        rc, out = self.fx.rename("pixel-style-lora.safetensors", "sub/dir.safetensors")
        self.assertEqual(rc, 2)
        self.assertIn("plain filename", out)
        # nothing above changed anything
        self.assertIn("loras/pixel-style-lora.safetensors", tree_links(self.fx.tree))
        self.assertNotIn("renames", self.fx.load_registry())

    def test_rename_list_reports_what_is_recorded(self):
        populate_standard(self.fx)
        self.fx.sync()
        rc, out = self.fx.rename("--list")
        self.assertEqual(rc, 0)
        self.assertIn("0 recorded rename(s)", out)
        self.fx.rename("pixel-style-lora.safetensors", "keeper.safetensors")
        rc, out = self.fx.rename("--list")
        self.assertEqual(rc, 0)
        self.assertIn("RENAME  pixel-style-lora.safetensors -> keeper.safetensors", out)
        self.assertIn("acme/style-pack/pixel-style-lora.safetensors", out)  # receipt
        self.assertIn("1 recorded rename(s)", out)

    # ------------------------------------------- s35: the NAME-IS-API blacklist (data)
    def _facexlib_fixture(self) -> str:
        """A file that ships under a name facexlib loads by. Content is irrelevant --
        the whole claim of the table is about the NAME."""
        self.fx.add_local_file("facedetection/detection_Resnet50_Final.pth", b"\x00" * 64)
        return "detection_Resnet50_Final.pth"

    def test_shipped_blacklist_seeds_the_facexlib_trio_with_receipts(self):
        table = ms.load_name_api_blacklist(ms.DEFAULT_NAME_API_BLACKLIST)
        for name in ("detection_Resnet50_Final.pth",
                     "detection_mobilenet0.25_Final.pth",
                     "parsing_parsenet.pth"):
            hit = ms.match_name_api(table, name)
            self.assertIsNotNone(hit, name)
            self.assertEqual(hit["library"], "facexlib")
            self.assertEqual(hit["match"], "exact")
            self.assertTrue(hit["note"], f"{name} has no consequence note")

    def test_shipped_blacklist_carries_every_match_kind_it_claims(self):
        """The s35 research pass (danger-models-research.md) is not a list of exact
        filenames: 7 rows name DIRECTORIES a loader addresses as a unit, and 8 are
        NAMING RULES rather than names. Both shapes have to survive the trip from that
        document into this table, or the entries were silently dropped."""
        table = ms.load_name_api_blacklist(ms.DEFAULT_NAME_API_BLACKLIST)
        self.assertGreater(len(table), 200, "the seeded table lost most of its rows")
        kinds = {row["match"] for row in table}
        self.assertEqual(kinds, {"exact", "glob", "dir"})
        # a directory row: insightface's pack, whose MEMBER .onnx files are safe
        buffalo = ms.match_name_api(table, "buffalo_l")
        self.assertEqual(buffalo["match"], "dir")
        # a naming RULE: the SAM architecture token. Deliberately tested on a name that
        # is NOT one of the canonical SAM releases (those have exact rows of their own)
        # -- the whole point of the rule is that it also covers the repacks and forks
        # nobody has enumerated, which is the class no exact name can express.
        sam = ms.match_name_api(table, "some-repack_sam_vit_h_v2.pth")
        self.assertIsNotNone(sam, "the *vit_h* substring rule did not fire")
        self.assertEqual(sam["match"], "glob")
        # ...and an exact row still outranks a broad pattern that also matches it
        exact = ms.match_name_api(table, "detection_mobilenet0.25_Final.pth")
        self.assertEqual(exact["match"], "exact")   # not the `*mobile*` glob
        self.assertEqual(exact["library"], "facexlib")
        # every row is usable: a consumer to name and a consequence to state
        for row in table:
            self.assertTrue(row["library"], row)
            self.assertTrue(row["note"], row)

    def test_every_rename_states_what_it_costs(self):
        """Two facts no per-file table can carry, because they are true of EVERY
        rename. They are not blocks -- the user decides -- but a user who was never
        told has not decided (danger-models-research.md sections 10 and 12)."""
        populate_standard(self.fx)
        self.fx.sync()
        rc, out = self.fx.rename("pixel-style-lora.safetensors", "renamed.safetensors")
        self.assertEqual(rc, 0)
        self.assertIn("saved workflows store the picker STRING", out)
        self.assertIn("ComfyUI-Manager", out)
        # ...and on the way back out again, because undoing is also a rename
        rc, out = self.fx.rename("renamed.safetensors",
                                 "pixel-style-lora.safetensors")
        self.assertEqual(rc, 0)
        self.assertIn("value not in list", out)

    def test_rename_of_a_name_is_api_file_is_skipped_unless_forced(self):
        name = self._facexlib_fixture()
        self.fx.sync()
        rc, out = self.fx.rename(name, "my-face-detector.pth")
        self.assertEqual(rc, 2)                       # a refusal is never silent
        self.assertIn("SKIP", out)
        self.assertIn("facexlib", out)                # who hardcodes it
        self.assertIn("re-download", out)             # ...and what it costs
        self.assertIn("--force", out)                 # ...and the way past it
        self.assertIn(f"facedetection/{name}", tree_links(self.fx.tree))
        self.assertNotIn("renames", self.fx.load_registry())

        # --force overrides, and the record it leaves is an ORDINARY record: nothing in
        # the registry marks it as forced, because nothing downstream should treat it so.
        rc, out = self.fx.rename("--force", name, "my-face-detector.pth")
        self.assertEqual(rc, 0)
        self.assertIn("facedetection/my-face-detector.pth", tree_links(self.fx.tree))
        rec = self.fx.load_registry()["renames"][name]
        self.assertEqual(set(rec), {"to", "display", "recorded"})

    def test_blacklist_is_data_appendable_without_code_changes(self):
        """The table is a YAML FILE, not a Python constant: an entry nobody has written
        code for still guards a rename, and an absent file guards nothing."""
        self.fx.add_local_file("loras/some-node-weights.safetensors",
                               safetensors_bytes(["whatever.weight"]))
        self.fx.sync()
        table = self.fx.root / "extra-blacklist.yaml"
        table.write_text(
            "version: 1\n"
            "files:\n"
            "  - filename: some-node-weights.safetensors\n"
            "    library: some-future-node-pack\n"
            "    note: it re-downloads 2 GB if the name changes.\n")
        rc, out = self.fx.rename("--name-api-blacklist", str(table),
                                 "some-node-weights.safetensors", "nicer.safetensors")
        self.assertEqual(rc, 2)
        self.assertIn("some-future-node-pack", out)
        self.assertIn("re-downloads 2 GB", out)
        # ...and the BARE-LIST shape parses too, because that is how rows arrive when
        # they are pasted straight out of the research document. A paste that failed to
        # parse would disarm the whole guard silently (the loader fails open).
        flat = self.fx.root / "pasted.yaml"
        flat.write_text(
            "- filename: some-node-weights.safetensors\n"
            "  library: pasted-without-indenting\n"
            "  note: still guarded.\n")
        rc, out = self.fx.rename("--name-api-blacklist", str(flat),
                                 "some-node-weights.safetensors", "nicer.safetensors")
        self.assertEqual(rc, 2)
        self.assertIn("pasted-without-indenting", out)
        # absent table -> empty table -> no guard, and NOT an error
        self.assertEqual(ms.load_name_api_blacklist(self.fx.root / "gone.yaml"), [])
        rc, out = self.fx.rename("--name-api-blacklist", str(self.fx.root / "gone.yaml"),
                                 "some-node-weights.safetensors", "nicer.safetensors")
        self.assertEqual(rc, 0)
        self.assertIn("loras/nicer.safetensors", tree_links(self.fx.tree))

    def test_unreadable_blacklist_warns_and_fails_open(self):
        bad = self.fx.root / "bad.yaml"
        bad.write_text("files: [ this: is: not: yaml\n")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            table = ms.load_name_api_blacklist(bad)
        self.assertEqual(table, [])
        self.assertIn("WARN", buf.getvalue())

    # ------------------------------- s35: one restricted unpickler, not one per tool
    def test_the_restricted_unpickler_exists_exactly_once(self):
        """The execution-free reader is a SECURITY boundary. It was written for
        droste-civitai-adopt, hand-ported into this scanner, and the two copies then
        drifted -- so a hardening applied to the copy you were looking at was not a
        hardening. model_formats.py is now the only place it exists, and this test is
        what notices if somebody re-forks it."""
        import model_formats

        self.assertIs(ms.read_torch_container, model_formats.read_torch_container)
        self.assertFalse(hasattr(ms, "_restricted_unpickle"))
        scripts = Path(ms.__file__).resolve().parent
        self.assertIn("pickle.Unpickler",
                      (scripts / "model_formats.py").read_text())
        for tool in ("model_scanner.py", "droste-civitai-adopt.sh"):
            self.assertNotIn("pickle.Unpickler", (scripts / tool).read_text(),
                             f"{tool} grew its own unpickler again")

    # ------------------------- heuristics 13: the crossing rules (s46)
    def test_upscaler_architecture_classifies_by_content(self):
        """THE BIGGEST GAP THE s41 AUDIT FOUND, and it pointed the other way: the adopt
        tool had seven upscaler-architecture rules and this scanner had NONE. An ESRGAN
        whose filename carries no `esrgan`/`4x` token therefore got no content vote at
        all and ended `unclassified`. It now classifies on its own tensors."""
        for keys, label in (
                (["model.1.sub.0.RDB1.conv1.weight"], "ESRGAN"),
                (["RRDB_trunk.0.RDB1.conv1.weight"], "ESRGAN (alt spelling)"),
                (["conv_first.weight", "body.0.rdb1.conv1.weight"], "RealESRGAN"),
                (["m_head.0.weight", "m_body.0.weight", "m_tail.0.weight"], "ScuNET"),
                (["l.0.residual_group.b.0.attn.relative_position_bias_table"], "SwinIR"),
                (["l.0.attn.relative_position_bias_table", "conv_after_body.weight"],
                 "HAT")):
            hdr = {k: {} for k in keys}
            self.assertEqual(ms.classify_safetensors_header(hdr), "upscale_models", label)
        # ...and an ABSOLUTE architecture is conclusive evidence, not a 0.6 guess
        self.assertEqual(ms.rate_safetensors({"model.1.sub.0.RDB1.conv1.weight": {}}),
                         ("upscale_models", ms.EMBEDDED_MAX_RATING))
        # ⚠️ The UNCERTAIN tier does not classify AT ALL, and that is deliberate rather
        # than an oversight. DAT's spatial blocks and a bare SwinIR window-attention
        # table say "some upscaler" without saying which, and the rule is SHARED: the
        # adopt tool stamps every kind it receives as `absolute` for routing, so a kind
        # returned on uncertain evidence would route a file over the CivitAI API's word
        # for it. Abstaining here costs nothing -- the naming rules still catch a file
        # called `*_dat_*` -- and it keeps content from overriding the API on a guess.
        self.assertIsNone(ms.classify_safetensors_header({"spatial_block.0.weight": {}}))
        self.assertIsNone(ms.rate_safetensors({"spatial_block.0.weight": {}}))

    def test_t2i_adapter_classifies_by_content(self):
        """`adapter.body.` is measured, not guessed: TencentARC's t2i-adapter-canny-sdxl
        and -depth-midas-sdxl were read over HTTP range requests -- 38 tensors each,
        every one under `adapter.`. It lands in controlnet, which is exactly where this
        tool's own FILENAME rule already sends a file named `t2iadapter_*`; the content
        rule agrees with the naming rule instead of inventing a third answer."""
        self.assertEqual(
            ms.classify_safetensors_header({"adapter.body.0.resnets.0.block1.bias": {}}),
            "controlnet")
        self.assertEqual(ms.classify_by_filename("t2iadapter_canny_sd14v1.pth"),
                         "controlnet")

    # ------------------------- s46: one key-signature rule set, two vocabularies
    def test_key_rules_live_in_the_shared_module(self):
        """The rules moved to model_formats in s46 for the same reason the unpickler
        did: the adopt tools need the same knowledge and were keeping a second, partial
        copy. What stays HERE is the mapping to ComfyUI loader dirs -- the tree is a
        rendering, the kind is the domain model."""
        import model_formats

        self.assertIs(ms.classify_keys, model_formats.classify_keys)
        self.assertIs(ms.strip_dataparallel, model_formats.strip_dataparallel)
        scripts = Path(ms.__file__).resolve().parent
        # STRING LITERALS ONLY, via the AST -- not a text grep. Comments and docstrings
        # legitimately DESCRIBE the heuristics (the HEURISTICS_VERSION changelog names
        # several rules by their key signature, and should), and prose about a rule is
        # not a copy of it. A re-implementation, on the other hand, needs the literal.
        tree = ast.parse((scripts / "model_scanner.py").read_text())
        docstrings = {id(n.body[0].value) for n in ast.walk(tree)
                      if isinstance(n, (ast.Module, ast.ClassDef, ast.FunctionDef))
                      and n.body and isinstance(n.body[0], ast.Expr)
                      and isinstance(n.body[0].value, ast.Constant)
                      and isinstance(n.body[0].value.value, str)}
        literals = [n.value for n in ast.walk(tree)
                    if isinstance(n, ast.Constant) and isinstance(n.value, str)
                    and id(n) not in docstrings]
        for signature in ("controlnet_x_embedder.", "Mconv", "BboxHead.",
                          "adaln_modulation", "text_embedding_projection."):
            self.assertNotIn(signature, literals,
                             f"key-signature rule {signature!r} re-grew in the scanner")
        # ⚠️ `first_stage_model.` is the ONE signature still spelled in both tools, and
        # it is deliberate rather than missed: the scanner tests it in
        # checkpoint_packaged_vae (the s43 WARN) and the adopt tool tests it for
        # `embedded_vae`. Whether the SHARED classifier should carry "packaged as a
        # checkpoint section" as DATA both tools may read, or stay one tool's warn, is
        # an OPEN question for Jei in the unification plan. This assertion records the
        # duplication on purpose, so that closing the question removes a failing test
        # rather than leaving an invisible fork.
        self.assertIn("first_stage_model.", literals,
                      "packaged-VAE moved to the shared module? update the plan's open "
                      "question and this test together")
        self.assertIn("controlnet_x_embedder.",
                      (scripts / "model_formats.py").read_text())

    def test_kind_map_is_total_over_the_rules(self):
        """Every KIND the shared rules can return must have a home in this tool.

        The map uses `.get`, so an unmapped kind ABSTAINS rather than raising -- the
        right behaviour for a rule that exists for the adopt side only, and the wrong
        thing to discover by watching a file go unclassified. This test is the tripwire:
        add a rule that returns a new kind and either map it or add it to the exemption
        list below, deliberately."""
        import model_formats

        # kinds the shared module defines but this tool has nowhere to put YET. Empty
        # today; the adopt tool's t2i-adapter and upscaler rules will land here first
        # and move into the map with the HEURISTICS_VERSION bump that pays for them.
        EXEMPT: set = set()
        produced = set()
        for keys in (["lora_unet_x.weight"], ["model.diffusion_model.x"],
                     ["down_blocks.0.motion_modules.0.temporal_transformer.x"],
                     ["down_blocks.0.motion_modules.0.temporal_transformer.attention"
                      "_blocks.0.processor.to_k_lora.down.weight"],
                     ["control_model.x"], ["controlnet_blocks.0.x"],
                     ["BboxHead.0.x", "ClassHead.0.x", "LandmarkHead.0.x"],
                     ["Mconv1_stage2.bias"], ["vision_model.x"],
                     ["vision_model.x", "model.layers.0.x"],
                     ["text_embedding_projection.x"], ["double_blocks.0.x"],
                     ["transformer_blocks.0.x", "img_in.x"],
                     ["patch_embedding.x", "time_embedding.x"],
                     ["net.blocks.0.adaln_modulation.x"], ["encoder.block.0.layer.0.SelfAttention.q.weight"],
                     ["first_stage_model.decoder.x"],
                     ["encoder.down.0.x", "decoder.up.0.x"], ["t5.x"],
                     ["adapter.body.0.x"], ["model.1.sub.0.RDB1.conv1.w"]):
            kind = model_formats.classify_keys(keys)
            self.assertIsNotNone(kind, f"a rule stopped firing for {keys[0]!r}")
            produced.add(kind)
        unmapped = produced - set(ms.KIND_TO_CATEGORY) - EXEMPT
        self.assertEqual(unmapped, set(), f"kinds with no ComfyUI destination: {unmapped}")
        for kind, cat in ms.KIND_TO_CATEGORY.items():
            self.assertIn(cat, ms.CATEGORIES | {ms.POSE_STAGE_CATEGORY},
                          f"{kind} maps to {cat}, which is not a category we link into")

    # --------------------------------------------------------------- inventory
    def test_inventory_skipped_and_cached(self):
        populate_standard(self.fx)
        rc, out = self.fx.sync()
        for rel in tree_links(self.fx.tree):
            self.assertNotIn("mystery.safetensors", rel)
            self.assertNotIn("assistant-8b", rel)
            self.assertNotIn("pytorch_model", rel)
            self.assertNotIn("tiny-llm", rel)
        # cached: second run re-inspects nothing (also covered by the no-op test)
        with mock.patch.object(ms, "read_gguf_metadata",
                               side_effect=AssertionError("re-inspected")) as g:
            self.fx.sync()
        self.assertEqual(g.call_count, 0)

    # ------------------------------------------- heuristics 9: the `format` field
    def test_detect_format_unit(self):
        """One helper derives the CONTAINER format from extension + magic + sibling
        evidence, so role (`category`) and container stop fighting for one string."""
        def src(link_name, path=Path("/nonexistent"),
                config_dir=Path("/nonexistent"), display=None):
            return SimpleNamespace(link_name=link_name, path=path,
                                   config_dir=config_dir,
                                   display=display or link_name)

        self.assertEqual(ms.detect_format(src("a.gguf")), "gguf")
        self.assertEqual(ms.detect_format(src("a.safetensors")), "safetensors")
        # bare pickle extensions: no magic, no CT2 sibling
        p = self.fx.root / "w.pth"
        p.write_bytes(b"\x80\x02junk")
        self.assertEqual(ms.detect_format(src("w.pth", path=p)), "pickle")
        # ggml magic outranks the pickle extension (.bin is not a pickle here)
        g = self.fx.root / "whisper-tiny.bin"
        g.write_bytes(b"ggml" + b"\x00" * 16)
        self.assertEqual(ms.detect_format(src("whisper-tiny.bin", path=g)), "ggml")
        # CTranslate2: a .bin beside a signature vocabulary sibling
        d = self.fx.root / "ct2"
        d.mkdir()
        m = d / "model.bin"
        m.write_bytes(b"ct2-binary-not-a-torch-file")
        (d / "vocabulary.txt").write_text("<|token|>\n")
        self.assertEqual(
            ms.detect_format(src("model.bin", path=m, config_dir=d,
                                 display="whisper/model.bin")),
            "ctranslate2")
        # a .bin with neither magic nor sibling is an HF-format torch pickle
        b = self.fx.root / "pytorch_model.bin"
        b.write_bytes(b"\x80\x02junk")
        self.assertEqual(ms.detect_format(src("pytorch_model.bin", path=b)), "pickle")

    def test_format_recorded_in_registry(self):
        """Every entry gains `format` beside `category`; repo units get `diffusers`."""
        ids = populate_raiju(self.fx)   # safetensors components + CT2 whisper + unit
        self.fx.add_hf_file("bartowski/assistant", "assistant-8b-q4.gguf",
                            gguf_bytes("llama"))
        self.fx.add_local_file("misc/esrgan-4x.pth", b"\x00" * 64)
        self.fx.add_local_file("whisper-tiny.bin", b"ggml" + b"\x00" * 32)
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        reg = self.fx.load_registry()
        fmts = {e["display"]: e.get("format") for e in reg["entries"].values()}
        self.assertEqual(fmts["bartowski/assistant/assistant-8b-q4.gguf"], "gguf")
        self.assertEqual(fmts["black-forest-labs/FLUX.1-Fill-dev/"
                              "vae/diffusion_pytorch_model.safetensors"],
                         "safetensors")
        self.assertEqual(fmts["misc/esrgan-4x.pth"], "pickle")
        self.assertEqual(fmts["whisper-tiny.bin"], "ggml")
        self.assertEqual(fmts["Systran/faster-whisper-large-v2/model.bin"],
                         "ctranslate2")
        # role stays separate: both whisper containers are `asr` by category
        cats = {e["display"]: e["category"] for e in reg["entries"].values()}
        self.assertEqual(cats["Systran/faster-whisper-large-v2/model.bin"], "asr")
        self.assertEqual(cats["whisper-tiny.bin"], "asr")
        # the repo unit records format: diffusers beside category: diffusers, no links
        unit = reg["entries"][ids["unit"]]
        self.assertEqual(unit["category"], "diffusers")
        self.assertEqual(unit["format"], "diffusers")
        self.assertEqual(unit["links"], [])
        # additive + universal: every entry has the field
        self.assertTrue(all("format" in e for e in reg["entries"].values()))
        # cached identities carry the format forward on a steady-state run
        self.fx.sync()
        reg2 = self.fx.load_registry()
        self.assertEqual(
            {e["display"]: e.get("format") for e in reg2["entries"].values()}, fmts)

    # --------------------- s32: `diffusers` is inventory-only, never a folder rule
    def test_diffusers_segment_no_longer_classifies_or_links(self):
        """The bug (s32): a file under a `diffusers/` directory was classified
        `diffusers`@0.3 off the folder name alone and LINKED, while a byte-identical
        file elsewhere went unclassified. The folder name must carry no signal:
        unclassified, NOT silently inventoried, NOT linked."""
        self.fx.add_local_file("diffusers/mystery.safetensors",
                               safetensors_bytes(["foo.bar"]))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), set())
        reg = self.fx.load_registry()
        self.assertEqual(len(reg["entries"]), 1)
        entry = next(iter(reg["entries"].values()))
        self.assertEqual(entry["category"], "unclassified")
        self.assertEqual(entry["links"], [])
        self.assertIn("UNCLASSIFIED", out)
        # and the segment classifier itself is silent on the name
        self.assertIsNone(ms.classify_by_segments(
            SimpleNamespace(rel_dir_parts=("diffusers",))))

    def test_linkable_rejects_inventory_even_if_readded_to_categories(self):
        """Belt-and-braces guard in linkable(): an inventory category stays
        unlinkable even if someone re-adds it to the CATEGORIES set by mistake."""
        src = SimpleNamespace(sharded=False)
        self.assertTrue(ms.linkable(src, "vae"))
        for cat in ms.INVENTORY_CATEGORIES:
            self.assertFalse(ms.linkable(src, cat), cat)
        with mock.patch.object(ms, "CATEGORIES", ms.CATEGORIES | {"diffusers"}):
            self.assertFalse(ms.linkable(src, "diffusers"))

    # -------------------------------------------------------------------- dry-run
    def test_dry_run_changes_nothing(self):
        populate_standard(self.fx)
        rc, out = self.fx.sync("--dry-run")
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), set())
        self.assertFalse(self.fx.registry.exists())
        self.assertIn("DRY-LINKED", out)
        self.assertIn("[dry-run]", out)
        # dry-run prune: set up state, remove a source, dry-run again
        self.fx.sync()
        shutil.rmtree(self.fx.cache / "models--acme--flux-dev")
        rc, out = self.fx.sync("-n")
        self.assertIn("DRY-PRUNE", out)
        self.assertTrue((self.fx.tree / "diffusion_models"
                         / "flux1-dev.safetensors").is_symlink())

    # --------------------------------------------------------------------- status
    def test_status_reports(self):
        populate_standard(self.fx)
        self.fx.sync()
        # user drop-in + a vanished source + a new source
        (self.fx.tree / "checkpoints" / "my-manual.safetensors").write_bytes(b"x")
        shutil.rmtree(self.fx.cache / "models--acme--flux-dev")
        self.fx.add_hf_file("acme/new-lora", "fresh-lora.safetensors",
                            safetensors_bytes(["lora_unet_a.lora_down.weight"]))
        rc, out = self.fx.status()
        self.assertEqual(rc, 0)
        self.assertIn("USER  checkpoints/my-manual.safetensors", out)
        self.assertIn("GONE", out)
        self.assertIn("NEW  acme/new-lora/fresh-lora.safetensors", out)
        self.assertIn("BROKEN", out)          # owned link whose blob vanished
        # UNCLASSIFIED lists only the true unknown, not the llm inventory
        self.assertIn("UNCLASSIFIED  acme/enigma/mystery.safetensors", out)
        self.assertNotIn("UNCLASSIFIED  meta/tiny-llm", out)
        self.assertNotIn("UNCLASSIFIED  bartowski/assistant", out)
        self.assertIn("model-scanner status:", out)
        # status is read-only
        self.assertTrue((self.fx.tree / "diffusion_models"
                         / "flux1-dev.safetensors").is_symlink())

    def test_status_counts_repo_units_without_noise(self):
        populate_raiju(self.fx)
        self.fx.sync()
        rc, out = self.fx.status()
        self.assertEqual(rc, 0)
        self.assertIn("1 repo units", out)
        self.assertIn("0 new, 0 gone", out)   # unit is stable across runs
        self.assertNotIn("UNCLASSIFIED", out)

    # ------------------------------------------------ status: the real-file row split
    # A real file in the tree (weights that exist nowhere else) and an unowned symlink
    # (a link somebody else made) are different findings, and `status` used to add them
    # up into one "N files+links". The number sync's census reports as "N real files in
    # tree" was therefore unreadable from `status` -- it now has its own component.
    def test_status_splits_real_files_from_unowned_links(self):
        populate_standard(self.fx)
        self.fx.sync()
        rc, out = self.fx.status()
        self.assertEqual(rc, 0)
        self.assertIn("user items: 0 real files + 0 links, 0 broken", out)

        dropin = self.fx.tree / "checkpoints" / "my-manual.safetensors"
        dropin.write_bytes(b"pulled in-box by a custom node")
        theirs = self.fx.tree / "vae" / "their-own-link.safetensors"
        theirs.symlink_to(self.fx.models / "loras" / "local-thing.safetensors")
        dangling = self.fx.tree / "vae" / "old-broken-link.safetensors"
        dangling.symlink_to(self.fx.root / "nowhere.safetensors")

        rc, out = self.fx.status()
        self.assertEqual(rc, 0)
        self.assertIn("user items: 1 real files + 1 links, 1 broken", out)
        # ...and each row says WHICH it is, so the counts can be read off the detail
        self.assertIn("USER  checkpoints/my-manual.safetensors "
                      "(real file, not ours; never touched)", out)
        self.assertIn("USER  vae/their-own-link.safetensors "
                      "(link, not ours; never touched)", out)
        self.assertIn("broken unowned symlink (left alone): "
                      "vae/old-broken-link.safetensors", out)

    def test_status_real_file_count_agrees_with_the_sync_census(self):
        """Two reports, one tree: the split exists so the same walk reports the same
        number in both verbs. A `status` real-file count that disagreed with the census
        would mean one of them is counting links."""
        populate_standard(self.fx)
        self.fx.sync()
        (self.fx.tree / "loras" / "manager-downloaded.safetensors").write_bytes(b"in-box")
        (self.fx.tree / "loras" / "manager-two.safetensors").write_bytes(b"in-box again")
        (self.fx.tree / "vae" / "their-own-link.safetensors").symlink_to(
            self.fx.models / "loras" / "local-thing.safetensors")

        rc, sync_out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertIn("2 real files in tree", sync_out)
        rc, out = self.fx.status()
        self.assertEqual(rc, 0)
        self.assertIn("user items: 2 real files + 1 links,", out)

    def test_status_does_not_report_owned_hardlinks_as_real_files(self):
        """The census tests ownership before realness so --hardlink does not make the
        scanner accuse itself; status walks the same tree and owes the same answer."""
        populate_standard(self.fx)
        self.fx.sync("--hardlink")
        hard = self.fx.tree / "vae" / "ae.safetensors"
        self.assertTrue(hard.is_file())
        self.assertFalse(hard.is_symlink())
        rc, out = self.fx.status()
        self.assertEqual(rc, 0)
        self.assertIn("user items: 0 real files + 0 links, 0 broken", out)
        self.assertNotIn("USER  ", out)

    def test_status_reports_a_real_file_at_an_owned_path_as_replaced(self):
        """The defect this pins: `status` called a REGULAR FILE at an owned path a
        healthy owned link, and its ownership skip then kept that same file out of the
        real-file count -- wrong twice, in one line. The window is exactly "registry
        stale relative to the tree": sync disowns the path on its next run (ensure_link
        -> conflict, rel left out of the rebuilt entry) and the two reports agree again,
        so status has to be right BEFORE that happens, not after."""
        populate_standard(self.fx)
        self.fx.sync()
        link = self.fx.tree / "loras" / "local-thing.safetensors"
        self.assertTrue(link.is_symlink())
        link.unlink()
        link.write_bytes(b"a real file where our link used to be")

        rc, out = self.fx.status()
        self.assertEqual(rc, 0)
        self.assertIn("REPLACED  loras/local-thing.safetensors", out)
        self.assertNotIn("links: 8 ok", out)
        self.assertIn("/ 1 replaced", out)
        # and it is counted where sync counts it -- the two verbs, one tree, one number
        self.assertIn("user items: 1 real files", out)
        rc, sync_out = self.fx.sync("-n")
        self.assertEqual(rc, 0)
        self.assertIn("1 real files in tree", sync_out)
        # named once: REPLACED explains it, the inventory must not repeat it as USER
        self.assertNotIn("USER  loras/local-thing.safetensors", out)

    def test_status_accepts_an_owned_hardlink_as_ok_without_being_told(self):
        """Hardlink-awareness, and why the INODE has to decide it: under --hardlink every
        owned link is a regular file, and `status` takes no --hardlink flag -- it reads a
        tree somebody else built. Mode cannot answer the question; identity can."""
        populate_standard(self.fx)
        self.fx.sync("--hardlink")
        hard = self.fx.tree / "vae" / "ae.safetensors"
        self.assertTrue(hard.is_file() and not hard.is_symlink())
        rc, out = self.fx.status()
        self.assertEqual(rc, 0)
        self.assertNotIn("REPLACED", out)
        self.assertNotIn("replaced", out)
        self.assertIn("0 broken / 0 missing,", out)

    def test_status_ok_broken_and_missing_are_unchanged(self):
        """The three states that were already right stay right -- the fix changes what
        `ok` MEANS, so the other three buckets are the regression surface."""
        populate_standard(self.fx)
        self.fx.sync()
        rc, out = self.fx.status()
        self.assertEqual(rc, 0)
        self.assertIn("0 broken / 0 missing,", out)
        self.assertNotIn("replaced", out)   # the bucket is silent when it is empty

        (self.fx.tree / "loras" / "local-thing.safetensors").unlink()
        broken = self.fx.tree / "vae" / "ae.safetensors"
        broken.unlink()
        broken.symlink_to(self.fx.root / "nowhere.safetensors")
        rc, out = self.fx.status()
        self.assertEqual(rc, 0)
        self.assertIn("BROKEN  vae/ae.safetensors", out)
        self.assertIn("MISSING  loras/local-thing.safetensors", out)
        self.assertIn("1 broken / 1 missing,", out)

    def test_checkpoint_packaged_vae_warns_and_changes_nothing(self):
        """Jei's ruling on the edge case (s43): "warn, and do nothing with it". A VAE that
        kept a checkpoint's `first_stage_model.` prefix still classifies as a vae and is
        still linked into vae/ -- the warn exists because ComfyUI's VAELoader wants bare
        encoder./decoder. keys and would not open the file as-is."""
        self.fx.add_local_file("odd/packaged-vae.safetensors",
                               safetensors_bytes(["first_stage_model.decoder.conv_in.weight",
                                                  "first_stage_model.encoder.conv_in.weight"]))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertIn("carrying a checkpoint's `first_stage_model.` prefix", out)
        # ...and DID NOTHING: still a vae, still linked, still byte-identical on disk
        self.assertIn("vae/packaged-vae.safetensors", tree_links(self.fx.tree))
        self.assertEqual(
            (self.fx.models / "odd" / "packaged-vae.safetensors").read_bytes(),
            safetensors_bytes(["first_stage_model.decoder.conv_in.weight",
                               "first_stage_model.encoder.conv_in.weight"]))

    def test_a_full_checkpoint_never_triggers_the_packaged_vae_warn(self):
        """The co-occurrence rule, which is what makes the warn safe: `first_stage_model.`
        WITH `model.diffusion_model.` is a checkpoint and the VAE is an attribute of it.
        Verified against the real SD1.5 header (s43): prefixes are exactly
        `cond_stage_model. / first_stage_model. / model. / model_ema.`."""
        self.fx.add_local_file("ckpt/sd15-ish.safetensors",
                               safetensors_bytes([
                                   "model.diffusion_model.input_blocks.0.0.weight",
                                   "first_stage_model.decoder.conv_in.weight",
                                   "cond_stage_model.transformer.x.weight"]))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertNotIn("first_stage_model.` prefix", out)
        self.assertIn("checkpoints/sd15-ish.safetensors", tree_links(self.fx.tree))

    def test_packaged_vae_predicate_is_not_fooled_by_an_earlier_rule(self):
        """`warn_if_packaged_vae` is guarded on the CATEGORY as well as the keys: a LoRA
        that happens to mention first_stage_model. is claimed by the lora rule long before
        the vae rule, and warning about it would be noise about the wrong file."""
        keys = ["lora_unet_x.lora_down.weight", "first_stage_model.decoder.w"]
        self.assertTrue(ms.checkpoint_packaged_vae(keys))       # keys alone say yes...
        self.assertEqual(ms.classify_safetensors_header(
            {k: {} for k in keys}), "loras")   # ...the classifier says lora
        # and the guard is the category, so nothing is said about a lora
        self.fx.add_local_file("loras/odd-one.safetensors", safetensors_bytes(keys))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertNotIn("first_stage_model.` prefix", out)

    # ------------------------------------------------------------ name collisions
    def test_name_collision_gets_disambiguated(self):
        self.fx.add_hf_file("acme/pack-one", "vae/dup.safetensors",
                            safetensors_bytes(["a.weight"]))
        self.fx.add_hf_file("acme/pack-two", "vae/dup.safetensors",
                            safetensors_bytes(["b.weight"]))  # different content
        rc, out = self.fx.sync()
        links = tree_links(self.fx.tree)
        self.assertEqual(len(links), 2, links)
        self.assertIn("vae/dup.safetensors", links)
        self.assertEqual(len([l for l in links if l.endswith("dup.safetensors")]), 2)

    # ------------------------------------------------------- classification units
    def test_classifier_units(self):
        header_cases = [
            (["lora_unet_down.lora_down.weight"], None, "loras"),
            (["model.diffusion_model.x", "first_stage_model.y"], None, "checkpoints"),
            (["diffusion_model.x"], None, "diffusion_models"),
            (["joint_blocks.0.x"], None, "diffusion_models"),
            (["control_model.x"], None, "controlnet"),
            (["vision_model.x"], None, "clip_vision"),
            (["first_stage_model.decoder.x"], None, "vae"),
            # heuristics 11: an encoder/decoder pair must carry real autoencoder
            # anatomy; the bare pair this case used to assert on is now ParseNet's
            # shape, and is pinned as a NON-vae in its own test.
            (ldm_vae_keys(), None, "vae"),
            (diffusers_vae_keys(), None, "vae"),
            (["encoder.block.0.layer.0.SelfAttention.q.weight", "shared.weight"], None,
             "text_encoders"),  # T5-style must NOT hit the generic vae rule
            (["text_model.encoder.x"], None, "text_encoders"),
            (["foo.bar"], None, None),
            (["x.weight"], {"modelspec.architecture": "flux-1-dev/lora"}, "loras"),
        ]
        for names, metadata, want in header_cases:
            header = {n: {"dtype": "F32", "shape": [1], "data_offsets": [0, 4]}
                      for n in names}
            if metadata:
                header["__metadata__"] = metadata
            self.assertEqual(ms.classify_safetensors_header(header), want, names)

        self.assertEqual(ms.classify_by_filename("umt5_xxl_fp8.safetensors"),
                         "text_encoders")
        self.assertEqual(ms.classify_by_filename("qwen_2.5_vl_7b.safetensors"),
                         "text_encoders")
        self.assertEqual(ms.classify_by_filename("clip_vision_h.safetensors"),
                         "clip_vision")
        self.assertEqual(ms.classify_by_filename("taesd_decoder.pth"), "vae_approx")
        self.assertEqual(ms.classify_by_filename("flux1-canny-dev.safetensors"),
                         "controlnet")
        self.assertEqual(ms.classify_by_filename("plain-model.safetensors"), None)

        # ---- auxiliary detector / estimator families (Impact-Pack / ReActor / cnet-aux)
        # Ultralytics / YOLO: bbox vs segm split
        for bbox_name in ("face_yolov8n.pt", "hand_yolov8s.pt", "person_yolov8m.pt",
                          "yolov11-face.pt", "yolov5n-face.pt", "yolo11n.pt"):
            self.assertEqual(ms.classify_by_filename(bbox_name), "ultralytics/bbox",
                             bbox_name)
        for segm_name in ("person_yolov8m-seg.pt", "deepfashion2_yolov8s-seg.pt",
                          "yolov8n-segm.pt"):
            self.assertEqual(ms.classify_by_filename(segm_name), "ultralytics/segm",
                             segm_name)
        # SAM (Segment Anything)
        for sam_name in ("sam_vit_b_01ec64.pth", "sam_vit_h_4b8939.pth",
                         "sam_vit_l_0b3195.pth", "mobile_sam.pt", "sam2_hiera_large.pt"):
            self.assertEqual(ms.classify_by_filename(sam_name), "sams", sam_name)
        # BiSeNet / ParseNet face-parsing
        self.assertEqual(ms.classify_by_filename("parsing_parsenet.pth"), "facedetection")
        self.assertEqual(ms.classify_by_filename("parsing_bisenet.pth"), "facedetection")
        # OpenPose / DWPose estimators
        self.assertEqual(ms.classify_by_filename("body_pose_model.pth"), "controlnet_aux")
        self.assertEqual(ms.classify_by_filename("hand_pose_model.pth"), "controlnet_aux")
        self.assertEqual(ms.classify_by_filename("dwpose.pth"), "controlnet_aux")
        # ESRGAN-family upscalers, incl. arch-unknown 4x/2x/x4 .pth files
        self.assertEqual(ms.classify_by_filename("4x-ClearRealityV1.pth"),
                         "upscale_models")
        self.assertEqual(ms.classify_by_filename("4x_foolhardy_Remacri.pth"),
                         "upscale_models")
        self.assertEqual(ms.classify_by_filename("RealESRGAN_x4plus.pth"),
                         "upscale_models")
        self.assertEqual(ms.classify_by_filename("2x_APISR_RRDB.pth"), "upscale_models")
        # conservative: a plain checkpoint / size tag is NOT swept into upscale
        self.assertIsNone(ms.classify_by_filename("dreamshaper_8.safetensors"))
        self.assertIsNone(ms.classify_by_filename("sdxl_base_1.0.safetensors"))

        self.assertEqual(ms.classify_gguf({"general.architecture": "wan"}),
                         "diffusion_models")
        self.assertEqual(ms.classify_gguf({"general.architecture": "t5"}),
                         "text_encoders")
        # heuristics 9: plain-LLM GGUFs are `llm` by role, not unclassified
        self.assertEqual(ms.classify_gguf({"general.architecture": "qwen2"}),
                         "llm")
        self.assertEqual(ms.classify_gguf({"general.architecture": "brandnew"}),
                         "unclassified")

        self.assertEqual(ms.classify_config({"architectures": ["T5EncoderModel"]}),
                         "text_encoders")
        self.assertEqual(ms.classify_config({"architectures": ["AutoencoderKL"]}),
                         "vae")
        # v2: HF LLM repos are `llm`, not unclassified
        self.assertEqual(ms.classify_config({"architectures": ["Qwen2ForCausalLM"]}),
                         "llm")
        self.assertIsNone(ms.classify_config({"architectures": ["SomethingNew"]}))

    # --------------------------------------------------------- misc robustness
    def test_missing_models_dir_is_silently_skipped(self):
        # fx.models never created; cache has one file
        self.fx.add_hf_file("acme/solo", "split_files/vae/solo.safetensors",
                            safetensors_bytes(["x.weight"]))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), {"vae/solo.safetensors"})

    def test_registry_lost_means_orphans_not_clobbers(self):
        populate_standard(self.fx)
        self.fx.sync()
        self.fx.registry.unlink()  # simulate registry loss
        shutil.rmtree(self.fx.cache / "models--acme--flux-dev")
        rc, out = self.fx.sync()
        # the now-sourceless link is ORPHANED (treated as user's), never removed
        self.assertTrue((self.fx.tree / "diffusion_models"
                         / "flux1-dev.safetensors").is_symlink())
        self.assertIn("broken unowned symlink", out)
        # still-valid links are re-adopted without clobbering (they match: "ok")
        self.assertIn("vae/ae.safetensors", tree_links(self.fx.tree))

    def test_v1_registry_migrates_via_heuristics_bump(self):
        ids = populate_raiju(self.fx)
        # simulate the v1 state: old heuristics + the old generic-named link on disk
        blob = (self.fx.cache / "models--black-forest-labs--FLUX.1-Fill-dev"
                / "blobs" / ids["text_encoder"][3:])
        old_link = self.fx.tree / "text_encoders" / "model.safetensors"
        old_link.parent.mkdir(parents=True)
        old_link.symlink_to(blob)
        self.fx.registry.parent.mkdir(parents=True, exist_ok=True)
        self.fx.registry.write_text(yaml.safe_dump({
            "version": 1, "heuristics": 1,
            "entries": {ids["text_encoder"]: {
                "origin": "hf", "category": "text_encoders",
                "source": str(blob),
                "display": ("black-forest-labs/FLUX.1-Fill-dev/"
                            "text_encoder/model.safetensors"),
                "links": ["text_encoders/model.safetensors"],
            }}}))
        rc, out = self.fx.sync()
        self.assertEqual(rc, 0)
        self.assertIn("reclassifying everything", out)
        links = tree_links(self.fx.tree)
        # old generic-named link (ours) was pruned; provenance name took over
        self.assertNotIn("text_encoders/model.safetensors", links)
        self.assertIn("text_encoders/FLUX.1-Fill-dev--text_encoder.safetensors", links)

    def test_default_verb_is_sync_and_help_works(self):
        populate_standard(self.fx)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = ms.main(self.fx.args())  # no verb at all
        self.assertEqual(rc, 0)
        self.assertEqual(tree_links(self.fx.tree), EXPECTED_LINKS)
        with self.assertRaises(SystemExit) as cm:
            with contextlib.redirect_stdout(io.StringIO()):
                ms.main(["--help"])
        self.assertEqual(cm.exception.code, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
