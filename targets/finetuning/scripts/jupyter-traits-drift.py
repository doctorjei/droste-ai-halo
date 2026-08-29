#!/usr/bin/env python3
"""jupyter-traits-drift.py — DEV-TIME drift report for droste's baked Jupyter traits.

⭐ WHY THIS EXISTS. /etc/jupyter/jupyter_server_config.py states droste's default for
every trait the user's config surface offers, and every value in it equals the upstream
default AT THE PINS. That is deliberate — it makes a commented line in the user's file
mean exactly one thing, "droste's default" — but it converts a TRACKING default into a
PINNED one. The moment jupyter_server, jupyterlab or traitlets moves, a baked value that
upstream has changed silently keeps this box on the old behaviour, and nothing about the
build says so: the file still parses, the server still starts, the trait still exists.

There is a second failure it catches, and it is the quieter one. A trait upstream has
RENAMED or REMOVED does not fail — traitlets only WARNS about an unknown trait in a
config file, and the server comes up healthy with the setting ignored. On a box whose
service log goes to /opt/data/.droste-serve.log rather than `podman logs`, nobody sees it.

⚠️ RUN IT WHEN A PIN MOVES, not on a schedule. The pins are in
targets/Container.finetuning: jupyter_core, jupyterlab, jupyter_server, jupyterlab_server,
traitlets. jupyter_client is NOT pinned there and floats.

⚠️ IT MUST RUN INSIDE THE BOX. It answers "what do the INSTALLED packages default to",
which is a question only the image can answer:

    podman exec droste-finetuning-halo jupyter-traits-drift.py

Exit status is 0 when nothing needs attention and 1 when something does, so it can gate a
bump. A row it cannot resolve is reported and counted as needing attention — "I could not
tell" is not "it is fine".
"""

from __future__ import annotations

import argparse
import re
import sys
from typing import Any

from traitlets import Undefined
from traitlets.config.configurable import Configurable
from traitlets.config.loader import Config
from traitlets.utils.importstring import import_item

DEFAULT_CONFIG = "/etc/jupyter/jupyter_server_config.py"
DEFAULT_TEMPLATE = "/opt/resources/templates/jupyter_server_config.py"

# Matches the way the user's template names a trait in a commented line:
#   # c.ServerApp.max_body_size = 536870912
# and the way the baked file names an unbaked one in its NOT BAKED section:
#   #   ServerApp.allow_remote_access
TRAIT_RE = re.compile(r"\bc\.([A-Z]\w*)\.(\w+)\s*=")
NAMED_RE = re.compile(r"\b([A-Z]\w*)\.(\w+)\b")


def build_class_index() -> dict[str, list[type]]:
    """Every Configurable reachable from the server and the Lab app, by bare name.

    ⭐ DISCOVERED, NOT LISTED. A hand-written {name: import path} map is a second place
    to forget to update, and it would report a class upstream RENAMED as "unknown" for
    the wrong reason. Importing the two apps drags in every Configurable they can be
    configured with; walking Configurable's subclass tree then finds them all.
    """
    import jupyter_server.serverapp  # noqa: F401
    import jupyterlab.labapp  # noqa: F401

    seen: set[type] = set()

    def walk(cls: type) -> None:
        for sub in cls.__subclasses__():
            if sub not in seen:
                seen.add(sub)
                walk(sub)

    walk(Configurable)
    seen.add(Configurable)

    index: dict[str, list[type]] = {}
    for cls in seen:
        index.setdefault(cls.__name__, []).append(cls)
    return index


def load_config(path: str) -> Config:
    """Execute the config file the way traitlets does, and hand back what it built."""
    cfg = Config()
    namespace: dict[str, Any] = {"get_config": lambda: cfg, "__file__": path}
    with open(path) as fh:
        source = fh.read()
    exec(compile(source, path, "exec"), namespace)  # noqa: S102
    return cfg


def upstream_default(cls: type, name: str) -> tuple[str, Any]:
    """Return (kind, value) for a trait's upstream default.

    kind is "static" for a literal, "container" for one traitlets rebuilds per instance,
    or "dynamic" for one computed by an @default generator. A dynamic default is REPORTED
    rather than compared: it is the thing a literal cannot stand in for, and the baked
    file excludes every trait that has one. Finding a new one here means upstream turned
    a literal into a computation — drift of exactly the kind this report is for.
    """
    trait = cls.class_traits()[name]
    if name in getattr(cls, "_trait_default_generators", {}):
        return "dynamic", None
    make = getattr(trait, "make_dynamic_default", None)
    if make is not None:
        # ⚠️ NOT a callable factory despite the name — traitlets' Container/Dict traits
        # BUILD AND RETURN the value here. Calling the result is a TypeError.
        value = make()
        if value is not None:
            return "container", value
    return "static", trait.default_value


def normalize(cls: type, name: str, value: Any) -> Any:
    """Put OUR value in the same terms as upstream's default before comparing.

    ⚠️ ONE CASE, AND IT IS NOT COSMETIC: a `Type` trait's default is a CLASS, while a
    config file must give it as a dotted string (importing the class at the top of a
    config file would run for every `jupyter` command in the box). Comparing the two
    raw reports drift on a pair that is identical, which is the noise that makes a
    report get ignored.
    """
    trait = cls.class_traits()[name]
    if type(trait).__name__ == "Type" and isinstance(value, str):
        try:
            return import_item(value)
        except Exception:  # noqa: BLE001
            return value
    return value


def main() -> int:
    ap = argparse.ArgumentParser(description="drift report for droste's baked Jupyter traits")
    ap.add_argument("--config-file", default=DEFAULT_CONFIG, help=f"default: {DEFAULT_CONFIG}")
    ap.add_argument(
        "--template",
        default=DEFAULT_TEMPLATE,
        help=f"the user-facing template to cross-check against (default: {DEFAULT_TEMPLATE})",
    )
    ap.add_argument("--no-template", action="store_true", help="skip the template cross-check")
    args = ap.parse_args()

    try:
        cfg = load_config(args.config_file)
    except OSError as exc:
        print(f"jupyter-traits-drift: cannot read the baked config: {exc}", file=sys.stderr)
        return 1

    index = build_class_index()

    print("pins as installed:")
    for mod in ("jupyter_core", "jupyter_server", "jupyterlab", "jupyterlab_server", "traitlets"):
        try:
            print(f"  {mod:<18} {__import__(mod).__version__}")
        except Exception as exc:  # noqa: BLE001
            print(f"  {mod:<18} <unreadable: {exc}>")
    print(f"\nbaked config: {args.config_file}\n")

    ok = 0
    problems: list[str] = []
    baked: set[tuple[str, str]] = set()

    for section in sorted(cfg):
        classes = index.get(section)
        for name in sorted(cfg[section]):
            baked.add((section, name))
            ours = cfg[section][name]
            label = f"{section}.{name}"
            if not classes:
                problems.append(f"UNKNOWN CLASS   {label} — no Configurable by that name is installed")
                continue
            if len(classes) > 1:
                mods = ", ".join(sorted(c.__module__ for c in classes))
                problems.append(f"AMBIGUOUS       {label} — {len(classes)} classes share the name ({mods})")
                continue
            cls = classes[0]
            if name not in cls.class_traits():
                problems.append(
                    f"UNKNOWN TRAIT   {label} — the class exists, the trait does not "
                    "(renamed or removed upstream; traitlets only WARNS about this at start)"
                )
                continue
            kind, theirs = upstream_default(cls, name)
            ours = normalize(cls, name, ours)
            if kind == "dynamic":
                problems.append(
                    f"NOW DYNAMIC     {label} — upstream computes this default now, so our "
                    "literal overrides the computation. Move it to the NOT BAKED section."
                )
                continue
            if theirs is Undefined:
                problems.append(f"UNRESOLVED      {label} — upstream default is Undefined; check by hand")
                continue
            if theirs != ours:
                problems.append(f"DRIFT           {label} — baked {ours!r}, upstream now {theirs!r}")
                continue
            ok += 1

    if not args.no_template:
        try:
            with open(args.template) as fh:
                text = fh.read()
        except OSError as exc:
            print(f"template cross-check SKIPPED: {exc}\n")
        else:
            wanted = set(TRAIT_RE.findall(text))
            with open(args.config_file) as fh:
                baked_text = fh.read()
            # A trait the baked file deliberately does NOT set names itself in prose;
            # treat being named anywhere in that file as "accounted for".
            named = set(NAMED_RE.findall(baked_text))
            missing = sorted(w for w in wanted if w not in baked and w not in named)
            for section, name in missing:
                problems.append(
                    f"NOT ACCOUNTED   {section}.{name} — the user's template offers it, the "
                    "baked file neither sets it nor explains why it is excluded"
                )

    for line in problems:
        print(line)
    if problems:
        print()
    print(f"{ok} baked trait(s) still agree with upstream; {len(problems)} need attention")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
