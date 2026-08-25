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
# listed by name, routed to LLAMA_EXTRA_ARGS.
#
# ⭐ AND THE RESULT IS CLASSIFIED, NOT JUST LISTED (s51). 257 options in upstream's
# printing order is a list, not a config surface; comfyui.env sorts its surface into
# what you need / what you might tune / what you reach for when debugging / what
# will not help you here, and llama gets the same four. CLASS_RULES below is the
# table, and it is PATTERNS rather than flag names so it keeps working across a pin
# bump. Anything no pattern claims is emitted under "Unclassified" and counted in
# the build log — a new upstream family announces itself instead of vanishing.
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

# ── THE CLASSIFICATION TABLE ──────────────────────────────────────────────────
# Four categories, the same split comfyui.env uses, because 257 options sorted by
# upstream's own printing order is a list, not a config surface:
#
#   a  definitely needed   you will set this, or we already did
#   b  useful for tweaking a real knob, with a default that is fine until it isn't
#   c  debug / development you reach for it when something is wrong
#   d  not useful here     it works, and it will not help you on this box (or it
#                          is fatal as a config line) -- with the reason, always
#
# ⭐ THE TABLE IS PATTERNS, NOT A FLAG LIST, and that is deliberate: the flags come
# from the BINARY at build time, so a hand-kept list would silently rot at the next
# pin bump while a pattern keeps classifying. Anything a pattern does not claim is
# NOT quietly bucketed -- it lands in an "unclassified" section in the file and is
# counted in the build log, so a new upstream family announces itself.
#
# Format: category | group heading | glob glob glob …
# First matching rule wins, so put the narrow ones first. Globs match a whole flag
# spelling, and an entry matches if ANY of its spellings does.
CLASS_RULES=(
# ── (d) first: these are the traps, and a trap must not be caught by a broad rule
"d|Exits immediately -- fatal as a config line|--help --usage -h --version --cache-list -cl --completion-bash --list-devices"
"d|Removed upstream -- kept only to give a good error|--spec-ngram-size-n --spec-ngram-size-m --spec-ngram-min-hits"
"d|Text-to-speech -- this box serves no vocoder model|--model-vocoder -mv --tts-*"
"d|Distributed inference -- this is a single box|--rpc --rpc-*"

# ── (a) definitely needed
"a|Model & first run|--model -m --model-url -mu --hf-repo -hf --hf-repo-v -hfv --hf-file -hff --hf-repo-draft* --hf-file-draft* --*-default --fim-*-spec --spec-default"
"a|Access & authentication|--api-key --api-key-file --hf-token -hft --host --port --path --no-webui"
"a|Context & KV cache type|--ctx-size -c --cache-type-k -ctk --cache-type-v -ctv"
"a|GPU placement|--n-gpu-layers -ngl --n-gpu-layers-draft -ngld --split-mode -sm --tensor-split -ts --main-gpu -mg --device -dev --list-devices"

# ── (b) useful for tweaking
"b|Sampling & constrained decoding|--samplers --seed -s --sampler-seq --sampling-seq --ignore-eos --temp --temperature --top-p --top-k --min-p --top-nsigma --xtc-* --typical --typical-p --repeat-* --presence-penalty --frequency-penalty --dry-* --adaptive-* --dynatemp-* --mirostat* --logit-bias -l --grammar --grammar-file -j --json-schema -jf --json-schema-file"
"b|Speculative decoding & draft model|--spec-* --draft* -td* -devd -ngld -cd -devdraft"
"b|Batching, memory & attention|--batch-size -b --ubatch-size -ub --flash-attn -fa --mlock --no-mlock --mmap --no-mmap --no-kv-offload -nkvo --defrag-thold -dt --parallel -np --cont-batching -cb --no-cont-batching --cache-reuse --swa-* --op-offload --no-op-offload --numa --override-tensor* -ot --n-cpu-moe* -ncmoe*"
"b|CPU threads & affinity|--threads -t --threads-batch -tb --cpu-mask* -C -Cb --cpu-range* -Cr -Crb --cpu-strict* --prio --prio-batch --poll --poll-batch"
"b|Adapters & control vectors|--lora --lora-scaled --lora-init-without-apply --control-vector*"
"b|Server behaviour|--slot-* -sps --media-path --sleep-idle-seconds --timeout --*-timeout --keep-alive --props --metrics --slots --no-slots --no-context-shift --context-shift --chat-template* --jinja --reasoning* --embd-* --pooling --rerank --alias -a --threads-http --cache-ram -cram --no-prefill-assistant --spm-infill"
"b|Prompt & generation semantics|--keep --escape -e --no-escape --reverse-prompt -r --special -sp --warmup --no-warmup --predict -n --n-predict"
"b|Multimodal|--mmproj* --no-mmproj* --image --audio"

# ── (c) debug / development
"c|Logging & diagnostics|--log-* --verbose -v --verbosity -lv --no-perf --check-tensors --override-kv --dump-kv-cache -dkvc --no-warmup-check --seed-debug --print-*"
)

# Prose for the (a) groups only. (b), (c) and (d) carry the one-line reason in
# their heading, which is what "briefly why if practical" buys at 257 options.
# Keyed by the exact group heading above.
class_prose() {
    case "$1" in
    "Model & first run")
        printf '%s\n' \
            "# The server does not start without a model. Either point LLAMA_ARG_MODEL at a" \
            "# local GGUF, or use one of upstream's one-shot presets in LLAMA_EXTRA_ARGS --" \
            "# each sets a whole configuration (repo, context, sometimes a draft model) in a" \
            "# single token, and is the shortest path from a fresh box to a working server:" \
            "#   LLAMA_EXTRA_ARGS=\"--gpt-oss-20b-default\"" ;;
    "Access & authentication")
        printf '%s\n' \
            "# **THIS BOX BINDS 0.0.0.0 AND SHIPS NO AUTHENTICATION. Anything that can route" \
            "# to it can use the model. LLAMA_API_KEY is the only knob that changes that;" \
            "# LLAMA_ARG_HOST=127.0.0.1 is the other answer if you only want in-box clients." \
            "# HF_TOKEN is what makes a gated repo download work at all." ;;
    "Context & KV cache type")
        printf '%s\n' \
            "# Context length is the memory knob that bites first, and the KV cache type is" \
            "# what makes a long one affordable." \
            "# ⭐ THIS BUILD IS TurboQuant, and its headline feature lives here: -ctk/-ctv" \
            "# accept **turbo2, turbo3 and turbo4** in addition to the stock f32/f16/q8_0/" \
            "# q5_1/q5_0/q4_1/q4_0 set. Those three are the reason this image exists and they" \
            "# are spelled exactly like that -- not TURBO2_0, which is the internal name." ;;
    "GPU placement")
        printf '%s\n' \
            "# On Strix Halo system RAM and VRAM are one pool, so \"offload everything\" is" \
            "# usually right and the interesting question is what does not fit. -ngl is the" \
            "# first thing to change when a model will not load." ;;
    *) : ;;
    esac
}

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

# ── 1c) classify every enumerated option into a/b/c/d ─────────────────────────
# Joins the flags the BINARY printed against the hand-written CLASS_RULES above.
# Emits "CAT<TAB>RULEINDEX<TAB>GROUP<TAB>FLAGS<TAB>ENVNAME"; an option no rule
# claims comes back as category "z", which the emitter renders as a visible
# "unclassified" section rather than hiding it in a bucket.
class_table=""
if [ -n "$flag_table" ]; then
    class_table=$(awk -v OFS='\t' '
        # file 1: the rules, "cat|group|globs"
        FNR == NR {
            n = split($0, rr, /\|/)
            if (n < 3) next
            nrules++
            cat[nrules] = rr[1]; grp[nrules] = rr[2]; pat[nrules] = rr[3]
            next
        }
        function globmatch(flag, glob,   re) {
            re = glob
            gsub(/[.]/, "\\.", re)
            gsub(/[*]/, ".*", re)
            return flag ~ ("^" re "$")
        }
        # file 2: the enumerated options, "section<TAB>flags<TAB>env"
        {
            split($0, col, /\t/)
            nf = split(col[2], flags, /, /)
            hit = 0
            for (r = 1; r <= nrules && !hit; r++) {
                ng = split(pat[r], globs, / /)
                for (g = 1; g <= ng && !hit; g++) {
                    if (globs[g] == "") continue
                    for (f = 1; f <= nf; f++) {
                        if (globmatch(flags[f], globs[g])) { hit = r; break }
                    }
                }
            }
            if (hit) print cat[hit], hit, grp[hit], col[2], col[3]
            else     print "z", 999, "Unclassified", col[2], col[3]
        }
      ' <(printf '%s\n' "${CLASS_RULES[@]}") <(printf '%s\n' "$flag_table"))
    unclassified=$(printf '%s\n' "$class_table" | awk -F'\t' '$1 == "z" { n++ } END { print n + 0 }')
    cat_count() { printf '%s\n' "$class_table" | awk -F'\t' -v c="$1" '$1 == c { n++ } END { print n + 0 }'; }
    note "classification: a=$(cat_count a) b=$(cat_count b) c=$(cat_count c) d=$(cat_count d) unclassified=$unclassified"
    [ "$unclassified" -eq 0 ] \
        || note "classification: $unclassified option(s) matched no rule and are emitted under 'Unclassified' — add a pattern to CLASS_RULES in this script, or confirm the family is new upstream."
fi

# ── 2) VERIFY the active/required vars exist in the enumerated table ──────────
names=$(printf '%s\n' "$table" | cut -f1)
for v in "${REQUIRED_VARS[@]}"; do
    grep -qx "$v" <<<"$names" \
        || die "required env var '$v' NOT in the pinned llama-server's arg table — upstream rename? Fix the emitted lines (or the launch flags) before shipping."
done
note "verified required vars: ${REQUIRED_VARS[*]}"

# ── 2b) stage the emitter's three inputs ──────────────────────────────────────
# awk joins them by FILENAME, so they have to be real files: the defaults from
# pass 1, the hand-written prose for the (a) groups, and the classified options.
TMP_DEF=$(mktemp); TMP_PROSE=$(mktemp); TMP_CLASS=$(mktemp)
trap 'rm -f "$TMP_DEF" "$TMP_PROSE" "$TMP_CLASS"' EXIT
printf '%s\n' "$table" > "$TMP_DEF"
printf '%s\n' "$class_table" > "$TMP_CLASS"
if [ -n "$class_table" ]; then
    # One "GROUP<TAB>line" row per prose line, for every group any (a) rule names.
    while IFS='|' read -r cat grp _; do
        [ "$cat" = a ] || continue
        class_prose "$grp" | while IFS= read -r pl; do printf '%s\t%s\n' "$grp" "$pl"; done
    done < <(printf '%s\n' "${CLASS_RULES[@]}") > "$TMP_PROSE"
fi

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
    # ⚠️ FALLBACK PATH ONLY. When the classification ran, pass 2 already places these
    # two under "Access & authentication" with the same warning, and emitting the
    # block as well printed each variable twice.
    other_shown=""
    for v in $OTHER_ENV_VARS; do
        grep -q "(env: $v)" <<<"$help_text" 2>/dev/null || continue
        other_shown="$other_shown $v"
    done
    if [ -n "$other_shown" ] && [ -z "$class_table" ]; then
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
    if [ -z "$class_table" ]; then
        # Fallback: the classification needs pass 2, which did not survive. Emit the
        # flat env list exactly as this script always did — losing the GROUPING is
        # acceptable, losing the VARIABLES is not.
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
    else
        # ── the classified body: every printed option, under a/b/c/d ─────────
        awk -F'\t' -v OFS='' -v special=" $SPECIAL_VARS " \
            -v deffile="$TMP_DEF" -v prosefile="$TMP_PROSE" '
            # file 1 — defaults, "ENVNAME<TAB>DEFAULT"
            FILENAME == deffile { def[$1] = $2; next }
            # file 2 — prose for the (a) groups, "GROUP<TAB>line"
            FILENAME == prosefile { prose[$1] = prose[$1] $2 "\n"; next }
            # file 3 — the classified options
            {
                key = $1 SUBSEP $2
                if (!(key in seengrp)) { seengrp[key] = 1; ord[++nord] = key
                                         gcat[key] = $1; gidx[key] = $2 + 0; gname[key] = $3 }
                ent[key] = ent[key] $4 "\t" $5 "\n"
            }
            function banner(c) {
                if (c == "a") return "(a) DEFINITELY NEEDED — you will set these, or we already did"
                if (c == "b") return "(b) USEFUL FOR TWEAKING — good defaults, until they are not yours"
                if (c == "c") return "(c) DEBUG & DEVELOPMENT — for when something is wrong"
                if (c == "d") return "(d) NOT USEFUL HERE — kept visible, with the reason"
                return "UNCLASSIFIED — no rule in this image'\''s generator claimed these"
            }
            # ⚠️ ASCII on purpose. mawk counts BYTES, so a box-drawing rule built by
            # length() comes out a third of the intended width.
            function rule() { return "============================================================================" }
            function emit_names(list,   c, f, j, line, out) {
                c = split(list, f, "\n"); line = ""
                for (j = 1; j <= c; j++) {
                    if (f[j] == "") continue
                    cand = (line == "" ? "#   " f[j] : line "  " f[j])
                    if (length(cand) > 78) { print line; line = "#   " f[j] }
                    else line = cand
                }
                if (line != "") print line
            }
            END {
                ncat = split("a b c d z", cats, " ")
                for (ci = 1; ci <= ncat; ci++) {
                    c = cats[ci]; any = 0
                    for (i = 1; i <= nord; i++) if (gcat[ord[i]] == c) { any = 1; break }
                    if (!any) continue
                    print ""
                    print "# " rule()
                    print "# " banner(c)
                    print "# " rule()
                    # groups in CLASS_RULES order
                    for (pass = 1; pass <= nord; pass++) {
                        best = ""; bi = 999999
                        for (i = 1; i <= nord; i++) {
                            k = ord[i]
                            if (gcat[k] != c || done[k]) continue
                            if (gidx[k] < bi) { bi = gidx[k]; best = k }
                        }
                        if (best == "") break
                        done[best] = 1
                        print ""
                        print "# " gname[best]
                        print "# " substr("--------------------------------------------------------------------------", 1, length(gname[best]))
                        if (gname[best] in prose) printf "%s", prose[gname[best]]
                        # assignments first, then the env-less names
                        n = split(ent[best], rows, "\n")
                        names = ""
                        for (j = 1; j <= n; j++) {
                            if (rows[j] == "") continue
                            split(rows[j], col, "\t")
                            flags = col[1]; env = col[2]
                            if (env == "") { names = names flags "\n"; continue }
                            if (index(special, " " env " ")) continue   # dedicated block above
                            d = def[env]
                            if (d != "" && d ~ /[ ,]/) print "# " env "=  # default: " d
                            else                       print "# " env "=" d
                        }
                        if (names != "") {
                            # ⚠️ The lead-in is per-category on purpose: telling a
                            # reader to put an exits-immediately flag in
                            # LLAMA_EXTRA_ARGS is advice that kills the service.
                            if (c == "d") print "#   flags:"
                            else          print "#   …no env var, use LLAMA_EXTRA_ARGS:"
                            emit_names(names)
                        }
                    }
                }
            }
        ' "$TMP_DEF" "$TMP_PROSE" "$TMP_CLASS"
    fi
} > "$OUT"

# ── 4) SAFETY NET: pass 2 groups, it does not get to DELETE ──────────────────
# The classified body emits assignments from the options pass 2 found. If pass 2
# ever misses an option pass 1 enumerated, that variable would silently drop out
# of the config surface — the exact regression this rewrite was meant to prevent
# in the other direction. So the emitted file is checked against pass 1's list and
# anything absent is appended rather than lost.
missing=""
while IFS="$TAB" read -r name _; do
    [ -n "$name" ] || continue
    case " $SPECIAL_VARS " in *" $name "*) continue ;; esac
    grep -q "^# $name=" "$OUT" || missing="$missing $name"
done <<<"$table"
if [ -n "$missing" ]; then
    # shellcheck disable=SC2086   # deliberate word split: $missing is a space-separated list
    n_missing=$(printf '%s\n' $missing | grep -c .)
    note "safety net: $n_missing env var(s) enumerated by pass 1 did not appear in the classified body — appending them. This means pass 2 missed an option pass 1 saw; worth a look at the help layout.$missing"
    {
        printf '\n'
        printf '%s\n' \
            "# ============================================================================" \
            "# OTHER ENVIRONMENT VARIABLES" \
            "# ============================================================================" \
            "# The binary reads these, but the option they belong to was not matched to a" \
            "# section above, so they could not be grouped. They work exactly like every" \
            "# other assignment in this file." \
            ""
        for v in $missing; do
            d=$(printf '%s\n' "$table" | awk -F'\t' -v n="$v" '$1 == n { print $2; exit }')
            if [ -n "$d" ] && [[ "$d" == *[[:space:],]* ]]; then
                printf '# %s=  # default: %s\n' "$v" "$d"
            else
                printf '# %s=%s\n' "$v" "$d"
            fi
        done
    } >> "$OUT"
fi

note "wrote $OUT"
