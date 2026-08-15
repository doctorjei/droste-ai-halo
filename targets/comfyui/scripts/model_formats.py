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
  * the key-signature RULES themselves (tensor names -> what the file is). Both sides
    genuinely share this knowledge -- `control_model.`, `controlnet_cond_embedding.`,
    `first_stage_model.`, `double_blocks.`/`joint_blocks.` appear in both -- but they
    map it to DIFFERENT vocabularies: ComfyUI category dirs on the scanner side,
    CivitAI model types / base-model families on the adopt side. Sharing them is a
    genuine improvement and a genuine BEHAVIOUR change, so it is a decision to be taken
    on purpose and not a side effect of a file move. This module is where it should
    land when it is taken.
"""

from __future__ import annotations

import pickle
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
