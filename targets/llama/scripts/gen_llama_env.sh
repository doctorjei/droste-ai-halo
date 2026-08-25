#!/usr/bin/env bash
# gen_llama_env.sh — BUILD-TIME generator for the llama.env TEMPLATE.
#
# Runs as a RUN step in Container.llama (after llama-server is in place) and emits
# /opt/resources/templates/llama.env — the template that templates.yaml seeds to
# /opt/data/llama.env (if_missing) at container start.
#
# Enumeration strategy (design: complete, drift-free, no hand-maintenance):
#   1. PRIMARY: parse `llama-server --help`. Every flag that has a native env var
#      carries an `(env: LLAMA_ARG_X)` annotation; the flag's `(default: …)` text
#      supplies the commented default value.
#   2. FALLBACK (if --help won't run in the build env, e.g. GPU-probing aborts, or
#      its output carries no env annotations): string-scan the llama-server binary
#      (+ its local libs) for LLAMA_ARG_[A-Z0-9_]+ literals — the arg table stores
#      the env names as plain strings. Names only; defaults left empty.
# Either way the REQUIRED vars (REQUIRED_VARS below — the ones this image's
# runtime contract depends on, whether emitted active, commented or passed as a
# flag) are VERIFIED against the enumerated table: a rename upstream fails the
# IMAGE BUILD loudly (verify-at-build by design).
#
# ⭐ SECOND PASS, ADDED s51 — THE FLAGS THAT HAVE NO ENV VAR.
# An env-annotation enumerator can only ever see the flags upstream chose to give
# an env var, and at this pin that is roughly half of what `--help` prints: 128 of
# 247. The other 119 — the whole sampler family, LoRA, grammars, the one-shot model
# presets — appeared NOWHERE in the file we tell the user IS the config surface.
# That gap is ours, not upstream's (see notebook/resources/exposure-audit-s48/
# llama.md), and the Feature Exposure rule in CONVENTIONS.md says it has to close.
#
# So a second, independent pass over the same help text collects EVERY option
# spelling and the section it printed under, and every flag with no env var is
# listed by name under its own section, routed to LLAMA_EXTRA_ARGS.
#
# ⚠️ THE TWO PASSES ARE DELIBERATELY INDEPENDENT, AND THE SECOND MAY NOT BREAK THE
# FIRST. Pass 1 is proven against this pin and carries the build-failing drift
# gate; pass 2 is a text-shape heuristic over help output this script cannot test
# at authoring time. If pass 2 comes back implausibly thin the file says so and the
# build CONTINUES — a cosmetic listing must never fail an image that is otherwise
# correct. The shortfall is reported to the build log, so check the log line
# "flag enumeration" after a build that bumps the llama pin.
#
# Usage: gen_llama_env.sh [output-path]   (env override: LLAMA_SERVER_BIN)
set -euo pipefail

OUT=${1:-/opt/resources/templates/llama.env}
SERVER=${LLAMA_SERVER_BIN:-llama-server}
# Below this many enumerated flags, pass 2 is treated as having failed to parse the
# help layout rather than as a genuinely small surface. The pin prints 247.
MIN_PLAUSIBLE_FLAGS=${MIN_PLAUSIBLE_FLAGS:-100}

die() { printf 'gen_llama_env: ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'gen_llama_env: %s\n' "$*" >&2; }

# Our one active (uncommented) value. Expressed as an env LINE, not a hardcoded
# flag, because CLI flags override env in llama.cpp — an env line keeps user edits
# winning (which is also exactly why the port below is NOT emitted active).
ACTIVE_HOST=0.0.0.0
# The port is NOT emitted active — the launcher owns it (see the emitted comment
# block below). This value only names llama-server's own default in that comment
# and on the commented LLAMA_ARG_PORT line.
DEFAULT_PORT=8080
# Slot save/restore: the pinned fork ships --slot-save-path with NO env
# annotation, so there is no LLAMA_ARG_SLOT_SAVE_PATH to set here — the flag is
# added by the entrypoint's launch line instead (targets/llama/build-spec,
# llama_pre_launch). This path only feeds the explanatory comment block below —
# keep it in step with the build-spec's flag (saved slots are cache class, so
# they live on the program-cache root, not /opt/data).
SLOTS_DIR=/opt/program-cache/slots
# Vars that MUST exist in the pinned llama-server's arg table (build fails if not).
# LLAMA_ARG_PORT stays on this list even though it is emitted COMMENTED: the port
# knob has to keep existing in the pinned binary for the commented line (and the
# server lane, which reads the env var) to mean anything, so the drift gate still
# covers it — the gate checks the BINARY's arg table, not what we emit active.
REQUIRED_VARS=(LLAMA_ARG_HOST LLAMA_ARG_PORT LLAMA_ARG_MODEL)
# Vars excluded from the generic commented list (they get dedicated blocks above
# it). LLAMA_ARG_SLOT_SAVE_PATH is deliberately NOT excluded: absent from the
# current pin, but if a future pin gains it, it should flow through as an
# ordinary enumerated (commented) flag — never REQUIRED.
SPECIAL_VARS="LLAMA_ARG_HOST LLAMA_ARG_PORT LLAMA_ARG_MODEL"
# Env-having flags whose env name is NOT spelled LLAMA_ARG_*, so pass 1's anchored
# pattern cannot see them. Enumerated from the pin; each is verified to be present
# in the help text before it is emitted, so a rename upstream drops the line
# rather than shipping a variable the binary does not read.
# ⚠️ --api-key is the one that matters: this box binds 0.0.0.0, and the file used
# to list the API_KEY_FILE variant while omitting the direct one.
OTHER_ENV_VARS="LLAMA_API_KEY HF_TOKEN"

TAB=$(printf '\t')

# ── 1) enumerate env-having flags → table of "NAME<TAB>DEFAULT" lines ─────────
# timeout: --help may probe for a GPU and hang on a GPU-less builder; a timeout
# (exit 124) is treated like any other --help failure → string-scan fallback.
mode=help
help_text=$(timeout 60 "$SERVER" --help 2>&1) || mode=scan
if [ "$mode" = help ] && ! grep -q '(env: LLAMA_ARG_' <<<"$help_text"; then
    mode=scan
fi

if [ "$mode" = help ]; then
    table=$(awk '
        {
            line = $0
            # A new option entry (first non-space char is "-") resets the pending
            # default; wrapped description lines are indented and rarely dash-led.
            if (line ~ /^[[:space:]]*-/) { def = "" }
            if (match(line, /\(default: [^)]*\)/)) {
                def = substr(line, RSTART + 10, RLENGTH - 11)
            }
            while (match(line, /\(env: LLAMA_ARG_[A-Z0-9_]+\)/)) {
                name = substr(line, RSTART + 6, RLENGTH - 7)
                printf "%s\t%s\n", name, def
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' <<<"$help_text")
else
    note "'$SERVER --help' unusable here — falling back to binary string-scan (names only, no defaults)"
    bin_path=$(command -v "$SERVER") || die "cannot locate '$SERVER' for the fallback scan"
    table=$( { grep -haoE 'LLAMA_ARG_[A-Z0-9_]+' "$bin_path" /usr/local/lib64/lib*.so* 2>/dev/null || true; } \
             | sed "s/\$/${TAB}/" )
fi

# de-duplicate by name (keep first default), sort for a stable template
table=$(printf '%s\n' "$table" | awk -F'\t' 'NF && !seen[$1]++' | sort -t"$TAB" -k1,1)
[ -n "$table" ] || die "no LLAMA_ARG_* env-having flags enumerated from '$SERVER' (mode: $mode)"

count=$(printf '%s\n' "$table" | wc -l)
note "enumerated $count env-having flags from '$SERVER' (mode: $mode)"

# ── 1b) enumerate EVERY option, with its section and whether it has an env var ─
# Emits "SECTION<TAB>FLAGS<TAB>ENVNAME" (ENVNAME empty when the option has none).
# Best-effort by construction: it reads the LAYOUT of the help text, not a
# guaranteed interface. See the header note on why it may not fail the build.
#
# Shape it relies on, all of it visible in the pinned fork's printer:
#   · an option entry begins on a line whose first non-space character is "-"
#   · the flag column is separated from the description by 2+ spaces
#   · a section heading is a rule line of 3+ dashes with the name inside it
#   · the "(env: X)" annotation is on its own continuation line under its option
flag_table=""
if [ "$mode" = help ]; then
    flag_table=$(awk -v FS='\n' '
        function flush(   i, n, out) {
            if (pending == "") return
            printf "%s\t%s\t%s\n", section, pending, pendenv
            pending = ""; pendenv = ""
        }
        # Section heading: ----- common params ----- (and any similar rule line).
        # ⚠️ THREE LITERAL DASHES, NOT AN INTERVAL. Debian`s /usr/bin/awk is mawk,
        # and mawk 1.3.4 does not implement {n,m} — it read `-{3,}` as a single
        # dash, which made every option line look like a section heading and the
        # whole pass return zero. Do not "tidy" this back into an interval.
        /^[[:space:]]*---/ {
            s = $0
            gsub(/^[[:space:]]*-+[[:space:]]*/, "", s)
            gsub(/[[:space:]]*-+[[:space:]]*$/, "", s)
            if (s != "") { flush(); section = s; next }
        }
        {
            line = $0
            # continuation line carrying the env annotation for the pending option
            if (match(line, /\(env: [A-Z][A-Z0-9_]*\)/)) {
                e = substr(line, RSTART + 6, RLENGTH - 7)
                if (pending != "") pendenv = e
            }
            # new option entry?
            if (line !~ /^[[:space:]]*-/) next
            head = line
            gsub(/^[[:space:]]+/, "", head)
            # Consume the FLAG COLUMN by its shape — a run of "flag[,] [PLACEHOLDER]"
            # groups — rather than by splitting on the gap before the description.
            # ⚠️ The gap does not identify the column: llama.cpp pads BETWEEN the short
            # and long spelling too ("-t,    --threads N"), so a gap-split drops every
            # long form, and an option with no short form starts with the gap and drops
            # everything. Both of those were live bugs here. Description text ends the
            # run because it is lowercase, and a dash-led wrapped line ("- set to 0.0
            # to disable") fails to match at all, which is why it is skipped below.
            if (!match(head, /^((-[-A-Za-z0-9_]+),?[ \t]*([A-Z][A-Z0-9_]*)?[ \t]*)+/)) next
            head = substr(head, 1, RLENGTH)
            n = split(head, parts, /[,[:space:]]+/)
            got = ""
            for (i = 1; i <= n; i++) {
                p = parts[i]
                # a real flag: --long-name, or -s / -abc (letters, never -1 or -)
                if (p ~ /^--[A-Za-z][-A-Za-z0-9_]*$/ || p ~ /^-[A-Za-z][-A-Za-z0-9_]*$/) {
                    got = (got == "" ? p : got ", " p)
                }
            }
            if (got == "") next
            flush()
            pending = got
            # same-line env annotation, if the printer ever puts one there
            if (match(line, /\(env: [A-Z][A-Z0-9_]*\)/)) {
                pendenv = substr(line, RSTART + 6, RLENGTH - 7)
            }
        }
        END { flush() }
    ' <<<"$help_text")
fi

flag_count=0
[ -z "$flag_table" ] || flag_count=$(printf '%s\n' "$flag_table" | grep -c . || true)
if [ "$flag_count" -lt "$MIN_PLAUSIBLE_FLAGS" ]; then
    note "flag enumeration: only $flag_count options parsed out of the help layout (expected >= $MIN_PLAUSIBLE_FLAGS) — emitting the env-var list ONLY, and saying so in the file. If the llama pin moved, the help layout probably moved with it; fix the pass-2 awk in this script."
    flag_table=""
else
    envless=$(printf '%s\n' "$flag_table" | awk -F'\t' '$3 == "" { n++ } END { print n + 0 }')
    note "flag enumeration: $flag_count options across $(printf '%s\n' "$flag_table" | cut -f1 | sort -u | grep -c .) sections; $envless of them have no env var and will be listed for LLAMA_EXTRA_ARGS"
fi

# ── 2) VERIFY the active/required vars exist in the enumerated table ──────────
names=$(printf '%s\n' "$table" | cut -f1)
for v in "${REQUIRED_VARS[@]}"; do
    grep -qx "$v" <<<"$names" \
        || die "required env var '$v' NOT in the pinned llama-server's arg table — upstream rename? Fix the emitted lines (or the launch flags) before shipping."
done
note "verified required vars: ${REQUIRED_VARS[*]}"

# ── 3) emit the template ──────────────────────────────────────────────────────
mkdir -p "$(dirname "$OUT")"
{
    printf '%s\n' \
        "# llama.env -- llama-server configuration (this file IS the config surface)." \
        "#" \
        "# GENERATED AT IMAGE BUILD from the pinned llama-server's own argument table" \
        "# (mode: $mode; $count env-having flags, $flag_count options in total), so it" \
        "# describes THIS binary rather than a version of the documentation." \
        "#" \
        "# Seeded to /opt/data/llama.env on first start and NEVER overwritten -- your" \
        "# edits here win." \
        "#" \
        "# TWO KINDS OF SETTING, and the difference decides where you write it:" \
        "#" \
        "#   Roughly half of llama-server's options have a NATIVE ENVIRONMENT VARIABLE." \
        "#   Those are listed below as commented assignments; uncomment one to set it." \
        "#   Values are used as-is (no shell quoting or expansion beyond this file being" \
        "#   sourced)." \
        "#" \
        "#   The other half have NO environment variable at all -- upstream never gave" \
        "#   them one. They are listed by NAME under the same section headings, and the" \
        "#   way to set them is LLAMA_EXTRA_ARGS near the top of this file." \
        "#" \
        "# **A COMMAND-LINE FLAG BEATS ITS ENVIRONMENT VARIABLE in llama.cpp, silently." \
        "# So a flag you put in LLAMA_EXTRA_ARGS overrides the matching assignment here." \
        "#" \
        "# NOTE: LLAMA_CACHE is deliberately NOT listed. Unset, llama-server shares" \
        "# the standard HF cache (~/.cache/huggingface/hub) with the other ports;" \
        "# setting it would re-separate llama's downloads. Leave it unset." \
        ""
    if [ -z "$flag_table" ]; then
        printf '%s\n' \
            "# ⚠️ THIS FILE IS INCOMPLETE. The build could not read the layout of this" \
            "# binary's --help, so only the options that carry an environment variable are" \
            "# listed below. The rest exist and work -- run 'llama-server --help' in the box" \
            "# to see them, and set them through LLAMA_EXTRA_ARGS." \
            ""
    fi
    printf '%s\n' \
        "# ── active defaults (droste) ─────────────────────────────────────────────────" \
        "LLAMA_ARG_HOST=$ACTIVE_HOST" \
        "" \
        "# NO active LLAMA_ARG_PORT line ON PURPOSE — it would not take effect. The launcher" \
        "# appends '--port' to the llama-server command line from PORT in /opt/data/server.env" \
        "# (default $DEFAULT_PORT), and llama.cpp resolves a CLI flag OVER the env var without saying" \
        "# so — uncommenting the line below would look authoritative and do nothing. Change the" \
        "# port in server.env, then restart the box." \
        "# (It does still apply where nothing appends '--port': a direct 'podman run', whose" \
        "# server lane reads no server.env, and a llama-server you start by hand in the box.)" \
        "# LLAMA_ARG_PORT=$DEFAULT_PORT" \
        "" \
        "# ── slot save/restore ────────────────────────────────────────────────────────" \
        "# Slot save/restore is enabled via the launch flag --slot-save-path $SLOTS_DIR," \
        "# added by the entrypoint's launch line (no env line needed here). To change" \
        "# the location, put your own '--slot-save-path <dir>' in LLAMA_EXTRA_ARGS" \
        "# below — later flags win in llama-server's parser." \
        ""
    printf '%s\n' \
        "# ── model ────────────────────────────────────────────────────────────────────" \
        "# LLAMA_ARG_MODEL= # REQUIRED — server won't start until set (absolute path, or use -hf via LLAMA_EXTRA_ARGS)" \
        "#   -hf downloads land in the shared HF cache (~/.cache/huggingface)." \
        "#   Local GGUFs: bind your collection read-only at /opt/models and point here." \
        ""
    printf '%s\n' \
        "# ── extra args ───────────────────────────────────────────────────────────────" \
        "# Catch-all for every flag WITHOUT a native env var (and anything else)," \
        "# appended to the llama-server command line. Quote the WHOLE value (this file is" \
        "# sourced bash); it is then whitespace-split into separate args — individual" \
        "# args cannot themselves contain spaces." \
        "#" \
        "# **THAT SPLIT IS WHY A GRAMMAR OR A JSON SCHEMA CANNOT GO HERE INLINE: both" \
        "# contain spaces. Use the file forms instead -- --grammar-file and -jf /" \
        "# --json-schema-file -- and put the grammar in a file on /opt/data." \
        "#" \
        "# Example:" \
        "#   LLAMA_EXTRA_ARGS=\"-hf org/repo:Q4_K_M --jinja --temp 0.7\"" \
        "# LLAMA_EXTRA_ARGS=" \
        ""
    # Env vars the binary reads under a name that is not LLAMA_ARG_* — pass 1 is
    # anchored on that prefix and cannot see them. Only emitted when the help text
    # proves this pin still has them.
    other_shown=""
    for v in $OTHER_ENV_VARS; do
        grep -q "(env: $v)" <<<"$help_text" 2>/dev/null || continue
        other_shown="$other_shown $v"
    done
    if [ -n "$other_shown" ]; then
        printf '%s\n' \
            "# ── authentication and downloads ─────────────────────────────────────────────" \
            "# These two are read from the environment like the LLAMA_ARG_* list below, but" \
            "# under their own names." \
            "#" \
            "# **THIS BOX BINDS 0.0.0.0 AND SHIPS NO AUTHENTICATION. Anything that can route" \
            "# to it can use the model. LLAMA_API_KEY is the one knob that changes that." \
            "# (--api-key on the command line beats it.)" \
            "#" \
            "# HF_TOKEN is what makes -hf work against a gated repo; without it the download" \
            "# fails with an error that does not name the missing token." \
            ""
        for v in $other_shown; do printf '# %s=\n' "$v"; done
        printf '\n'
    fi
    printf '%s\n' \
        "# ── all env-having flags of the pinned llama-server (uncomment to set) ───────"
    while IFS="$TAB" read -r name def; do
        case " $SPECIAL_VARS " in *" $name "*) continue ;; esac
        # A simple single-token default becomes the value; prose defaults
        # ("4096, 0 = loaded from model") go into a trailing comment instead,
        # so an uncommented line is always a valid assignment.
        if [ -n "$def" ] && [[ "$def" == *[[:space:],]* ]]; then
            printf '# %s=  # default: %s\n' "$name" "$def"
        else
            printf '# %s=%s\n' "$name" "$def"
        fi
    done <<<"$table"

    # ── the other half: options with no environment variable ─────────────────
    if [ -n "$flag_table" ]; then
        printf '\n'
        printf '%s\n' \
            "# ── options with NO environment variable (set via LLAMA_EXTRA_ARGS) ──────────" \
            "# Everything llama-server accepts that upstream did not give an env var, under" \
            "# the section headings its own --help prints. Run 'llama-server --help' in the" \
            "# box for each one's description and default." \
            ""
        printf '%s\n' "$flag_table" \
            | awk -F'\t' -v q="'" '
                $3 != "" { next }                       # has an env var; listed above
                { by[$1] = by[$1] $2 "\n"; if (!($1 in seen)) { order[++n] = $1; seen[$1] = 1 } }
                END {
                    for (i = 1; i <= n; i++) {
                        s = order[i]
                        printf "# %s\n", (s == "" ? "other options" : s)
                        c = split(by[s], f, "\n")
                        line = ""
                        for (j = 1; j <= c; j++) {
                            if (f[j] == "") continue
                            cand = (line == "" ? "#   " f[j] : line "  " f[j])
                            if (length(cand) > 78) { print line; line = "#   " f[j] }
                            else line = cand
                        }
                        if (line != "") print line
                        print "#"
                    }
                }'
    fi
} > "$OUT"

note "wrote $OUT"
