#!/usr/bin/env bash
# check-llama-collisions.sh — do the options we ship still MEAN what our surface says?
#
# check-llama-flags.sh asks "does everything we ship still EXIST". This asks the two
# questions it structurally cannot:
#   1. DEPRECATION. At fb2cc35a the whole --mmap/--mlock/--direct-io family was
#      collapsed into one --load-mode enum whose handlers overwrite each other. Nothing
#      was REMOVED, so the existence check stayed green the entire time.
#   2. SHARED FIELDS. Two settings writing one upstream field are a silent last-wins
#      race. LLAMA_EXCLUSIVE_GROUPS names the ones we know; this asserts it is complete.
#
# A shared field is not automatically a conflict: where one option is a superset of
# another, or the overlap is partial, "set ONE of them" is false advice. Those are
# EXEMPT below with their reasons, and a NEW shared field must be classified either way.
#
# The ref is read from the Containerfile, never passed and never hardcoded.
#
# Usage: scripts/check-llama-collisions.sh [--ref <sha>]
# Exit:  0 clean · 1 something we ship changed meaning · 2 the check could not run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CF=$REPO/scaffolding/Container.llama-build
SPEC=$REPO/targets/llama/build-spec
CFG=$REPO/targets/llama/templates/llama.cfg

die() { printf 'check-llama-collisions: %s\n' "$*" >&2; exit 2; }

REF=""
case "${1-}" in
  --ref) [[ $# -ge 2 ]] || die "--ref needs a sha"; REF=$2 ;;
  "")    ;;
  *)     die "unknown option: $1" ;;
esac

for f in "$CF" "$SPEC" "$CFG"; do [[ -r $f ]] || die "cannot read $f"; done
command -v curl >/dev/null 2>&1 || die "needs curl"
command -v python3 >/dev/null 2>&1 || die "needs python3"

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
[[ -s $ARG ]] || die "fetched an empty common/arg.cpp at $REF"

# Needed for the AUTO-is-a-stub assertion below; the rewrite lives here, not in arg.cpp.
MODEL=$TMP/llama-model.cpp
curl -fsSL -o "$MODEL" "https://raw.githubusercontent.com/$REPO_URL/$REF/src/llama-model.cpp" \
  || die "could not fetch src/llama-model.cpp at $REF from $REPO_URL"
[[ -s $MODEL ]] || die "fetched an empty src/llama-model.cpp at $REF"

printf '\nllama option SEMANTICS — %s @ %s\n\n' "$REPO_URL" "${REF:0:12}"

python3 - "$ARG" "$SPEC" "$CFG" "$MODEL" <<'PY'
import re
import sys

argcpp, spec_path, cfg_path, model_path = sys.argv[1:5]
src = open(argcpp, encoding='utf-8', errors='replace').read()
spec = open(spec_path, encoding='utf-8', errors='replace').read()
cfg = open(cfg_path, encoding='utf-8', errors='replace').read()
model = open(model_path, encoding='utf-8', errors='replace').read()

# Settings whose overlap is real but whose "set ONE of them" would be FALSE. Each of
# these is a decision, not an oversight; deleting a line here makes the check red.
EXEMPT = {
    # The 'embedding' exemption was removed in s69: EMBEDDINGS and RERANKING were folded
    # into DROSTE_LLAMA_TASK_TYPE, so no two shipped settings write that field any more.
    # An exemption for a state nobody can express is a claim nothing tests.
    'fit_params_min_ctx':
        'CTX_SIZE writes n_ctx AND this; FIT_CTX writes only this. A user may want '
        'both, so telling them to pick one would be wrong.',
}
# AUTO_MODEL presets set a dozen fields each BY DESIGN and llama.cfg says so on the
# setting's own line. They would otherwise collide with almost everything we ship.
EXEMPT_SETTINGS = {'DROSTE_LLAMA_AUTO_MODEL'}

fail = []
ok = []


def blocks(text):
    for m in re.finditer(r'\badd_opt\s*\(', text):
        i, depth, in_str, esc, j = m.end() - 1, 0, False, False, m.end() - 1
        while j < len(text):
            c = text[j]
            if in_str:
                if esc:
                    esc = False
                elif c == '\\':
                    esc = True
                elif c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    yield text[i:j + 1]
                    break
            j += 1


def aliases(b):
    head = b.split('[](')[0]
    return [s.group(1)
            for grp in re.finditer(r'\{([^{}]*)\}', head)
            for s in re.finditer(r'"(-{1,2}[A-Za-z0-9][A-Za-z0-9.-]*)"', grp.group(1))]


def fields(b):
    body = b[b.find('[]('):] if '[](' in b else ''
    return sorted(set(m.group(1) for m in re.finditer(
        r'params\.([A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*)\s*=(?!=)', body)))


def helptext(b):
    head = re.sub(r'\{[^{}]*\}', '', b.split('[](')[0])
    return ' '.join(re.findall(r'"((?:[^"\\]|\\.)*)"', head))


def env_of(b):
    m = re.search(r'set_env\("([A-Z0-9_]+)"\)', b)
    return m.group(1) if m else None


# Our surface: flag -> the SETTING name a user would edit.
flag_to_setting = {}
for m in re.finditer(r'"([A-Z0-9_]+)[:|]([^"]*)"', spec):
    suffix, rest = m.group(1), m.group(2)
    for f in re.findall(r'--[a-z0-9.-]+', rest):
        flag_to_setting[f] = 'DROSTE_LLAMA_' + suffix
offered_env = set(re.findall(r'^# ?(LLAMA_ARG_[A-Z0-9_]+)=', cfg, re.M))
offered_env |= set(re.findall(r'^# ?(LLAMA_API_KEY)=', cfg, re.M))

groups = []
gm = re.search(r'LLAMA_EXCLUSIVE_GROUPS=\((.*?)\n\)', spec, re.S)
if gm:
    for row in re.findall(r'"([^"]+)"', gm.group(1)):
        groups.append({n if n.startswith('LLAMA_') else 'DROSTE_LLAMA_' + n
                       for n in row.split()})

opts = [{'a': aliases(b), 'f': fields(b), 'h': helptext(b), 'e': env_of(b)}
        for b in blocks(src)]
opts = [o for o in opts if o['a']]
if len(opts) < 100:
    print(f"  ABORT  parsed only {len(opts)} options — the extractor is broken, not the tree")
    raise SystemExit(2)

print(f"  parsed {len(opts)} upstream options; our surface names "
      f"{len(set(flag_to_setting.values()))} emitted settings and {len(offered_env)} native")

# 1. deprecation
dep = []
for o in opts:
    if 'deprecat' not in o['h'].lower():
        continue
    names = {flag_to_setting[a] for a in o['a'] if a in flag_to_setting}
    if o['e'] in offered_env:
        names.add(o['e'])
    if names:
        repl = re.search(r'in favor of `([^`]+)`', o['h'])
        dep.append((' '.join(o['a']), sorted(names), repl.group(1) if repl else 'nothing named'))
if dep:
    fail.append("we ship options upstream has DEPRECATED:")
    for al, names, repl in dep:
        fail.append(f"      {al}  ({', '.join(names)})  -> use {repl}")
else:
    ok.append("nothing we ship is deprecated upstream")

# 2. shared fields
byfield = {}
for o in opts:
    names = {flag_to_setting[a] for a in o['a'] if a in flag_to_setting}
    if o['e'] in offered_env:
        names.add(o['e'])
    names -= EXEMPT_SETTINGS
    for f in o['f']:
        byfield.setdefault(f, set()).update(names)

uncovered = []
covered = 0
for f, names in sorted(byfield.items()):
    if len(names) < 2:
        continue
    if f in EXEMPT:
        covered += 1
        continue
    if any(names <= g for g in groups):
        covered += 1
        continue
    uncovered.append((f, sorted(names)))
if uncovered:
    fail.append("upstream fields written by MORE THAN ONE setting we ship, with no")
    fail.append("      exclusive group and no exemption — a silent last-wins race:")
    for f, names in uncovered:
        fail.append(f"      params.{f}: {', '.join(names)}")
else:
    ok.append(f"every shared upstream field is grouped or exempt ({covered} of them)")

# 3. the groups must still describe reality
stale = []
for g in groups:
    hit = [f for f, names in byfield.items() if len(g & names) >= 2]
    if not hit:
        stale.append(sorted(g))
if stale:
    fail.append("exclusive groups that no longer share ANY upstream field —")
    fail.append("      upstream split them, so the warning is now false:")
    for g in stale:
        fail.append(f"      {', '.join(g)}")
else:
    ok.append(f"all {len(groups)} exclusive groups still share a field upstream")

# 4. `auto` is a stub: llama.h calls it "auto-detect based on device capabilities" and
# llama-model.cpp rewrites it to MMAP before any consumer sees it. We drop it on that
# basis, so if the rewrite ever disappears that has to reach a human.
AUTO_REWRITE = re.compile(
    r'load_mode\s*==\s*LLAMA_LOAD_MODE_AUTO\s*\?\s*LLAMA_LOAD_MODE_MMAP')
offers_auto = bool(re.search(r'"LOAD_MODE\|[^"]*\bauto=', spec))
if AUTO_REWRITE.search(model):
    if offers_auto:
        fail.append("LOAD_MODE offers `auto`, but upstream still rewrites AUTO -> MMAP")
        fail.append("      before any consumer reads it, so the value is a synonym for")
        fail.append("      `mmap` and the menu presents a distinction that does not exist.")
    else:
        ok.append("`auto` is still rewritten to MMAP upstream, so leaving it off the menu"
                  " is still right")
elif not offers_auto:
    fail.append("upstream NO LONGER rewrites LLAMA_LOAD_MODE_AUTO to MMAP, so `auto` may")
    fail.append("      now mean something. We drop it from the LOAD_MODE menu ONLY because")
    fail.append("      it was a stub — re-read llama-model.cpp and decide whether to offer")
    fail.append("      it again (targets/llama/templates/llama.cfg + LLAMA_CHOICE_FLAGS).")
else:
    ok.append("`auto` is no longer a stub upstream and we offer it")

print()
for line in ok:
    print(f"  ok   {line}")
for line in fail:
    print(f"  FAIL {line}" if not line.startswith('      ') else line)
print()
if fail:
    print("  our surface no longer describes this pin — see above.")
    raise SystemExit(1)
print("  our surface still describes this pin.")
PY
