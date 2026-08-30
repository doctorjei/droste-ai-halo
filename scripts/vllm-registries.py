#!/usr/bin/env python3
"""vllm-registries.py — DEV-TIME drift report for vLLM's two OPEN registries.

Re-derives the built-in members of `VIDEO_LOADER_REGISTRY` and
`MEDIA_CONNECTOR_REGISTRY` from the PINNED vLLM source and compares them against
the three places we assert them:

  * `VLLM_VIDEO_LOADER_BUILTINS` / `VLLM_MEDIA_CONNECTOR_BUILTINS` in
    targets/vllm/build-spec   — what PRE_LAUNCH warns against
  * the `# {a*, b, c}` menu comments in targets/vllm/templates/vllm.cfg
    — what the user is told

Run it when VLLM_REF moves in scaffolding/Container.vllm-build. The output is a
work list; nothing here writes anything.

⭐ WHY AT DEV TIME AND NOT AT BUILD TIME. Asking the registry itself means
IMPORTING vllm, which needs the GPU stack and takes the failure mode of
`gen_llama_env.sh` — a build on a GPU-less runner that degrades silently. The
registrations are decorators, so the SOURCE answers the same question with an AST
walk and no import at all.

⭐ WHY IT READS THE REGISTRATION SITES AND NOT THE COMMENTS. Upstream's own comment
above VLLM_VIDEO_LOADER_BACKEND (vllm/envs.py) documents "opencv" and "identity".
At v0.16.0 `identity` is registered NOWHERE, while `opencv_dynamic` and `molmo2`
are — so the prose names a backend that does not exist and misses two that do. An
earlier pass copied that comment into vllm.cfg as `{opencv*}` and shipped it. A
comment describing the default is not an enumeration of the choices.

🚨 IT CANNOT WRITE ANY FILE, BY CONSTRUCTION — there is no output path and no write
mode. vllm.cfg and the build-spec are authored, reviewed files; this reports what
disagrees so a human can decide, and it is not a gate (it always exits 0).

⚠️ WHAT IT DOES NOT DO. It finds registrations in the two modules that hold them
today. A registration moved to a third module, or built by a loop rather than a
decorator, is invisible to it — if a list comes back EMPTY, suspect this tool
before concluding upstream deleted a backend.

Usage:
  vllm-registries.py [--src DIR] [--ref REF] [--list]

  --src DIR   a vLLM checkout or unpacked sdist to read instead of fetching
  --ref REF   git ref to fetch from GitHub (default: VLLM_REF in the build file)
  --list      print the derived lists and stop
"""

import argparse
import ast
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, os.pardir)
BUILD_FILE = os.path.join(REPO, "scaffolding", "Container.vllm-build")
SPEC = os.path.join(REPO, "targets", "vllm", "build-spec")
ENVF = os.path.join(REPO, "targets", "vllm", "templates", "vllm.cfg")
RAW = "https://raw.githubusercontent.com/vllm-project/vllm/{ref}/{path}"

# registry variable -> (module holding the registrations, our spec array, the
# native environment variable the user sets)
REGISTRIES = {
    "VIDEO_LOADER_REGISTRY": (
        "vllm/multimodal/video.py",
        "VLLM_VIDEO_LOADER_BUILTINS",
        "VLLM_VIDEO_LOADER_BACKEND",
    ),
    "MEDIA_CONNECTOR_REGISTRY": (
        "vllm/multimodal/media/connector.py",
        "VLLM_MEDIA_CONNECTOR_BUILTINS",
        "VLLM_MEDIA_CONNECTOR",
    ),
}


def note(msg):
    print(f"vllm-registries: {msg}", file=sys.stderr)


def pinned_ref():
    """The VLLM_REF the toolbox builds, read from the build file rather than typed.

    ⭐ The pin has exactly one home. Hardcoding it here would create a second one
    that nobody updates, which is the failure this report exists to catch.
    """
    try:
        with open(BUILD_FILE) as fh:
            text = fh.read()
    except OSError as exc:
        raise SystemExit(f"cannot read {BUILD_FILE}: {exc}")
    m = re.search(r"^ARG\s+VLLM_REF=(\S+)", text, re.M)
    if not m:
        raise SystemExit(f"{BUILD_FILE}: no `ARG VLLM_REF=` line — has the pin moved?")
    return m.group(1)


def read_source(path, src_dir, ref):
    if src_dir:
        full = os.path.join(src_dir, path)
        try:
            with open(full) as fh:
                return fh.read(), full
        except OSError as exc:
            raise SystemExit(f"cannot read {full}: {exc}")
    url = RAW.format(ref=ref, path=path)
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            return resp.read().decode("utf-8"), url
    except Exception as exc:  # noqa: BLE001 — any failure is the same advice
        raise SystemExit(
            f"cannot fetch {url}: {exc}\n"
            "Pass --src with a vLLM checkout if this machine has no network."
        )


def registered_names(source, registry, where):
    """Every name registered via `@<registry>.register("name")`, in source order.

    ⚠️ An AST walk, not a regex: a decorator inside a docstring or an example in a
    comment must not count, and `register` on some OTHER object must not either.
    """
    tree = ast.parse(source, filename=where)
    names = []
    for node in ast.walk(tree):
        for deco in getattr(node, "decorator_list", []):
            if not isinstance(deco, ast.Call):
                continue
            func = deco.func
            if not isinstance(func, ast.Attribute) or func.attr != "register":
                continue
            if not isinstance(func.value, ast.Name) or func.value.id != registry:
                continue
            if not deco.args:
                continue
            arg = deco.args[0]
            if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                names.append((arg.value, getattr(deco, "lineno", 0)))
    return names


def spec_array(name):
    """The literal members of a `NAME=( a b c )` array in the build-spec."""
    try:
        with open(SPEC) as fh:
            text = fh.read()
    except OSError as exc:
        raise SystemExit(f"cannot read {SPEC}: {exc}")
    m = re.search(rf"^{re.escape(name)}=\(([^)]*)\)", text, re.M)
    if not m:
        return None
    return [w for w in m.group(1).split() if w]


def env_menu(var):
    """The `# {a*, b, c}` menu comment that sits above a setting in vllm.cfg.

    Returns the members with any `*` default marker stripped, or None if the
    setting has no menu comment. The surface may spell the setting with either the
    native name or a DROSTE_ one, so the search is for a menu comment followed by
    a line naming the variable — with the DROSTE_ spelling matched by its distinct
    suffix, since the two names are not the same string.
    """
    try:
        with open(ENVF) as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        raise SystemExit(f"cannot read {ENVF}: {exc}")
    # `VLLM_VIDEO_LOADER_BACKEND` is spelled `DROSTE_VLLM_VIDEO_LOAD_BACKEND` on the
    # surface; match on a trailing fragment so either spelling is found.
    tail = var.replace("VLLM_", "", 1).replace("LOADER_BACKEND", "LOAD_BACKEND")
    menu = None
    for line in lines:
        m = re.match(r"^#\s*\{(.+)\}\s*$", line.strip())
        if m:
            menu = m.group(1)
            continue
        if re.match(r"^#?\s*\w*" + re.escape(tail) + r"=", line.strip()):
            if menu is None:
                return None
            return [w.strip().rstrip("*") for w in menu.split(",") if w.strip()]
        if line.strip() and not line.strip().startswith("#"):
            menu = None
    return None


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--src")
    ap.add_argument("--ref")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    args = ap.parse_args(argv)
    if args.help:
        print(__doc__)
        return 0

    ref = args.ref or pinned_ref()
    if not args.src:
        note(f"reading vLLM at {ref}")

    problems = 0
    for registry, (path, array, var) in REGISTRIES.items():
        source, where = read_source(path, args.src, ref)
        found = registered_names(source, registry, where)
        upstream = [n for n, _ in found]

        if not upstream:
            note(
                f"{registry}: NO registrations found in {path}. Suspect this tool "
                "(a moved module, or registration by something other than a "
                "decorator) before concluding upstream removed them all."
            )
            problems += 1
            continue

        if args.list:
            print(f"{registry}  ({var})")
            for name, line in found:
                print(f"    {name:<20} {path}:{line}")
            continue

        ours = spec_array(array)
        if ours is None:
            note(f"{array} not found in {SPEC} — the warning has nothing to compare against")
            problems += 1
        elif sorted(ours) != sorted(upstream):
            note(
                f"{array} disagrees with {path}:\n"
                f"    build-spec: {', '.join(ours)}\n"
                f"    upstream:   {', '.join(upstream)}\n"
                f"    -> edit the array in {SPEC}"
            )
            problems += 1

        shown = env_menu(var)
        if shown is None:
            note(f"{var}: no `# {{...}}` menu comment in vllm.cfg — nothing tells the user the choices")
            problems += 1
        elif sorted(shown) != sorted(upstream):
            note(
                f"{var}: the menu shown in vllm.cfg disagrees with {path}:\n"
                f"    vllm.cfg:  {', '.join(shown)}\n"
                f"    upstream:  {', '.join(upstream)}\n"
                f"    -> the config file is the user's surface and is authored by hand; "
                f"take this to whoever owns it, do not edit it from a script"
            )
            problems += 1

    if args.list:
        return 0
    note(f"{problems} item(s) need a decision")
    # A report a human acts on, not a gate.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
