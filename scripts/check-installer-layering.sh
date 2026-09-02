#!/usr/bin/env bash
# check-installer-layering.sh — assert the UI layer of droste-setup.sh stays blind.
#
# WHAT THIS PROTECTS. droste-setup.sh opens with a display/prompt layer (the
# sections "Output / display helpers", "Path fitting" and "Prompt plumbing",
# ending where "State" begins) which draws every screen and reads every answer
# and knows nothing about droste. Jei's ask (s63) is that the drawing stay
# clean enough to lift into another project of his. Three properties make that
# possible, all three were TRUE BEFORE ANYONE STATED THEM, and all three would
# die quietly to one reasonable-looking edit:
#
#   A. the layer references no global belonging to the program around it
#   B. no function in the layer calls a function defined below the layer
#   C. inside the layer, the DISPLAY half never calls the PROMPT half
#
# C is the one that matters most to the long game: the prompt half calls the
# display half constantly (that is the right direction), and the day a drawing
# routine stops to ask a question is the day the drawing stops being liftable
# on its own. Nothing else in the tree enforces it.
#
# WHAT IT READS. A path, defaulting to the droste-setup.sh beside this checkout.
# In CI it is handed the ASSEMBLED artifact rather than the tracked file, which
# is the same bytes today (lint-shell.yml asserts it) and is the only subject
# that still exists once the artifact stops being tracked. It anchors on the
# section dividers, so either subject works and neither carries line numbers.
#
# HOW IT DECIDES WHAT IS FORBIDDEN. It does not carry a list of names. A hand
# written regex rots the moment someone adds a global, and it rots SILENTLY —
# the checker keeps passing. So the forbidden set is DERIVED from the file on
# every run: every SHOUTING-CASE name the program assigns outside the layer is
# forbidden inside it, minus the names the layer assigns itself (those are its
# own outputs) and minus the two documented inputs below. Add a global to the
# installer and it is covered without touching this script.
#
# Usage: check-installer-layering.sh [path/to/droste-setup.sh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP=${1:-$SCRIPT_DIR/../droste-setup.sh}
[[ -r $SETUP ]] || { printf 'check-installer-layering.sh: cannot read %s\n' "$SETUP" >&2; exit 2; }

# The layer's declared inputs. This list is the ONLY thing a maintainer should
# ever have to edit here, and every entry is a promise that the layer can be
# lifted as long as the new host sets it too.
UI_INPUTS='UI_PROG UI_INPUT_VAR'

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

printf '\nInstaller layering — droste-setup.sh\n  subject: %s\n\n' "$SETUP"

REPORT=$(SETUP="$SETUP" UI_INPUTS="$UI_INPUTS" python3 - <<'PY'
import os, re, sys

path = os.environ['SETUP']
inputs = set(os.environ['UI_INPUTS'].split())
lines = open(path, encoding='utf-8').read().split('\n')

# ── Two strippers, and they are NOT the same one ─────────────────────────────
# Brace counting needs quoted text GONE (a "}" in a string is not a brace).
# The call graph needs quoted text KEPT (`"$(disp_width)"` is a real call) and
# comments gone — a naive grep over this file reports five display->prompt
# "calls" that are every one of them prose about the prompts.
def _scan(l, keep_quoted):
    out = []; i = 0; n = len(l); q = None
    while i < n:
        c = l[i]
        if q:
            if q == '"' and c == '\\':
                if keep_quoted: out.append(l[i:i + 2])
                i += 2; continue
            if c == q:
                q = None
                if keep_quoted: out.append(c)
                i += 1; continue
            if keep_quoted: out.append(c)
            i += 1; continue
        if c == '\\':
            out.append(l[i:i + 2]); i += 2; continue
        if c in '"\'':
            q = c
            if keep_quoted: out.append(c)
            i += 1; continue
        if c == '#' and (not out or out[-1] in ' \t;&|(<>'):
            break
        out.append(c); i += 1
    return ''.join(out)

def code_only(l):  # comments and quoted text removed
    return _scan(l, False)

def decomment(l):  # comments removed, quoted text kept
    return '' if l.lstrip().startswith('#') else _scan(l, True)

# ── Anchors, never line numbers ──────────────────────────────────────────────
# Every number in the s42 brief that described this file was stale within one
# session. Locate by the divider text the file itself draws.
def anchor(pat, what):
    rx = re.compile(pat)
    hits = [i + 1 for i, l in enumerate(lines) if rx.match(l)]
    if len(hits) != 1:
        print('ANCHOR|%s|%d' % (what, len(hits)))
        sys.exit(3)
    return hits[0]

lo      = anchor(r'^# ── Output / display helpers ', 'display-start')
promptl = anchor(r'^# ── Prompt plumbing ',         'prompt-start')
statel  = anchor(r'^# ── State ',                   'state-start')
hi      = statel - 1
if not (lo < promptl < hi):
    print('ANCHOR|order|0'); sys.exit(3)

print('ZONE|%d|%d|%d' % (lo, promptl, hi))

# ── Function extents ─────────────────────────────────────────────────────────
DEF = re.compile(r'^([A-Za-z_][A-Za-z0-9_:]*)\s*\(\)\s*\{')
funcs = {}
i = 0
while i < len(lines):
    m = DEF.match(lines[i])
    if m:
        s = code_only(lines[i])
        depth = s.count('{') - s.count('}')
        j = i
        while depth > 0 and j + 1 < len(lines):
            j += 1
            s = code_only(lines[j])
            depth += s.count('{') - s.count('}')
        funcs[m.group(1)] = (i + 1, j + 1)   # 1-based, inclusive
        i = j + 1
    else:
        i += 1

names = set(funcs)
IN_LAYER  = {f for f, (a, b) in funcs.items() if a >= lo and b <= hi}
IN_DISP   = {f for f, (a, b) in funcs.items() if a >= lo and b < promptl}
IN_PROMPT = {f for f, (a, b) in funcs.items() if a >= promptl and b <= hi}
print('COUNT|%d|%d|%d|%d' % (len(funcs), len(IN_LAYER), len(IN_DISP), len(IN_PROMPT)))

def body(f):
    # THE WHOLE EXTENT, def line included, minus everything up to its opening
    # brace. An earlier cut of this took lines[a:b-1] — "the extent without its
    # first and last line" — which is silently EMPTY for a one-liner, and this
    # file has 29 of them: say, warn, die, wrap, hdr, dflt, subnote, the pf_*
    # atoms. Every call they make was invisible, and two mutants written to
    # prove the graph bites walked straight through it.
    a, b = funcs[f]
    seg = [decomment(l) for l in lines[a - 1:b]]
    k = seg[0].find('{')
    if k >= 0:
        seg[0] = seg[0][k + 1:]
    return '\n'.join(seg)

def word(n):
    # a call site, not a definition and not "$NAME" / "a.NAME" / "NAME_2"
    return re.compile(r'(?<![A-Za-z0-9_:$.-])' + re.escape(n) + r'(?![A-Za-z0-9_:])')

# ── A: no forbidden identifiers ──────────────────────────────────────────────
ASSIGN = re.compile(r'(?<![A-Za-z0-9_])([A-Z][A-Z0-9_]*)(?:\[[^\]]*\])?\+?=')
LOCAL  = re.compile(r'^\s*(?:local|typeset)\b')

# HEREDOC BODIES ARE PROSE, NOT CODE — and this file is mostly prose that draws.
# usage()'s help text says "TERM=dumb auto-detects" and NOTES.md's emitters are
# full of example settings; read as assignments they invent globals that do not
# exist, and each invented one then shows up as a violation the moment the layer
# legitimately reads the real environment variable of that name. TERM was caught
# exactly that way. Masked ONLY here, in the assignment derivation: an unquoted
# heredoc can still run a `$(...)`, so the call graph keeps reading them.
HD = re.compile(r'<<-?\s*(["\']?)([A-Za-z_][A-Za-z0-9_]*)\1')
def heredoc_body():
    body = set(); i = 0; n = len(lines)
    while i < n:
        s = decomment(lines[i])
        m = HD.search(s.replace('<<<', ''))
        if m:
            delim = m.group(2); i += 1
            while i < n and lines[i].strip() != delim:
                body.add(i); i += 1
        i += 1
    return body
HEREDOC = heredoc_body()

def assigned(a, b):
    out = set()
    for k in range(a - 1, min(b, len(lines))):
        if k in HEREDOC:
            continue
        l = lines[k]
        s = decomment(l)
        if not s or LOCAL.match(s):
            continue
        out.update(ASSIGN.findall(s))
        for part in re.split(r'\bdeclare\b', s)[1:]:
            out.update(re.findall(r'(?<![A-Za-z0-9_])([A-Z][A-Z0-9_]*)', part.split('=')[0]))
    return out

layer_owned  = assigned(lo, hi)
program_wide = assigned(1, lo - 1) | assigned(hi + 1, len(lines))
forbidden    = (program_wide - layer_owned) - inputs

layer_text = '\n'.join(decomment(l) for l in lines[lo - 1:hi])
REF = lambda n: re.compile(r'(?<![A-Za-z0-9_])' + re.escape(n) + r'(?![A-Za-z0-9_])')
viol_a = sorted(n for n in forbidden if REF(n).search(layer_text))
print('A|%d|%d|%s' % (len(forbidden), len(viol_a), ','.join(viol_a)))

# ── B: no upward calls ───────────────────────────────────────────────────────
viol_b = []
for f in sorted(IN_LAYER):
    t = body(f)
    for c in sorted(names):
        if c != f and c not in IN_LAYER and word(c).search(t):
            viol_b.append('%s->%s' % (f, c))

# The layer also has TOP-LEVEL code — the --ascii pre-pass, the palette, the
# option loop — and it runs during sourcing, before most of the file exists.
# It legitimately calls usage(), which is defined ABOVE the layer; a call to
# anything defined BELOW would be a forward reference into droste and is a
# violation of the same rule, so it is checked, function bodies excluded.
covered = set()
for a, b in funcs.values():
    covered.update(range(a, b + 1))
toplevel = '\n'.join(decomment(lines[k - 1]) for k in range(lo, hi + 1) if k not in covered)
below = {f for f, (a, _) in funcs.items() if a > hi}
for c in sorted(below):
    if word(c).search(toplevel):
        viol_b.append('<layer top level>->%s' % c)
print('B|%d|%s' % (len(viol_b), ','.join(viol_b)))

# ── C: the display half never calls the prompt half ──────────────────────────
viol_c = []
for f in sorted(IN_DISP):
    t = body(f)
    for c in sorted(IN_PROMPT):
        if word(c).search(t):
            viol_c.append('%s->%s' % (f, c))
print('C|%d|%s' % (len(viol_c), ','.join(viol_c)))

# The counter-direction, reported so a reader can see C is a real asymmetry and
# not a vacuous claim about two halves that never speak. A zero here would mean
# the split is drawn in the wrong place, so it is asserted too.
edges = 0
tgts = set()
for f in IN_PROMPT:
    t = body(f)
    for c in IN_DISP:
        hits = len(word(c).findall(t))
        if hits:
            tgts.add(c); edges += hits
print('CBACK|%d|%d' % (len(tgts), edges))

# Same for B's counter-direction: the layer is called INTO, heavily.
inward = 0
for f in names - IN_LAYER:
    t = body(f)
    for c in IN_LAYER:
        if word(c).search(t):
            inward += 1
print('BBACK|%d' % inward)
PY
) && rc=0 || rc=$?

# The analysis says WHY before it gives up (a missing or duplicated section
# divider is the likely reason, and "did not complete" would send the reader
# looking for a python bug instead of a renamed heading). $REPORT is assigned
# even when the substitution's command fails, so the reason survives.
if [[ $rc -ne 0 ]]; then
  printf '  FAIL the analysis aborted (rc=%s) — see below\n' "$rc"
  printf '%s\n' "$REPORT" | sed 's/^/         /'
  printf '\n  pass=0 fail=1\n'
  exit 1
fi

get() { printf '%s\n' "$REPORT" | grep "^$1|" || true; }

if [[ -n $(get ANCHOR) ]]; then
  printf '  FAIL section anchors not found as expected: %s\n' "$(get ANCHOR)"
  printf '\n  pass=0 fail=1\n'
  exit 1
fi

IFS='|' read -r _ z_lo z_prompt z_hi <<<"$(get ZONE)"
IFS='|' read -r _ n_all n_layer n_disp n_prompt <<<"$(get COUNT)"
printf '  layer: lines %s-%s (display %s-%s, prompt %s-%s)\n' \
  "$z_lo" "$z_hi" "$z_lo" "$((z_prompt - 1))" "$z_prompt" "$z_hi"
printf '  functions: %s in the file, %s in the layer (%s display, %s prompt)\n\n' \
  "$n_all" "$n_layer" "$n_disp" "$n_prompt"

# ── A ─────────────────────────────────────────────────────────────────────────
IFS='|' read -r _ a_pool a_n a_list <<<"$(get A)"
if [[ $a_n -eq 0 ]]; then
  ok "A. no project global is named in the layer ($a_pool derived, 0 referenced)"
else
  bad "A. the layer names $a_n project global(s): $a_list"
fi
# The pool must not be empty, or A passes because it asked nothing.
if [[ ${a_pool:-0} -gt 20 ]]; then
  ok "A. the derived forbidden set is non-trivial ($a_pool names)"
else
  bad "A. derived only $a_pool forbidden names — the derivation is broken, not the file"
fi

# ── B ─────────────────────────────────────────────────────────────────────────
IFS='|' read -r _ b_n b_list <<<"$(get B)"
if [[ $b_n -eq 0 ]]; then
  ok "B. no function in the layer calls out of it"
else
  bad "B. $b_n upward call(s): $b_list"
fi
IFS='|' read -r _ b_in <<<"$(get BBACK)"
if [[ ${b_in:-0} -gt 0 ]]; then
  ok "B. and the layer IS called into ($b_in edges) — the seam is one-way, not idle"
else
  bad "B. nothing calls into the layer — the zone is not where this thinks it is"
fi

# ── C ─────────────────────────────────────────────────────────────────────────
IFS='|' read -r _ c_n c_list <<<"$(get C)"
if [[ $c_n -eq 0 ]]; then
  ok "C. the display half never calls the prompt half"
else
  bad "C. $c_n display->prompt call(s): $c_list"
fi
IFS='|' read -r _ c_t c_e <<<"$(get CBACK)"
if [[ ${c_e:-0} -gt 0 ]]; then
  ok "C. and the prompt half DOES call the display half ($c_t functions, $c_e sites)"
else
  bad "C. the two halves never speak — the display/prompt line is drawn wrong"
fi

printf '\n  pass=%d fail=%d\n' "$pass" "$fail"
[[ $fail -eq 0 ]] || exit 1
exit 0
