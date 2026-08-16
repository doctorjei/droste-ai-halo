#!/usr/bin/env python3
"""apply_templates.py — seed baked default files into runtime locations.

Shared template applier baked into the runtime base image. Reads a manifest
``templates.yaml`` in the templates directory and applies two seeding rules.

RESTRICTED YAML SUBSET (intentional — NO pyyaml dependency in the lean base):
This parser understands ONLY this exact shape, and keeps the ``.yaml`` extension
so it can be swapped for a real YAML loader later without touching callers:

    # comment lines and blank lines are ignored
    if_empty:
      src_dir: /absolute/dest/dir
    if_missing:
      src_file.yaml: /absolute/dest/file.yaml

  * Exactly two top-level keys: ``if_empty`` and ``if_missing`` (either may be
    absent). Each is a FLAT one-level map of ``src: dest``.
  * ``src`` is relative to the templates directory (this script's argv[1]).
  * ``dest`` is an absolute path.
  * ``#`` full-line comments and blank lines are ignored. No nesting, no lists,
    no quoting, no inline structures.

SEMANTICS:
  if_empty   — copy src (dir or file) into dest IFF dest is a COMPLETELY EMPTY
               directory. "Empty" = no entries at all (dotfiles count as content).
               A missing dest counts as empty (created). Any entry → skip.
  if_missing — copy src to dest IFF dest does NOT exist. Never overwrites.

Copies preserve tree structure (shutil.copytree/copy2). Idempotent; prints one
line per action, silent when there is nothing to do.

OWNERSHIP (``--owner <user>``, optional):
Seeding runs as ROOT in both lanes (the server ENTRYPOINT is root; so is the
distrobox init hook). Without this flag every seeded config therefore lands owned
by the CONTAINER's root — which under rootless podman is a subuid on the host
(uid 100000 with the usual mapping), so the user cannot edit the very files the
docs hand them ("after first start they are yours to edit"). With it, everything
this run CREATES is chowned to <user> and their PRIMARY group — the same shape as
the resolver's `chown "$DROSTE_USER:"` idiom.

WHY THE CHOWN LIVES HERE AND NOT IN THE SHELL CALLER: only this script knows
exactly what it created — a whole tree for ``if_empty``, one file (plus any parent
dirs it had to make) for ``if_missing`` — and precision is the whole requirement.
Nothing else is ever touched: a dest DIRECTORY that already existed keeps its
ownership (it is routinely the user's own bind, e.g. comfyui's /opt/ComfyUI/input),
a dest that already existed is never copied over in the first place, and no chown
is recursive over anything but the copy that just happened. The CALLER decides
WHETHER to pass the flag — lane policy belongs with the resolver's other lane
deviations, not in here.

Exit status: 0 on success or no-op (a missing manifest is fine). Nonzero only on
real errors (e.g. a manifest src that does not exist). A failed chown is NOT one
of them: it warns and continues, exactly as resolve::_own_dirs does — a seed the
user has to chown by hand still beats a container that refuses to start.
"""

import argparse
import os
import pwd
import shutil
import sys

TOOL = "apply_templates"
SECTIONS = ("if_empty", "if_missing")


def warn(msg):
    print(f"{TOOL}: {msg}", file=sys.stderr)


def parse_manifest(path):
    """Parse the restricted-subset manifest into {section: {src: dest}}."""
    sections = {name: {} for name in SECTIONS}
    current = None
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if not line[0].isspace():
                # top-level key, e.g. "if_empty:"
                key = stripped.rstrip(":").strip()
                if key not in sections:
                    raise ValueError(
                        f"{path}:{lineno}: unknown top-level key '{key}' "
                        f"(expected one of {', '.join(SECTIONS)})"
                    )
                current = key
                continue
            # indented "src: dest" entry
            if current is None:
                raise ValueError(f"{path}:{lineno}: entry before any section header")
            if ":" not in stripped:
                raise ValueError(f"{path}:{lineno}: expected 'src: dest', got '{stripped}'")
            src, _, dest = stripped.partition(":")
            sections[current][src.strip()] = dest.strip()
    return sections


def is_empty_dir(dest):
    """True if dest is missing, or an existing directory with no entries."""
    if not os.path.exists(dest):
        return True
    if os.path.isdir(dest):
        return len(os.listdir(dest)) == 0
    return False  # an existing file is not an empty dir


def owner_ids(owner):
    """(uid, gid) for --owner: the user plus their PRIMARY group.

    Mirrors the shell's `chown "$DROSTE_USER:"` (trailing colon = "and their login
    group"), not _own_dirs' owner-only form: seeded configs carry no baked group or
    setgid intent to preserve, and matching the installer-written server.env beside
    them (user:user) is what makes the whole config dir read as the user's.
    A numeric owner is accepted for the DROSTE_USER override case. Raises KeyError
    if the user does not exist here; the caller degrades to "no chown" on that.
    """
    try:
        ent = pwd.getpwnam(owner)
    except KeyError:
        if not owner.isdigit():
            raise
        ent = pwd.getpwuid(int(owner))
    return ent.pw_uid, ent.pw_gid


def chown_created(paths, ids):
    """Give the paths this run created to (uid, gid). Best effort, see below."""
    if ids is None:
        return
    uid, gid = ids
    for path in paths:
        try:
            # Already-right is a no-op, the `! -uid` spirit of resolve::_own_dirs:
            # it keeps a non-root caller (who already owns what it just wrote)
            # silent instead of warning about a chown it never needed.
            st = os.lstat(path)
            if st.st_uid == uid and st.st_gid == gid:
                continue
            # lchown, not chown: a template tree may carry a symlink, and the link
            # itself is what we created — never whatever it points at.
            os.lchown(path, uid, gid)
        except OSError as exc:
            # ONE line, then stop: this fails for the whole pass or for none of it
            # (it is EPERM — the caller is not root), so per-path warnings would be
            # noise. Seeding itself succeeded; say what the user is left with.
            warn(
                f"could not set ownership on {path} ({exc}) — what was just seeded "
                f"stays owned by this process; you may need to chown it by hand."
            )
            return


def copy_tree_or_file(src, dest):
    """Copy src (dir or file) to dest, preserving structure. src must exist.

    Returns the list of paths this call CREATED — the only paths chown_created is
    ever allowed to touch (see OWNERSHIP in the module docstring). For a tree that
    is every entry of src mapped onto dest, plus dest itself IFF we had to make it;
    for a file, the file plus whatever parent components did not exist yet (the
    same "leaf plus what this run created" rule as resolve::_mkuserdir).
    """
    created = []
    if os.path.isdir(src):
        if not os.path.isdir(dest):
            created.append(dest)
        shutil.copytree(src, dest, dirs_exist_ok=True)
        # Enumerate from SRC, not by walking dest: the copied names are exactly the
        # source's names, so this cannot pick up a stray entry that was already in
        # dest — dirs_exist_ok means the caller's emptiness rule is what keeps them
        # apart, and we do not want to depend on that rule from down here.
        for root, dirs, files in os.walk(src):
            base = dest + root[len(src):]   # root always starts with src
            created.extend(os.path.join(base, name) for name in dirs + files)
    elif os.path.isfile(src):
        parent = os.path.dirname(dest)
        if parent:
            # Which parent components does makedirs bring into being THIS run?
            # Walk up while they are absent — those are ours to hand over; the
            # first existing ancestor and everything above it are not touched.
            missing = []
            probe = parent
            while probe and not os.path.exists(probe) and probe != os.path.dirname(probe):
                missing.append(probe)
                probe = os.path.dirname(probe)
            os.makedirs(parent, exist_ok=True)
            created.extend(missing)
        shutil.copy2(src, dest)
        created.append(dest)
    else:
        raise FileNotFoundError(src)
    return created


def apply(templates_dir, ids=None):
    manifest = os.path.join(templates_dir, "templates.yaml")
    if not os.path.isfile(manifest):
        # No manifest is a legitimate no-op.
        return 0

    sections = parse_manifest(manifest)

    # if_empty: seed only into a completely empty (or missing) destination.
    for src, dest in sections["if_empty"].items():
        src_path = os.path.join(templates_dir, src)
        if not os.path.exists(src_path):
            warn(f"if_empty src does not exist: {src_path}")
            return 1
        if not is_empty_dir(dest):
            continue
        chown_created(copy_tree_or_file(src_path, dest), ids)
        print(f"{TOOL}: seeded {dest} from {src} (if_empty)")

    # if_missing: copy only when the destination does not exist. Never overwrite.
    for src, dest in sections["if_missing"].items():
        src_path = os.path.join(templates_dir, src)
        if not os.path.exists(src_path):
            warn(f"if_missing src does not exist: {src_path}")
            return 1
        if os.path.exists(dest):
            continue
        chown_created(copy_tree_or_file(src_path, dest), ids)
        print(f"{TOOL}: created {dest} from {src} (if_missing)")

    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        description="Seed baked default files into runtime locations.")
    parser.add_argument("templates_dir", nargs="?", default="/opt/resources/templates",
                        help="directory holding templates.yaml and the template sources")
    parser.add_argument("--owner", metavar="USER",
                        help="give what this run CREATES to USER and their primary "
                             "group (the resolver passes the box user in the "
                             "distrobox lane; omitted = leave ownership alone)")
    args = parser.parse_args(argv[1:])

    ids = None
    if args.owner:
        try:
            ids = owner_ids(args.owner)
        except (KeyError, ValueError):
            # Same posture as resolve::_own_dirs' unresolvable-uid branch: say so
            # and seed anyway, rather than withholding the user's config files.
            warn(f"--owner '{args.owner}' is not a user here — seeding without a "
                 f"chown; the seeded files stay owned by this process.")

    try:
        return apply(args.templates_dir, ids)
    except (ValueError, OSError) as exc:
        warn(str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
