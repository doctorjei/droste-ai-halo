#!/usr/bin/env bash
# check-llama-flags.sh — does every llama flag and env name we ship still EXIST?
#
# WHY THIS EXISTS. A llama.cpp pin bump can remove an option without removing
# anything of ours, and the failure is silent in both directions: a flag we EMIT
# that upstream dropped makes llama-server exit at startup, and a native
# LLAMA_ARG_* we OFFER that upstream dropped becomes a config line that reads as
# authoritative and does nothing. The s64 bump did exactly the second one —
# --hf-repo-v / --hf-file-v (the vocoder sub-model) were removed upstream, and
# llama.cfg went on offering their env names.
#
# 🚨 CI DOES NOT COVER THIS. targets/Container.llama's drift gate checks exactly
# THREE names (LLAMA_ARG_HOST, _PORT, _MODEL) against the built binary. A green
# build says nothing about the other four dozen. That gate is a floor, not a sweep.
#
# WHAT IT IS NOT. Not scripts/llama-options.sh — that one runs the BINARY on a
# machine with a GPU and reports option DRIFT (new/changed options worth exposing).
# This one reads SOURCE over the network, needs no GPU and no build, and answers a
# narrower question: has anything we already ship stopped existing? Run it at every
# pin bump, before the build.
#
# THE REF IS READ FROM THE CONTAINERFILE, never passed and never hardcoded: the
# question is only meaningful against the pin we actually build.
#
# Usage: scripts/check-llama-flags.sh [--ref <sha>]     (--ref for a dry run
#                                                        against a candidate pin)
# Exit:  0 all present · 1 something we ship is gone · 2 the check could not run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CF=$REPO/scaffolding/Container.llama-build
SPEC=$REPO/targets/llama/build-spec
CFG=$REPO/targets/llama/templates/llama.cfg

die() { printf 'check-llama-flags: %s\n' "$*" >&2; exit 2; }

REF=""
case "${1-}" in
  --ref) [[ $# -ge 2 ]] || die "--ref needs a sha"; REF=$2 ;;
  "")    ;;
  *)     die "unknown option: $1" ;;
esac

for f in "$CF" "$SPEC" "$CFG"; do [[ -r $f ]] || die "cannot read $f"; done
command -v curl >/dev/null 2>&1 || die "needs curl"

if [[ -z $REF ]]; then
  REF=$(sed -n 's/^ARG LLAMA_REF=\([0-9a-f]\{7,40\}\).*/\1/p' "$CF" | head -1)
  [[ -n $REF ]] || die "no ARG LLAMA_REF=<sha> found in $CF"
fi
REPO_URL=$(sed -n 's|^ARG LLAMA_REPO=https://github.com/\([^ ]*\)\.git.*|\1|p' "$CF" | head -1)
[[ -n $REPO_URL ]] || die "no ARG LLAMA_REPO=<url> found in $CF"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ARG=$TMP/arg.cpp
curl -fsSL -o "$ARG" "https://raw.githubusercontent.com/$REPO_URL/$REF/common/arg.cpp" \
  || die "could not fetch common/arg.cpp at $REF from $REPO_URL"

printf '\nllama flag/env existence — %s @ %s\n\n' "$REPO_URL" "${REF:0:12}"

# ── What upstream declares ───────────────────────────────────────────────────
# ⚠️ ALIAS LISTS ONLY. An earlier cut of this took `{"--flag"` and reported SEVEN
# flags as removed that were present all along, because options are declared
# {"--typical", "--typical-p"} and {"-e", "--embeddings"} — the name we ship is
# often not first. Matching any "--flag" on a line that opens a brace list gets
# every alias. Matching every "--flag" ANYWHERE would over-capture help text and
# report a removed flag as present, which is the dangerous direction.
#
# ⚠️ EVERY EXTRACTION ENDS `|| true`, AND THAT IS NOT SLOPPINESS. Under `set -o
# pipefail` a grep that matches nothing fails the whole pipeline and errexit kills
# the script THERE — exiting non-zero with nothing printed, which is
# indistinguishable from a real finding and tells the reader nothing. The floor
# checks below are what must speak for an empty set, so the pipelines have to
# survive long enough to reach them. (Found by mutating this script, not by
# reading it: emptying llama.cfg produced a silent exit 1.)
grep -hE '^[[:space:]]*\{' "$ARG" | grep -ohE '"--[a-z0-9-]+"' | tr -d '"' | sort -u > "$TMP/have_flags" || true
grep -ohE 'set_env\("LLAMA_ARG_[A-Z0-9_]+"\)' "$ARG" | sed -E 's/set_env\("//; s/"\)//' | sort -u > "$TMP/have_env" || true

# ── What we ship ─────────────────────────────────────────────────────────────
# Flags: only the emitted rows, "NAME:--flag". Prose mentions are NOT claims that
# the flag exists — this file discusses podman flags and writes ${LLAMA_ARG_X=…}
# placeholders, and sweeping those in produces noise that trains people to ignore
# the report.
grep -ohE '"[A-Z0-9_]+:(--[a-z0-9-]+)"' "$SPEC" | sed -E 's/.*:(--[a-z0-9-]+)"/\1/' | sort -u > "$TMP/our_flags" || true
# Env names: only lines that OFFER a setting, i.e. a commented assignment at the
# start of a line. Same reason.
grep -ohE '^# ?LLAMA_ARG_[A-Z0-9_]+=' "$CFG" | sed -E 's/^# ?//; s/=$//' | sort -u > "$TMP/our_env" || true

nf=$(wc -l < "$TMP/our_flags"); ne=$(wc -l < "$TMP/our_env")
hf=$(wc -l < "$TMP/have_flags"); he=$(wc -l < "$TMP/have_env")

# 🚨 NEITHER SIDE MAY BE EMPTY. A broken extractor produces an empty "ours" and
# the check passes having compared nothing — the silent green this repo keeps
# being bitten by. Both floors are deliberately generous; they catch a rotted
# regex, not a small edit.
(( nf >= 20 )) || die "extracted only $nf emitted flags from $SPEC — the extractor is broken, not the tree"
(( ne >= 40 )) || die "extracted only $ne offered env names from $CFG — the extractor is broken, not the tree"
(( hf >= 100 )) || die "found only $hf declared flags in arg.cpp — the parse is broken, not upstream"
(( he >= 50 )) || die "found only $he declared env names in arg.cpp — the parse is broken, not upstream"

printf '  we emit %s flags, we offer %s env names\n' "$nf" "$ne"
printf '  upstream declares %s flags, %s env names\n\n' "$hf" "$he"

miss_f=$(comm -23 "$TMP/our_flags" "$TMP/have_flags" || true)
miss_e=$(comm -23 "$TMP/our_env" "$TMP/have_env" || true)

rc=0
if [[ -n $miss_f ]]; then
  rc=1
  printf '  FAIL flags this spec EMITS that arg.cpp no longer declares:\n'
  printf '%s\n' "$miss_f" | sed 's/^/         /'
  printf '       ⇒ llama-server exits at startup on an unknown flag. Fix the SERVICE\n'
  printf '         rows in targets/llama/build-spec before building this pin.\n\n'
else
  printf '  ok   all %s emitted flags exist at this pin\n' "$nf"
fi

if [[ -n $miss_e ]]; then
  rc=1
  printf '  FAIL native env names llama.cfg OFFERS that arg.cpp no longer declares:\n'
  printf '%s\n' "$miss_e" | sed 's/^/         /'
  printf '       ⇒ NOT fatal: llama-server reads only the env names it declares, so\n'
  printf '         uncommenting one is a SILENT NO-OP — a knob that reads as\n'
  printf '         authoritative and does nothing. Remove the line, or replace it\n'
  printf '         with whatever upstream renamed it to.\n'
  printf '       ⚠️ llama.cfg is JEI'"'"'S FILE. Report this; do not edit it.\n\n'
else
  printf '  ok   all %s offered env names exist at this pin\n' "$ne"
fi

# The check must be able to FAIL, and a reader should be able to see that without
# taking it on trust. A name upstream cannot possibly declare proves the
# comparison is live rather than comparing a set against itself.
if grep -qx -- '--droste-not-a-real-flag' "$TMP/have_flags"; then
  printf '\n  FAIL the control matched — the declared set is not what it claims to be\n'
  rc=1
else
  printf '  ok   control: a fabricated flag is absent from the declared set\n'
fi

printf '\n  %s\n\n' "$( ((rc == 0)) && echo 'nothing we ship has been removed upstream.' || echo 'something we ship no longer exists — see above.')"
exit $rc
