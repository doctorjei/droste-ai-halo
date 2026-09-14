#!/usr/bin/env bash
# check-installer-dryrun.sh — assert that --dry-run cannot change the disk.
#
# 🏁 WHAT IT PROTECTS. `droste-setup.sh --dry-run` promises one thing, in Jei's
# words: "a dry run never changes the disk." That promise is made to a user
# standing in front of the most destructive surface this project has — the
# interview moves their data, empties their caches and deletes directories, and
# it does all of it BEFORE the ladder rung is even chosen. A dry run that misses
# one site is not a smaller feature; it is this project's own named defect (a
# knob that looks authoritative and does nothing) aimed at someone who has just
# been told nothing will happen.
#
# ⭐⭐ SO THIS CHECKER IS THE DELIVERABLE, NOT THE WRAPPERS. Without it the
# guarantee is a promise; with it, it is a property. The wrappers are only how
# the property is made checkable.
#
# ── HOW IT DECIDES WHAT IS A MUTATION ────────────────────────────────────────
# IT CARRIES NO LIST OF SITES, for the same reason check-installer-layering.sh
# carries no list of globals: a hand-written list rots the moment someone adds a
# writer, and it rots SILENTLY — the checker keeps passing. The mutating set is
# DERIVED on every run, from the tree, by the verbs a POSIX shell changes the
# world with:
#
#   filesystem   rm · rmdir · mkdir · mv · cp · install · truncate · chmod ·
#                chown · touch · ln · tee · dd · a `>` or `>>` redirect
#   container    a "$RUNTIME" / $RUNTIME_BIN / podman / docker / distrobox verb
#                that is not on the derived READ-ONLY set
#   host units   systemctl · loginctl
#
# ⚠️ THE READ-ONLY RUNTIME VERBS ARE THE ONE PLACE A LIST IS UNAVOIDABLE, and it
# is a list of what is SAFE rather than of what is dangerous — which is the
# direction that fails closed. A verb nobody has classified counts as a mutation
# and this checker goes red until someone says otherwise. Adding a verb here is
# a decision; forgetting to is not a hole.
#
# ── HOW IT DECIDES WHETHER A MUTATION IS GUARDED ─────────────────────────────
# A mutation line passes when EITHER:
#   (a) it is lexically part of a `dry::fs` / `dry::rt` call — the wrapper stands
#       in front of the command, or
#   (b) a `dry::` guard appears EARLIER IN ITS OWN FUNCTION. Ordering is the
#       whole claim: a mutation after `if dry::on; then …; return 0; fi` is
#       unreachable in a dry run, and the same mutation moved ABOVE that block
#       is not. A checker that only asked "does this function mention dry::"
#       would bless exactly that move.
#
# ⚠️ (b) IS A COARSE APPROXIMATION AND IS SAID SO OUT LOUD. It cannot tell an
# early-return guard from a `dry::` call in a sibling branch, so it can pass a
# function whose guard does not actually cover the mutation below it. It is
# deliberately the weaker half: (a) is exact, and every site this checker was
# written against uses (a) or a guard that returns. ⭐ What it DOES catch, which
# is the failure that actually happens, is a NEW mutation added to a file where
# nobody was thinking about dry runs at all.
#
# ── AND THE SECOND ASSERTION, WHICH IS THE ONE THAT CANNOT BE FOOLED ─────────
# It RUNS the thing. A real headless run and a dry headless run against the same
# answers, in two throwaway HOMEs, and the dry one must leave its HOME exactly as
# it found it — byte for byte, timestamps included. ⭐ A static check says no
# mutation escaped the wrappers; this says no mutation happened. Neither implies
# the other, and the second is what a user actually cares about.
#
# Usage: check-installer-dryrun.sh [path/to/installer-dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=${1:-$SCRIPT_DIR/../installer}
[[ -d $SRC ]] || {
  printf 'check-installer-dryrun.sh: no installer directory at %s\n' "$SRC" >&2
  exit 2; }

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

printf '\nInstaller dry run — no mutation escapes the wrappers\n  subject: %s\n\n' "$SRC"

REPORT=$(SRC="$SRC" python3 - <<'PY'
import os, re, glob

src = os.environ['SRC']

# ── The mutating verbs, IN COMMAND POSITION ONLY ─────────────────────────────
# 🚨 COMMAND POSITION IS THE WHOLE OF THE PRECISION HERE, and the first cut of
# this checker learned it the expensive way: matching these words ANYWHERE
# reported 30 sites of which 3 were real. `prose "stored at <base>/<box>"` read
# as a redirect, `(( idx >= 1 ))` read as a redirect, `status_start "loginctl
# enable-linger..."` read as a loginctl call, and so did `command -v loginctl`.
# ⭐ A CHECKER THAT CRIES WOLF GETS TUNED UNTIL IT IS SILENT, and the tuning is
# where the real site gets excluded. So it reads only the FIRST WORD of a
# command, and the runtime assertion below carries the weight this gives up.
FS_VERBS = {'rm', 'rmdir', 'mkdir', 'mv', 'cp', 'install', 'truncate',
            'chmod', 'chown', 'touch', 'ln', 'tee', 'dd'}
RT_HEADS = {'"$RUNTIME"', '$RUNTIME_BIN', '"$RUNTIME_BIN"', '"${RUNTIME:-podman}"',
            'podman', 'docker', 'distrobox', 'systemctl', 'loginctl'}

# An allowlist of SAFE verbs, never a denylist of dangerous ones: a verb nobody
# has classified counts as a mutation and this goes red. Adding one here is a
# decision someone made; forgetting to add one is not a hole.
READ_VERBS = {'ps', 'inspect', 'images', 'info', 'version', 'is-enabled',
              'is-active', 'show-user', 'show', 'unshare', 'exists',
              'list', 'ls', 'status', 'cat'}
# `podman image exists` reads; `podman image rm` does not. When the first word
# is a NOUN, the second is what decides.
NOUNS = {'image', 'images', 'system', 'manifest', 'container', 'volume'}

LEAD = re.compile(r'^(?:!|if|then|elif|else|do|while|until|\{|\(|&&|\|\||;|\|)\s+')
DEF = re.compile(r'^([A-Za-z_][A-Za-z0-9_:]*)\s*\(\)\s*\{')


def strip_comment(l):
    out = []; i = 0; n = len(l); q = None
    while i < n:
        c = l[i]
        if q:
            if q == '"' and c == '\\':
                out.append(l[i:i + 2]); i += 2; continue
            if c == q:
                q = None; out.append(c); i += 1; continue
            out.append(c); i += 1; continue
        if c == '\\':
            out.append(l[i:i + 2]); i += 2; continue
        if c in '"\'':
            q = c; out.append(c); i += 1; continue
        if c == '#' and (not out or out[-1] in ' \t;&|(<>'):
            break
        out.append(c); i += 1
    return ''.join(out)


def commands(code):
    """Every command HEAD on this line: at the start, after a separator, and
    inside a $( ) substitution."""
    heads = []
    # ⚠️ NOT SPLIT ON A BACKTICK, and that is a bug fix rather than an
    # omission: NOTES.md's prose is full of `distrobox enter` and `podman
    # restart` inside printf strings, and splitting there handed the word after
    # the backtick to the analyser as a command head. Eight of report.sh's
    # sentences were reported as container mutations. This installer uses $( )
    # throughout and no backtick substitution at all, so nothing real is lost.
    for chunk in re.split(r'(?:;|&&|\|\||\||\$\()', code):
        s = chunk.strip()
        while True:
            m = LEAD.match(s)
            if not m:
                break
            s = s[m.end():]
        while re.match(r'^[A-Za-z_][A-Za-z0-9_]*=\S*\s+', s):
            parts = s.split(None, 1)
            s = parts[1] if len(parts) > 1 else ''
        if s:
            heads.append(s.split())
    return heads


def unquoted(l):
    """Comments AND quoted text removed. Used for one job only: finding a
    redirect. 🚨 THE FIRST CUT OF THIS CHECKER DROPPED REDIRECT DETECTION
    ENTIRELY, because reading them out of quoted text reported `prose "stored at
    <base>/<box>"` and `(( idx >= 1 ))` as writes — and the tuning that silenced
    the noise also silenced write_notes, whose `} > "$f"` is how NOTES.md is
    written. The FIRST real --dry-run died there. ⭐ Tuning a rule for quiet is
    how it stops asserting the thing it was tuned around; the answer is a
    sharper rule, not a weaker one."""
    out = []; i = 0; n = len(l); q = None
    while i < n:
        c = l[i]
        if q:
            if q == '"' and c == '\\':
                i += 2; continue
            if c == q:
                q = None
            i += 1; continue
        if c == '\\':
            i += 2; continue
        if c in '"\'':
            # 🚨 A QUOTED RUN IS NOT SIMPLY DROPPED, and the difference matters
            # in both directions. Dropping it loses the redirect TARGET — every
            # one of them is written `> "$log"` — while keeping it reads the `>`
            # in `printf 'droste-<box>-halo'` as a redirect. So a quoted run
            # that is EXACTLY a variable or command substitution is kept, and
            # every other one collapses to a single placeholder character.
            q = c; j = i + 1
            inner = []
            while j < n:
                if l[j] == '\\' and q == '"':
                    inner.append(l[j:j + 2]); j += 2; continue
                if l[j] == q:
                    break
                inner.append(l[j]); j += 1
            text = ''.join(inner)
            out.append(text if re.fullmatch(r'\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$\(.*\)', text) else '_')
            i = j + 1 if j < n else n
            q = None
            continue
        if c == '#' and (not out or out[-1] in ' \t;&|(<>'):
            break
        out.append(c); i += 1
    return ''.join(out)


# A real output redirect, and the three exclusions are each a measured false
# positive rather than a precaution:
#   `(( a > b ))` / `[[ -n $x ]]`  arithmetic and tests are not redirects, so
#                                  those spans are removed before looking
#   `>/dev/null`, `2>/dev/null`    a redirect that writes NOTHING. Nine sites,
#                                  every one of them a `command -v` probe
#   `>&` / `2>&1` / `>=` / `->`    a dup, a comparison, an arrow
ARITH = re.compile(r'\(\(.*?\)\)|\[\[.*?\]\]')
REDIR = re.compile(r'(?<![-<>=])[0-9]?>>?(?![>=&])\s*(\S+)?')


def writes_something(code, safe_targets=frozenset()):
    s = ARITH.sub(' ', unquoted(code))
    for m in REDIR.finditer(s):
        target = (m.group(1) or '').strip('"\'')
        if target.startswith('/dev/'):
            continue
        bare = target.lstrip('$').strip('{}')
        if bare in safe_targets:
            continue
        return True
    return False


def mutation_kind(code, safe_targets=frozenset()):
    for words in commands(code):
        head = words[0]
        if head in FS_VERBS:
            return 'fs'
        if head in RT_HEADS:
            rest = [w for w in words[1:] if not w.startswith('-')]
            verb = rest[0] if rest else ''
            if verb in NOUNS and len(rest) > 1 and rest[1] in READ_VERBS:
                continue
            if verb in READ_VERBS:
                continue
            return 'rt'
    if writes_something(code, safe_targets):
        return 'fs'
    return None


# ── Two derivations that keep this honest without an exemption list ─────────
# 🚨 A HEREDOC BODY IS PROSE, NOT CODE. usage()'s help text says "droste-<box>-
# halo" and "<box>.cfg", and read as shell those `<` and `>` are redirects. The
# layering checker learned the same thing about assignments and masks them the
# same way. ⚠️ Masked for MUTATION detection only — an unquoted heredoc can still
# run a $( ), so nothing else here should copy the exemption.
HD = re.compile(r'<<-?\s*(["\']?)([A-Za-z_][A-Za-z0-9_]*)\1')


def heredoc_lines(lines):
    body = set(); i = 0; n = len(lines)
    while i < n:
        m = HD.search(strip_comment(lines[i]).replace('<<<', ''))
        if m:
            delim = m.group(2); i += 1
            while i < n and lines[i].strip() != delim:
                body.add(i); i += 1
        i += 1
    return body


# ⭐ DERIVED, NOT EXEMPTED. step_log() hands back /dev/null under a dry run —
# that is where its guard lives — so every `: > "$log"` and `>>"$log"` whose
# target came from it writes nothing. Rather than listing those sites (a list
# rots), find the VARIABLES assigned from step_log and treat redirects to them
# as safe. The chain is then: step_log is guarded (asserted separately, below),
# therefore these targets are /dev/null, therefore these writes are not writes.
# ⚠️ IF SOMEONE REMOVES step_log's GUARD, the separate assertion goes red — the
# derivation does not quietly keep blessing them.
FROM_STEP_LOG = re.compile(r'(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)=\$\(step_log\b')


def step_log_vars(lines):
    out = set()
    for l in lines:
        for m in FROM_STEP_LOG.finditer(strip_comment(l)):
            out.add(m.group(1))
    return out


rows = []
for path in sorted(glob.glob(os.path.join(src, '*.sh'))):
    base = os.path.basename(path)
    # The wrappers PERFORM the actions they guard; that is their job.
    if base == 'dryrun.sh':
        continue
    lines = open(path, encoding='utf-8').read().split('\n')
    extents = {}
    i = 0
    while i < len(lines):
        m = DEF.match(lines[i])
        if m:
            s = strip_comment(lines[i])
            depth = s.count('{') - s.count('}')
            j = i
            while depth > 0 and j + 1 < len(lines):
                j += 1
                s = strip_comment(lines[j])
                depth += s.count('{') - s.count('}')
            extents[m.group(1)] = (i, j)
            i = j + 1
        else:
            i += 1

    def enclosing(k, extents=extents):
        best = None
        for fn, (a, b) in extents.items():
            if a <= k <= b and (best is None or a > extents[best][0]):
                best = fn
        return best

    first_guard = {}
    for fn, (a, b) in extents.items():
        for k in range(a, b + 1):
            if 'dry::' in strip_comment(lines[k]):
                first_guard[fn] = k
                break

    hd = heredoc_lines(lines)
    safe_targets = step_log_vars(lines)
    for k, raw in enumerate(lines):
        if k in hd:
            continue
        code = strip_comment(raw)
        kind = mutation_kind(code, safe_targets)
        if kind is None:
            continue
        if 'dry::fs' in code or 'dry::rt' in code:
            continue
        fn = enclosing(k)
        if fn is not None and fn in first_guard and first_guard[fn] < k:
            continue
        where = fn or '<top level>'
        rows.append('MUT|%s|%d|%s|%s|%s' % (base, k + 1, kind, where, code.strip()[:90]))

print('COUNT|%d' % len(rows))
for r in rows:
    print(r)
PY
) || { printf '  FAIL  the derivation itself failed\n'; exit 1; }

unguarded=0
while IFS='|' read -r tag a b c d e; do
  case "$tag" in
    COUNT) unguarded=$a ;;
    MUT)   printf '        %s:%s  (%s, in %s)\n           %s\n' "$a" "$b" "$c" "$d" "$e" ;;
  esac
done <<<"$REPORT"

if [[ $unguarded -eq 0 ]]; then
  ok "every derived mutation in installer/*.sh is behind a dry:: guard"
else
  bad "$unguarded mutation site(s) are reachable with no dry:: guard (listed above)"
fi

# ── The wrappers exist and are not decoration ────────────────────────────────
for fn in dry::on dry::would dry::sim dry::fs dry::rt dry::skip; do
  if grep -q "^${fn}() {" "$SRC/dryrun.sh"; then
    ok "$fn is defined"
  else
    bad "$fn is missing from installer/dryrun.sh"
  fi
done

# The flag has to reach the wrappers, or every guard above is dead code.
if grep -q -- '--dry-run) ARG_DRY_RUN=1' "$SRC/ui.sh"; then
  ok "--dry-run is accepted by the option loop"
else
  bad "--dry-run is not wired into the option loop, so no guard can ever fire"
fi
if grep -q 'ARG_DRY_RUN' "$SRC/dryrun.sh"; then
  ok "dry::on reads the flag the option loop sets"
else
  bad "dry::on does not read ARG_DRY_RUN"
fi

# The link the step_log derivation above RESTS ON. Those `: > "$log"` writes are
# blessed because step_log hands back /dev/null in a dry run; if that guard ever
# goes, the derivation would keep blessing them and say nothing. So the chain is
# asserted, not assumed.
if sed -n '/^step_log() {/,/^}/p' "$SRC/execute.sh" | grep -q 'dry::on'; then
  ok "step_log is guarded, which is what makes its log targets safe"
else
  bad "step_log has no dry:: guard, so every write to a step log is a real write"
fi

# ── The assertion that cannot be fooled: RUN IT ──────────────────────────────
# ⭐⭐ A STATIC CHECK SAYS NO MUTATION ESCAPED THE WRAPPERS. THIS SAYS NO MUTATION
# HAPPENED. Neither implies the other, and only the second is the promise made
# to the user. It earned its place immediately: the static half had been tuned
# to drop redirect detection, and the first real --dry-run died on an unguarded
# NOTES.md that the static half was blind to.
#
# 🚨 A THROWAWAY HOME, ALWAYS. Rung `w` is not a dry run (the moves happen during
# the INTERVIEW, before the rung is chosen), which is the whole defect this
# feature exists to close — so a run pointed at a real HOME is exactly the
# accident being prevented.
# ⚠️ ANSWERS ARE 200 BLANK LINES: every prompt takes its own default, so this
# needs no knowledge of the question sequence and cannot rot when one is added.
# The run is DEFAULT RUNG [A], deliberately — the rung that does the most.
SETUP_BIN=${SETUP_BIN:-$SCRIPT_DIR/../droste-setup.sh}
if [[ ! -r $SETUP_BIN ]]; then
  SETUP_BIN=$(mktemp "${TMPDIR:-/tmp}/droste-setup.XXXXXX")
  "$SCRIPT_DIR/assemble-droste-setup.sh" > "$SETUP_BIN" || {
    bad "could not assemble an installer to run"; SETUP_BIN=""; }
fi

if [[ -n $SETUP_BIN ]]; then
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/droste-dryrun.XXXXXX")
  ANS=$LAB/answers
  printf '\n%.0s' $(seq 1 200) > "$ANS"
  DRYHOME=$LAB/home
  mkdir -p "$DRYHOME"
  # The fingerprint is taken from a SIBLING directory, never from inside the
  # HOME being watched, or the act of measuring would be the change it reports.
  fingerprint() { find "$DRYHOME" -mindepth 1 -printf '%P|%y|%s\n' 2>/dev/null | LC_ALL=C sort; }
  # 🚨 THE ONE THING A DRY RUN LEAVES BEHIND IS NOT OURS, AND IT IS DERIVED
  # RATHER THAN EXCUSED. The very first `podman ps` on a machine with no
  # container storage CREATES that storage (~/.local/share/containers, plus an
  # empty ~/.config). That is podman initialising itself in response to a READ —
  # and reads are what a rehearsal is made of, so the alternative is a dry run
  # that cannot see whether a box exists.
  # ⭐ SO THE BASELINE IS MEASURED, NOT LISTED: a throwaway HOME gets a bare
  # container-state read and nothing else, and whatever THAT creates is
  # subtracted. If podman changes what it touches, this follows it; if the
  # installer ever writes one of those paths itself, the path is already in the
  # baseline and the assertion would miss it — which is why the baseline is a
  # bare `ps` and not a whole run.
  RTHOME=$LAB/rthome
  mkdir -p "$RTHOME"
  HOME=$RTHOME timeout 60 "${RUNTIME_PROBE:-podman}" ps -a >/dev/null 2>&1 || :
  runtime_made=$(find "$RTHOME" -mindepth 1 -printf '%P\n' 2>/dev/null | LC_ALL=C sort)
  if [[ -n $runtime_made ]]; then
    printf '  note  %s creates %s path(s) in a fresh HOME on a bare read;\n' \
      "${RUNTIME_PROBE:-podman}" "$(printf '%s\n' "$runtime_made" | grep -c .)"
    printf '        those are subtracted below, measured rather than listed\n'
  fi
  # Subtract by PATH, comparing only what is left.
  # Subtracted by PATH, never by the whole record: podman's db.sql changes SIZE
  # between the two fingerprints, so matching the full `path|type|size` line
  # would leave it behind and report podman's own bookkeeping as our write.
  fingerprint() {
    find "$DRYHOME" -mindepth 1 -printf '%P|%y|%s\n' 2>/dev/null \
      | awk -F'|' 'NR==FNR { skip[$0] = 1; next } !($1 in skip)' \
            <(printf '%s\n' "$runtime_made") - \
      | LC_ALL=C sort
  }
  before=$(fingerprint)
  HOME=$DRYHOME DROSTE_SETUP_INPUT=$ANS DROSTE_SETUP_FSTYPE=ext4 \
    timeout 300 bash "$SETUP_BIN" --ascii --dry-run > "$LAB/out" 2>&1 || :
  after=$(fingerprint)

  if [[ -s $LAB/out ]] && grep -q 'WOULD DO' "$LAB/out"; then
    ok "a headless --dry-run completes and predicts actions"
  else
    bad "the headless --dry-run produced no predictions (see $LAB/out)"
  fi

  if [[ $before == "$after" ]]; then
    ok "and its HOME is unchanged afterwards — nothing was created, written or removed"
  else
    bad "--dry-run CHANGED ITS HOME:"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/        /' || :
  fi

  # 🚨 THE ONE THING A DRY RUN DOES LEAVE BEHIND, AND IT IS NOT OURS. The very
  # first `podman ps` on a machine with no container storage CREATES that
  # storage (~/.local/share/containers). It is podman initialising itself in
  # response to a READ — and reads are what a rehearsal is made of, so the
  # alternative is a dry run that cannot see whether a box exists. Reported
  # rather than hidden: on any machine that has ever run podman it is a no-op,
  # and on one that has not, the directory is empty and inert.
  if printf '%s\n' "$after" | grep -q '^\.local/share/containers'; then
    printf '  note  podman initialised its own storage under ~/.local/share/containers\n'
    printf '        (a first-run side effect of reading container state, not an installer write)\n'
  fi
  rm -rf "$LAB"
fi

printf '\n%s passed, %s failed\n\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
