#!/usr/bin/env bash
# assemble-droste-setup.sh — emit the single-file droste-setup.sh on STDOUT.
#
# WHAT IT IS. droste-setup.sh is assembled, not authored: its sources live in
# installer/ and this script concatenates them in the order installer/MANIFEST
# gives. It is deliberately boring — a `cat` with guards — because the artifact
# is proven by `assemble | cmp - droste-setup.sh` and a build step clever enough
# to transform anything is a build step clever enough to be wrong.
#
# STDOUT IS THE PRODUCT. Nothing lands anywhere unless the caller redirects:
#
#   scripts/assemble-droste-setup.sh > droste-setup.sh     # CI, release asset
#   scripts/assemble-droste-setup.sh --ref main | bash     # run a ref directly
#   scripts/assemble-droste-setup.sh | cmp - droste-setup.sh
#
# The interview still works down a pipe because the prompt layer opens the
# terminal on its own fd (`exec {ASK_FD}</dev/tty`) rather than reading answers
# from stdin.
#
# SILENT ON SUCCESS. Not "diagnostics go to stderr" — no non-error output at
# all. That makes "anything on stderr means something went wrong" trivially
# true rather than a convention every future edit has to remember, and it is
# testable in one line: `assemble 2>&1 >/dev/null` must be empty. There is
# deliberately no --verbose and no --quiet; adding one reintroduces exactly the
# bug class the silence eliminates.
#
# BUFFERED. A pipe means a half-finished assembly has already fed a truncated
# script to bash. The whole artifact is built and checked before a single byte
# reaches stdout.
#
# Usage: assemble-droste-setup.sh [--ref <branch|tag|sha>]
set -euo pipefail

SELF=$(basename "$0")
die() { printf '%s: %s\n' "$SELF" "$*" >&2; exit 1; }

REF=""
REFETCH=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --ref)        [[ $# -ge 2 ]] || die "--ref needs a branch, tag or sha"; REF=$2; shift 2 ;;
    --ref=*)      REF=${1#*=}; shift ;;
    --no-refetch) REFETCH=0; shift ;;   # internal: set on the re-exec below
    -h|--help)    sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//' ; exit 0 ;;
    *)            die "unknown option: $1" ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/.." && pwd)

TMP=""
cleanup() { [[ -n $TMP ]] && rm -rf "$TMP"; }
trap cleanup EXIT

# ── --ref: assemble a ref instead of the working tree ────────────────────────
# The fetched copy of THIS SCRIPT is what assembles the fetched sources. A local
# script older than the ref's manifest format would otherwise mis-assemble it,
# quietly — the artifact would still be a plausible bash file. There is exactly
# one implementation of assembly and this is how it stays that way.
if [[ -n $REF ]]; then
  [[ $REFETCH -eq 1 ]] || die "internal: --ref reached the re-executed copy"
  command -v curl >/dev/null 2>&1 || die "--ref needs curl"
  command -v tar  >/dev/null 2>&1 || die "--ref needs tar"
  TMP=$(mktemp -d)
  url="https://codeload.github.com/doctorjei/droste-ai-halo/tar.gz/$REF"
  curl -fsSL "$url" -o "$TMP/src.tar.gz" \
    || die "could not fetch $REF from $url"
  tar -xzf "$TMP/src.tar.gz" -C "$TMP" --strip-components=1 \
    || die "could not extract the $REF tarball"
  [[ -x $TMP/scripts/$SELF ]] || die "$REF carries no scripts/$SELF"
  exec bash "$TMP/scripts/$SELF" --no-refetch
fi

SRC=$REPO/installer
MANIFEST=$SRC/MANIFEST
[[ -d $SRC      ]] || die "no installer/ directory at $SRC"
[[ -r $MANIFEST ]] || die "cannot read $MANIFEST"

# ── The manifest, and the closed-list check in BOTH directions ───────────────
# An unlisted fragment does not fail — it VANISHES, and the artifact still
# builds and still runs, missing whatever that file defined. So the list and the
# directory are checked against each other, not just the list against disk.
FRAGS=()
while IFS= read -r line; do
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -n $line ]] || continue
  FRAGS+=("$line")
done < "$MANIFEST"

[[ ${#FRAGS[@]} -gt 0 ]] || die "$MANIFEST lists no fragments"

seen=""
for f in "${FRAGS[@]}"; do
  [[ -r $SRC/$f ]] || die "manifest lists $f, which is not readable under installer/"
  case " $seen " in *" $f "*) die "manifest lists $f more than once" ;; esac
  seen="$seen $f"
done

for p in "$SRC"/*.sh; do
  [[ -e $p ]] || continue
  b=$(basename "$p")
  case " $seen " in *" $b "*) ;; *) die "installer/$b is not listed in MANIFEST" ;; esac
done

# ── Embedded Python ──────────────────────────────────────────────────────────
# The two programs the pull runs are real .py files under installer/py/ so an
# editor, a linter and `python3 -m py_compile` can see them; in the artifact
# they are the same quoted heredocs they have always been. A fragment asks for
# one with a directive alone on its line, INSIDE the heredoc it belongs to:
#
#     cat <<'PY'
#   #@embed py/pull_manifest.py
#   PY
#
# Two properties are checked rather than assumed, because both fail silently:
# the heredoc must be QUOTED (an unquoted one would expand a registry-supplied
# `$` at assembly time), and the embedded file must contain no line equal to the
# terminator (a lone `PY` truncates the program, and the result still parses as
# bash and still runs — the pull then breaks pointing nowhere near the cause).
EMBED_RE='^#@embed[[:space:]]+([^[:space:]]+)[[:space:]]*$'
OPEN_RE="<<'([A-Za-z_][A-Za-z0-9_]*)'"
embedded=""

emit_fragment() {   # fragment-name → its assembled text on stdout
  local frag=$1 path=$SRC/$1 line prev="" delim rel py
  if ! grep -qE "$EMBED_RE" "$path"; then
    cat "$path"
    return
  fi
  while IFS= read -r line; do
    if [[ $line =~ $EMBED_RE ]]; then
      rel=${BASH_REMATCH[1]}
      py=$SRC/$rel
      [[ -r $py ]] || die "$frag asks to embed $rel, which is not readable under installer/"
      [[ $prev =~ $OPEN_RE ]] \
        || die "$frag embeds $rel outside a quoted heredoc (the line above must open <<'DELIM')"
      delim=${BASH_REMATCH[1]}
      if grep -qxF "$delim" "$py"; then
        die "$rel contains a line reading exactly '$delim' — it would truncate the program"
      fi
      case " $embedded " in
        *" $rel "*) die "$rel is embedded more than once" ;;
      esac
      embedded="$embedded $rel"
      cat "$py"
      prev=""
      continue
    fi
    printf '%s\n' "$line"
    prev=$line
  done < "$path"
}

TMP=$(mktemp -d)
BUF=$TMP/droste-setup.sh
: > "$BUF"
for f in "${FRAGS[@]}"; do
  emit_fragment "$f" >> "$BUF"
done

for p in "$SRC"/py/*.py; do
  [[ -e $p ]] || continue
  rel="py/$(basename "$p")"
  case " $embedded " in
    *" $rel "*) ;;
    *) die "installer/$rel is embedded by no fragment" ;;
  esac
done

# ── Provenance ───────────────────────────────────────────────────────────────
# A user holding a downloaded droste-setup.sh has no other way to say WHICH one
# they are running, and "the one from the website" is not an answer anyone can
# act on. One comment line fixes that and costs nothing to carry.
#
# 🚨 DERIVED FROM THE TREE, NEVER FROM THE CLOCK. CI asserts two assemblies of
# the same sources are byte-identical, precisely to catch a build step reaching
# for a timestamp, a hostname or a directory order. A commit sha is a property
# of the SOURCES, so it satisfies that check by construction; a date would break
# it, and breaking it would be the check working.
#
# 🚨 ON LINE 2, NOT AT THE END. The shebang must stay on line 1, and the LAST
# line must stay a bare `main` — the g1lab suites source this artifact with the
# final line stripped, and the guarantee below enforces it. Appending the stamp
# was the first thing I tried and it broke that check immediately.
#
# ⚙️ `unknown` when there is no git (a release tarball, a vendored copy), and
# `-dirty` when the tree has uncommitted changes — an artifact built from edits
# that exist on one machine is exactly the case worth flagging.
STAMP=unknown
if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  STAMP=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf unknown)
  git -C "$REPO" diff --quiet HEAD -- 2>/dev/null || STAMP="$STAMP-dirty"
fi
{ head -n 1 "$BUF"
  printf '# assembled by scripts/assemble-droste-setup.sh from %s\n' "$STAMP"
  tail -n +2 "$BUF"
} > "$BUF.stamped"
mv "$BUF.stamped" "$BUF"

# ── The artifact's own guarantees ────────────────────────────────────────────
bash -n "$BUF" || die "the assembled script does not parse"
[[ $(tail -n 1 "$BUF") == "main" ]] \
  || die "the assembled script does not end with a bare 'main' (the g1lab suites source it with the last line stripped)"

cat "$BUF"
