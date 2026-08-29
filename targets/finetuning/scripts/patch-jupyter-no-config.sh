#!/usr/bin/env bash
# patch-jupyter-no-config.sh — make JUPYTER_NO_CONFIG skip the USER'S config without
# also discarding DROSTE'S baked defaults. BUILD-TIME ONLY; run from
# targets/Container.finetuning.
#
# ⭐ WHAT IT CHANGES, AND WHY ONE LINE IS THE WHOLE FIX. jupyter_core has two separate
# short-circuits on JUPYTER_NO_CONFIG:
#
#   paths.py:153  jupyter_config_dir()  -> a throwaway temp dir. This is the one that
#                 excludes the USER'S /opt/data/jupyter_server_config.py, and it is
#                 exactly what the setting is supposed to do. LEAVE IT ALONE.
#   paths.py:392  jupyter_config_path() -> `return [jupyter_config_dir()]`, i.e. the
#                 whole search path collapses to that temp dir. That also throws away
#                 /etc/jupyter, where droste states its own trait defaults — so the box
#                 would silently fall back to whatever upstream happens to default to,
#                 for ~40 traits, on a setting a user reached for to skip THEIR config.
#
# So the substitution is `return [jupyter_config_dir()]`
#                     -> `return [jupyter_config_dir(), *SYSTEM_CONFIG_PATH]`
# SYSTEM_CONFIG_PATH is a module global in that same file (no import to add).
#
# 🧪 MEASURED on the pin (jupyter_core 5.8.1), all three cases:
#   stock,   JUPYTER_NO_CONFIG=1  ->  ['/tmp/jupyter-clean-cfg-XXXX']
#   patched, JUPYTER_NO_CONFIG=1  ->  ['/tmp/jupyter-clean-cfg-XXXX', '/usr/local/etc/jupyter', '/etc/jupyter']
#   patched, variable unset       ->  byte-identical to stock with it unset
# The third case is the one that matters most and this script RE-MEASURES it every build:
# the normal path must not move at all.
#
# ⚠️ SYSTEM_CONFIG_PATH ONLY, NOT ENV_CONFIG_PATH. /opt/venv/etc/jupyter holds third-party
# extension-enablement JSONs, which are a package's own installation state rather than
# somebody's configuration; "skip config" arguably should still skip those. Adding it is a
# one-word change to PATCHED below, and it would need a matching note in the baked
# /etc/jupyter/jupyter_server_config.py.
#
# 🚨 THE ANCHOR GUARD IS THE POINT OF THIS BEING A SCRIPT. A pin bump that reflows that
# return statement must BREAK THE BUILD, not quietly restore all-or-nothing behaviour —
# which nothing downstream would notice, because every failure mode here is "the server
# starts and the traits are wrong".
#
# ⚠️ WHAT IT CANNOT DEFEND AGAINST: a user pip-installing jupyter_core inside the box
# writes a fresh, unpatched paths.py into the venv overlay's upper layer. Re-running this
# script in the box repairs that; there is no build-time guard for it.
#
# Usage: patch-jupyter-no-config.sh [path/to/jupyter_core/paths.py]
set -euo pipefail

PYTHON=${PYTHON:-/opt/venv/bin/python}

die() { printf 'patch-jupyter-no-config: ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'patch-jupyter-no-config: %s\n' "$*" >&2; }

TARGET=${1:-}
if [ -z "$TARGET" ]; then
    TARGET=$("$PYTHON" -c 'import jupyter_core.paths as p; print(p.__file__)' 2>/dev/null) \
        || die "cannot locate jupyter_core.paths with $PYTHON"
fi
[ -r "$TARGET" ] && [ -w "$TARGET" ] || die "$TARGET is not readable and writable"

ANCHOR='        return [jupyter_config_dir()]'
PATCHED='        return [jupyter_config_dir(), *SYSTEM_CONFIG_PATH]'

# ── guards BEFORE ────────────────────────────────────────────────────────────
# ⚠️ -F and -x together: an EXACT WHOLE LINE, so neither the brackets nor the leading
# indentation is at the mercy of a regex, and a longer line that merely contains the
# anchor cannot be counted.
before_anchor=$(grep -Fxc -- "$ANCHOR" "$TARGET" || true)
before_patched=$(grep -Fxc -- "$PATCHED" "$TARGET" || true)
# ⚠️ ORDER MATTERS FOR THE MESSAGE, not for the outcome. An already-patched file has
# ZERO anchors, so testing the anchor first would report "the pin has moved" at somebody
# who simply ran this twice — and send them re-deriving an anchor that is perfectly fine.
[ "$before_patched" = "0" ] || die \
    "$TARGET already contains the patched line ($before_patched occurrence(s)) — refusing to patch twice."
[ "$before_anchor" = "1" ] || die \
    "expected exactly 1 occurrence of the anchor in $TARGET, found $before_anchor. The jupyter_core pin has moved and that return statement has been reflowed or renamed — re-derive the anchor from the new source before touching this."
grep -Eqc '^ {0,4}SYSTEM_CONFIG_PATH = ' "$TARGET" || die \
    "SYSTEM_CONFIG_PATH is not assigned at module level in $TARGET — the replacement would reference an undefined name."

# ── the normal path, measured before the change ──────────────────────────────
# stdout only: jupyter_core writes a platformdirs DeprecationWarning to stderr.
unset_before=$("$PYTHON" -c \
    'from jupyter_core.paths import jupyter_config_path as f; print(f())' 2>/dev/null) \
    || die "could not evaluate jupyter_config_path() before patching"

# ── substitute ───────────────────────────────────────────────────────────────
# ⭐ awk on EXACT LINE EQUALITY, not sed: the anchor is full of regex metacharacters
# ([, ], (, )) and the replacement contains a `*`. Nothing here is a pattern.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
awk -v a="$ANCHOR" -v r="$PATCHED" '
    $0 == a { print r; n = n + 1; next }
    { print }
    END { if (n != 1) exit 3 }
' "$TARGET" >"$tmp" || die "the substitution replaced a number of lines other than 1"

# Write THROUGH the existing file rather than moving over it, so ownership, mode and the
# group-writable bits the venv carries are all untouched.
cat "$tmp" >"$TARGET"

# ── guards AFTER ─────────────────────────────────────────────────────────────
after_anchor=$(grep -Fxc -- "$ANCHOR" "$TARGET" || true)
after_patched=$(grep -Fxc -- "$PATCHED" "$TARGET" || true)
[ "$after_anchor" = "0" ] || die "the anchor survived the substitution ($after_anchor left)"
[ "$after_patched" = "1" ] || die "expected exactly 1 patched line, found $after_patched"

# ── behaviour, measured ──────────────────────────────────────────────────────
# Delete any stale bytecode first: an overlay upper can hold a .pyc newer than the source
# we just rewrote, and the import would then not see the change.
find "$(dirname "$TARGET")" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

unset_after=$("$PYTHON" -c \
    'from jupyter_core.paths import jupyter_config_path as f; print(f())' 2>/dev/null) \
    || die "jupyter_config_path() no longer evaluates after patching"
[ "$unset_before" = "$unset_after" ] || die \
    "the NORMAL search path changed, which this patch must never do: before=$unset_before after=$unset_after"

skipped=$(JUPYTER_NO_CONFIG=1 "$PYTHON" -c \
    'from jupyter_core.paths import jupyter_config_path as f; print(f())' 2>/dev/null) \
    || die "jupyter_config_path() failed with JUPYTER_NO_CONFIG=1"
case "$skipped" in
    *"/etc/jupyter"*) ;;
    *) die "with JUPYTER_NO_CONFIG=1 the search path still omits the system dirs: $skipped" ;;
esac

note "patched $TARGET"
note "  normal search path unchanged:      $unset_after"
note "  with JUPYTER_NO_CONFIG=1 now:      $skipped"
