#!/usr/bin/env bash
# llama-options.sh — DEV-TIME drift report for llama.env.
#
# Enumerates what the PINNED llama-server actually accepts and compares it
# against our hand-authored targets/llama/templates/llama.env. Run it when the
# llama pin moves; the output is a work list for editing that file by hand.
#
# ⭐ WHY THIS IS NOT A BUILD STEP (it used to be, as gen_llama_env.sh):
#   1. Presentation of the config surface is ours to control, and a file printed
#      by a shell script is not a file anyone can lay out.
#   2. `llama-server --help` CANNOT RUN on a GPU-less machine. It dies with
#      SIGILL (exit 132) after "ggml_cuda_init: failed to initialize ROCm: no
#      ROCm-capable device is detected", so on a CI runner the generated file
#      silently shipped DEGRADED. Hiding the GPUs does not help — the failure IS
#      "no device". Moving the enumeration to a machine that HAS one is the fix.
# The build keeps a cheap guarantee in place of the old one: targets/Container.llama
# scans the binary for the LLAMA_ARG_* names we depend on, which needs no GPU.
#
# WHERE TO RUN IT: on a box with the GPU, against the real binary. In-box:
#   podman exec droste-llama-halo llama-server --help > /tmp/llama-help.txt
#   scripts/llama-options.sh --help-file /tmp/llama-help.txt
# or directly, if you are standing on the hardware:
#   scripts/llama-options.sh
#
# ⚠️ A CAPTURED --help IS FINE HERE AND IS NOT "VENDORING ONE". The old rule
# (never vendor a captured --help) protected enumerate-from-the-binary at BUILD
# time, where a stale capture would silently outlive its pin. Here the capture is
# an input to a report a human reads, taken from the binary being asked about.
#
# Usage: llama-options.sh [--help-file FILE] [--env-file FILE] [--list]
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SERVER=${LLAMA_SERVER_BIN:-llama-server}
ENVFILE="$HERE/../targets/llama/templates/llama.env"
HELPFILE=""
LIST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --help-file) HELPFILE=$2; shift 2 ;;
        --env-file)  ENVFILE=$2;  shift 2 ;;
        --list)      LIST=1; shift ;;
        -h|--help)   sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die()  { printf 'llama-options: ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'llama-options: %s\n' "$*" >&2; }
TAB=$(printf '\t')

# ── 1) get the help text ─────────────────────────────────────────────────────
if [ -n "$HELPFILE" ]; then
    [ -r "$HELPFILE" ] || die "cannot read $HELPFILE"
    help_text=$(cat "$HELPFILE")
else
    # ⚠️ EXIT STATUS IS THE WRONG TEST (cost a build in s51): llama-server prints
    # the whole help and can still exit non-zero on its way out. The only
    # question that matters is whether we HAVE usable help.
    rc=0
    help_text=$(timeout 60 "$SERVER" --help 2>&1) || rc=$?
    grep -q '(env: ' <<<"$help_text" || die \
        "'$SERVER --help' gave no usable output (exit $rc). On a GPU-less machine this is expected — capture the help on the hardware and pass --help-file."
fi

# ── 2) enumerate: every option, its flags, its env var, its default ──────────
# Both passes are lifted verbatim from the old build-time generator, where they
# were proven against this pin. Shape relied on, all visible in the printer:
#   · an option entry begins on a line whose first non-space char is "-"
#   · a section heading is a rule line of 3+ dashes with the name inside
#   · "(env: X)" and "(default: …)" sit on continuation lines under the option
# ⚠️ THREE LITERAL DASHES BELOW, NOT AN INTERVAL. Debian's awk is mawk, which
# does not implement {n,m} — it read `-{3,}` as a single dash, so every option
# line looked like a heading and the pass returned zero.
table=$(awk '
    function flush(   ) {
        if (pending == "") return
        printf "%s\t%s\t%s\t%s\n", section, pending, pendenv, penddef
        pending = ""; pendenv = ""; penddef = ""
    }
    # "(default: X)" on the given line, possibly unclosed (it wraps at 70 cols).
    function readdef(l) {
        if (match(l, /\(default: [^)]*\)/)) {
            penddef = substr(l, RSTART + 10, RLENGTH - 11); defopen = 0
        } else if (match(l, /\(default:[^)]*$/)) {
            penddef = substr(l, RSTART + 9); sub(/^[[:space:]]+/, "", penddef); defopen = 1
        }
    }
    function readenv(l) {
        if (match(l, /\(env: [A-Z][A-Z0-9_]*\)/)) pendenv = substr(l, RSTART + 6, RLENGTH - 7)
    }
    # A section rule line: ----- common params -----
    # ⚠️ THREE LITERAL DASHES, NOT AN INTERVAL. Debian awk is mawk, which does not
    # implement {n,m}: it read -{3,} as ONE dash, so every option line looked like
    # a heading and the pass returned zero.
    /^[[:space:]]*---/ {
        s = $0
        gsub(/^[[:space:]]*-+[[:space:]]*/, "", s)
        gsub(/[[:space:]]*-+[[:space:]]*$/, "", s)
        if (s != "") { flush(); section = s; next }
    }
    {
        line = $0
        # ⭐ IS THIS A NEW OPTION? Decide FIRST. Reading the default before knowing
        # that overwrites the PENDING option with the NEW line default -- which
        # attributed every default to the option above it.
        isopt = 0
        if (line ~ /^[[:space:]]*-/) {
            head = line; gsub(/^[[:space:]]+/, "", head)
            # Consume the FLAG COLUMN by SHAPE. ⚠️ It cannot be split off at "2+
            # spaces": llama.cpp pads BETWEEN the short and long spelling, and a
            # long-only option BEGINS with that gap. A dash-led wrapped line
            # ("- set to 0.0 to disable") fails this and is skipped, for free.
            if (match(head, /^((-[-A-Za-z0-9_]+),?[ \t]*([A-Z][A-Z0-9_]*)?[ \t]*)+/)) {
                col = substr(head, 1, RLENGTH)
                n = split(col, parts, /[,[:space:]]+/)
                got = ""
                for (i = 1; i <= n; i++) {
                    p = parts[i]
                    if (p ~ /^--[A-Za-z][-A-Za-z0-9_]*$/ || p ~ /^-[A-Za-z][-A-Za-z0-9_]*$/)
                        got = (got == "" ? p : got ", " p)
                }
                if (got != "") isopt = 1
            }
        }
        if (isopt) {
            flush()
            pending = got; defopen = 0; penddef = ""; pendenv = ""
            readdef(line); readenv(line)
            next
        }
        # a continuation line of the option we are holding
        if (defopen) {
            t = line; sub(/^[[:space:]]+/, "", t)
            if (match(t, /^[^)]*\)/)) { penddef = penddef " " substr(t, 1, RLENGTH - 1); defopen = 0 }
            else                      { penddef = penddef " " t }
            sub(/^[[:space:]]+/, "", penddef)
        } else {
            readdef(line)
        }
        if (pending != "") readenv(line)
    }
    END { flush() }
' <<<"$help_text")

[ -n "$table" ] || die "parsed no options out of the help text — the layout probably moved with the pin; fix the awk above."

n_opt=$(printf '%s\n' "$table" | grep -c .)
n_env=$(printf '%s\n' "$table" | awk -F'\t' '$3 != "" { n++ } END { print n + 0 }')
note "binary: $n_opt options, $n_env of them with a native environment variable"

if [ "$LIST" = 1 ]; then
    printf '%s\n' "$table"
    exit 0
fi

# 🚨 PLAUSIBILITY GATE. Every comparison below is "what the binary has" against
# "what our file says", so a TRUNCATED capture makes almost our entire config
# surface look stale — and acting on that report would delete ~130 working
# variables. The pin prints ~249 options; anything far below that is a bad
# capture, not a shrunken upstream.
MIN_PLAUSIBLE_OPTIONS=${MIN_PLAUSIBLE_OPTIONS:-150}
if [ "$n_opt" -lt "$MIN_PLAUSIBLE_OPTIONS" ]; then
    note "⚠️  only $n_opt options parsed (expected >= $MIN_PLAUSIBLE_OPTIONS)."
    note "⚠️  That is almost certainly a TRUNCATED OR PARTIAL --help capture, not a"
    note "⚠️  smaller upstream. The 'names our file offers' section below will be"
    note "⚠️  mostly FALSE POSITIVES — do not act on it. Re-capture the full help,"
    note "⚠️  or pass MIN_PLAUSIBLE_OPTIONS=<n> if the surface really did shrink."
    printf '\n'
fi

# ── 3) compare against the hand-authored template ───────────────────────────
[ -r "$ENVFILE" ] || die "cannot read $ENVFILE"
note "comparing against $ENVFILE"
printf '\n'

# 3a. options the binary has that our file never mentions
missing_flags=$(printf '%s\n' "$table" | awk -F'\t' '{ print $2 }' \
    | tr ',' '\n' | sed 's/^ *//' | grep . | sort -u \
    | while read -r f; do grep -qF -- "$f" "$ENVFILE" || printf '%s\n' "$f"; done)

# 3b. env vars the binary has that our file never mentions
missing_envs=$(printf '%s\n' "$table" | awk -F'\t' '$3 != "" { print $3 }' | sort -u \
    | while read -r e; do grep -qw -- "$e" "$ENVFILE" || printf '%s\n' "$e"; done)

# 3c. 🚨 THE DANGEROUS DIRECTION: names OUR FILE offers that the binary does NOT
# read. A user setting one of those gets silence, and the file is the thing that
# told them it would work. TURBO_* are exempt — they are documented as inert.
# ⭐ AND DROSTE'S OWN NAMES ARE EXEMPT BY CONSTRUCTION, not by a list: the pattern
# anchors on the NATIVE LLAMA_/HF_ prefixes, so DROSTE_LLAMA_* — names upstream has
# never heard of — cannot match it. The catch-all needed a hand-written exception
# here only while it wore a native-looking name without the DROSTE_ prefix.
stale=$(grep -oE '^# (LLAMA_[A-Z_0-9]+|HF_[A-Z_0-9]+)=' "$ENVFILE" \
    | sed 's/^# //; s/=$//' | sort -u \
    | while read -r e; do
        grep -q "(env: $e)" <<<"$help_text" || printf '%s\n' "$e"
      done)

# 3d. defaults our file states that the binary now disagrees with
changed=$(printf '%s\n' "$table" | awk -F'\t' -v OFS='\t' '$3 != "" && $4 != "" { print $3, $4 }' \
    | while IFS="$TAB" read -r e d; do
        ours=$(grep -oE "^# $e=[^ ]*" "$ENVFILE" | head -1 | sed "s/^# $e=//") || true
        grep -q "^# $e=" "$ENVFILE" || continue
        want=${d%%,*}; want=${want%% *}
        case "$want" in ''|*[!0-9.eE+-]*) continue ;; esac   # compare numbers only
        [ "$ours" = "$want" ] || printf '%s\t%s\t%s\n' "$e" "$ours" "$want"
      done)

report() {
    local title=$1 body=$2 hint=$3
    printf '== %s ==\n' "$title"
    if [ -z "$body" ]; then printf '   (none)\n\n'; return; fi
    printf '%s\n' "$body" | sed 's/^/   /'
    printf '   -> %s\n\n' "$hint"
}
report "options in the binary, absent from llama.env" "$missing_flags" \
       "add them under a group, or record why they are not worth naming"
report "env vars in the binary, absent from llama.env" "$missing_envs" \
       "each is a setting a user cannot discover from our file"
report "NAMES OUR FILE OFFERS THAT THE BINARY DOES NOT READ" "$stale" \
       "🚨 remove or rename these — setting one does nothing, silently"
report "defaults that moved" "$changed" \
       "columns: variable, what llama.env says, what the binary says"

n_bad=0
for v in "$missing_flags" "$missing_envs" "$stale" "$changed"; do
    [ -z "$v" ] || n_bad=$((n_bad + $(printf '%s\n' "$v" | grep -c .)))
done
note "$n_bad item(s) need a decision"
# Exit 0 either way: this is a report a human acts on, not a gate.
