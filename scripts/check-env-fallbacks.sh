#!/usr/bin/env bash
# check-env-fallbacks.sh — a `$` on a config template's right-hand side is
# allowed in ONE shape, and that shape is a whitelist.
#
# ⭐ WHY THIS EXISTS. Every box's config surface (targets/*/templates/*.env) is a
# shell file that droste SOURCES as a unit, in a child shell running
# `set -euo pipefail` (base/resolve/droste-envfile.sh). Under `set -u` an
# assignment whose right-hand side dereferences an unset variable does not fail
# that LINE — it aborts the whole source, so EVERY SETTING AFTER IT IS LOST. The
# measured original was `HF_TOKEN=$HF_TOKEN` in llama.env (s52), which took the
# box down before the server ever launched.
#
# ⭐ AND THE RULE IS NOT "NO `$`" (Jei, s57). The danger was never the
# cross-reference:
#
#     "there may be isolated cases where the user wants to grab a value from
#      another variable"
#
# `${OTHER-}` is mechanically safe and legitimately useful — it is exactly how a
# class-2 line says "default is whatever is already there, replace the right-hand
# side to set your own". So a template may reach for another variable; it may
# only do it in one shape.
#
# ── THE RULE, AND IT IS A WHITELIST OF SHAPES ────────────────────────────────
#
#     A `$` on a right-hand side is allowed only in the form `${NAME<op>…}`,
#     where NAME is a plain variable name ([A-Za-z_][A-Za-z0-9_]*) and <op> is
#     one of  -  :-  +  :+ .  Nesting is permitted provided every level obeys
#     the rule.  Nothing else is allowed.
#
# 🚨 IT IS A WHITELIST BECAUSE THE PROPERTY VERSION HAD A HOLE AND HID A FORM.
# This checker's first rule was stated as a property — "every `$` carries a `-`
# or `:-`" — and a property is only ever as good as the enumeration of hazards
# behind it:
#   · `${!IND-}` CARRIES THE FALLBACK AND ABORTS ANYWAY (measured: "invalid
#     indirect expansion"). The property says yes; bash says no.
#   · `$((OTHER+1))` aborts, and the name inside it carries NO `$` at all — so
#     nothing anchored on `$` could ever see it. The property could not even
#     look at the form, let alone judge it.
# A whitelist has neither failure mode: a shape that is not the one shape is
# refused whether or not anyone thought of it. Same reasoning that made
# `droste::bool` a whitelist after a boolean BLACKLIST turned `Off` and `FALSE`
# into ON — a blacklist fails in the dangerous direction, silently, on the input
# nobody enumerated.
# ⚠️ SO DO NOT ADD A CASE TO MAKE A NEW FORM FAIL. It already fails. The `case`
# arms below the whitelist gate choose the WORDING of a refusal that has already
# been decided; adding one changes a message, never a verdict. If you find
# yourself adding a case to REJECT something, the gate has been broken.
#
# ⚠️ BOTH `${VAR-…}` AND `${VAR:-…}` ARE ACCEPTED, DELIBERATELY. There is a
# separate open finding that vllm.env's four `${XDG_CACHE_HOME:-…}` lines should
# use `-` rather than `:-`, because vLLM's own reader is `os.getenv(X, default)`
# and therefore has `-` semantics. That is a question about MEANING (what a
# user's empty XDG_CACHE_HOME should do), not about SAFETY (whether the source
# survives). Both forms survive `set -u`; both are correct here. DO NOT "fix"
# this checker into rejecting one of them — it would be enforcing a semantic
# opinion under the banner of a safety rule, on files that are the user's.
#
# 🚨 AND `${VAR=…}` / `${VAR:=…}` ARE REJECTED THOUGH THEY ARE SAFE TO SOURCE —
# THE ONE PLACE THIS CHECKER IS DELIBERATELY STRICTER THAN BASH. They do not
# just substitute, they ASSIGN. Measured: `A=${OTHER=x}` in a template leaves the
# child shell holding `OTHER=x`, `set -a` exports it, and droste::load_env_file
# diffs `env -0` around the source — so `OTHER` comes back as a brand-new setting
# and is applied exactly as though the user had written an `OTHER=` line. A
# config file may not silently create a setting nobody wrote. `${VAR-…}` says the
# same thing about VAR and leaves nothing behind.
#
# ── WHAT IT CHECKS, AND WHAT IT DOES NOT ────────────────────────────────────
# SCOPE:  assignment lines only — `NAME=…`, `export NAME=…`, and the SAME shapes
#         behind a leading `#`. The commented ones are checked ON PURPOSE: every
#         template ships its settings commented out and the file's own idiom is
#         "remove the `#`", so an unguarded `$` on a commented line is a landmine
#         with a one-character fuse.
# NOT IN SCOPE:
#   · prose comments (`# see $HOME for details`) — not an assignment, never run;
#   · non-assignment lines (a bare word, a command) — droste::load_env_file
#     already warns about those, and this checker would only duplicate it;
#   · a quoted value continued across several lines. The scan is line-oriented.
#     No shipped template has one; if one ever appears, this file must grow a
#     continuation state rather than quietly mis-parse it.
# NOTATION: one finding per line of output, `FILE:LINE: <what> — <fix>`, plus the
#         offending source line. Exit 0 = clean, 1 = findings, 2 = usage.
#
# ── THE FORM TABLE, EVERY ROW MEASURED under `set -euo pipefail` (s57, s58) ──
# The measurement is `set -a; source <file>` with the referenced name UNSET.
# ⚠️ THIS TABLE IS A RECORD OF MEASUREMENTS, NOT THE RULE. The rule is the
# whitelist above; every "REJECTED" row below is refused by simply not being the
# accepted shape, and none of them is enumerated anywhere in the code.
#
#   ACCEPTED — the one shape, and the source survives:
#     ${VAR-…}  ${VAR:-…}   default
#     ${VAR+…}  ${VAR:+…}   alternate — safe by construction: it can only expand
#                           when VAR is set, so `set -u` has nothing to trip on
#   REJECTED — measured to ABORT the source when the name is unset:
#     $VAR   "$VAR"   ${VAR}   x$VAR      the original box-killer, braces or not
#     ${#VAR}                             length
#     ${VAR/…} ${VAR#…} ${VAR%…}
#     ${VAR^…} ${VAR,…} ${VAR@Q} ${VAR:0:2}
#     ${!VAR}  ${!VAR-}                   🚨 INDIRECT ABORTS EVEN WITH A `-`
#                                         ("invalid indirect expansion"), which
#                                         is half of why the rule is a whitelist:
#                                         `!IND` is not a plain NAME, so the
#                                         shape never matches and no arm has to
#                                         know that bash treats it specially
#     ${ARR[0]}                           an unbound element still aborts
#     ${VAR?msg} ${VAR:?msg}              deliberately fatal is still fatal: a
#                                         config file may not stop the box
#     $((VAR+1))                          arithmetic; the name inside carries NO
#                                         `$`, so no `$`-anchored PROPERTY could
#                                         ever see it — but it does not begin
#                                         `${NAME<op>`, so the whitelist does
#     $(cmd)  `cmd`                       command substitution: `$(false)`, a
#                                         failing pipeline and a missing command
#                                         all abort under errexit
#   REJECTED — safe to source, but never what the writer meant:
#     ${VAR=…}  ${VAR:=…}                 assign-default. Measured: it also SETS
#                                         VAR in the child, `set -a` exports it,
#                                         and the loader's diff then applies VAR
#                                         as a setting nobody wrote. See above.
#     ${ARR[0]-}                          survives, but `env -0` carries scalars
#                                         only — an array cannot round-trip out
#                                         of the child, so the value is a promise
#                                         the loader cannot keep
#     $1 $@ $* $0 $$ $? $- $!             these name the RESOLVER's shell, not
#                                         the user's config. Measured: `$1` in a
#                                         sourced template yields the path the
#                                         resolver passed to `source`, `$0` is
#                                         `_`, `$$` is the throwaway child's pid.
#                                         A knob that looks authoritative and
#                                         does nothing is worse than an absent
#                                         one ([[never-silently-ignore-user-input]]).
#   NOT AN EXPANSION AT ALL — left alone:
#     '$VAR' (single-quoted)   \$VAR (escaped)   a trailing or lone `$`
#
# Run:  scripts/check-env-fallbacks.sh              # every shipped template
#       scripts/check-env-fallbacks.sh FILE…        # or just these
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: check-env-fallbacks.sh [-q] [FILE...]

Verify that every `$` on the right-hand side of an assignment in a box config
template is written `${NAME-…}`, `${NAME:-…}`, `${NAME+…}` or `${NAME:+…}` —
the only shapes that cannot abort the source under `set -u` and lose every
setting after the offending line, and that leave nothing behind in the child.
Nesting is allowed as long as every level obeys the same rule.

  FILE...   files to check (default: targets/*/templates/*.env)
  -q        print findings only; no per-file OK line
  -h        this help

Exit: 0 clean · 1 findings · 2 usage error
EOF
}

QUIET=no
while [ $# -gt 0 ]; do
    case $1 in
        -q|--quiet) QUIET=yes; shift ;;
        -h|--help)  usage; exit 0 ;;
        --)         shift; break ;;
        -*)         printf 'check-env-fallbacks: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
        *)          break ;;
    esac
done

if [ $# -gt 0 ]; then
    FILES=("$@")
else
    # ⚠️ A glob that matches nothing must be an ERROR, not a green run over zero
    # files — the same reason a missing .checks file fails loudly in droste-core.
    shopt -s nullglob
    FILES=("$REPO"/targets/*/templates/*.env)
    shopt -u nullglob
    if [ ${#FILES[@]} -eq 0 ]; then
        printf 'check-env-fallbacks: no templates found under %s/targets/*/templates/\n' "$REPO" >&2
        exit 2
    fi
fi

findings=0

# ── report — one finding, in the one format ─────────────────────────────────
# Names the FILE, the LINE NUMBER, the offending expansion and the FIX, then
# echoes the source line. Anything less and the reader has to go looking.
report() {  # <file> <lineno> <expansion> <why> <fix> <srcline>
    findings=$((findings + 1))
    printf '%s:%s: %s `%s` — %s\n' "$1" "$2" "$4" "$3" "$5"
    printf '    %s\n' "$6"
}

# ── close_brace — index of the `}` matching the `${` that starts at $2 ───────
# Counts nested `${…}` so that `${A:-${B-}}` is one expansion, not two halves.
# Prints -1 when the braces never close.
close_brace() {  # <string> <index-of-$>
    local s=$1 i=$(( $2 + 2 )) n=${#1} depth=1 c
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        if [ "$c" = '\' ]; then i=$((i + 2)); continue; fi
        if [ "$c" = '$' ] && [ "${s:i+1:1}" = '{' ]; then depth=$((depth + 1)); i=$((i + 2)); continue; fi
        if [ "$c" = '}' ]; then
            depth=$((depth - 1))
            [ "$depth" -eq 0 ] && { printf '%s' "$i"; return; }
        fi
        i=$((i + 1))
    done
    printf '%s' -1
}

# ── close_paren — index of the `)` matching the `$(` that starts at $2 ───────
close_paren() {  # <string> <index-of-$>
    local s=$1 i=$(( $2 + 2 )) n=${#1} depth=1 c
    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}
        if [ "$c" = '\' ]; then i=$((i + 2)); continue; fi
        [ "$c" = '(' ] && depth=$((depth + 1))
        if [ "$c" = ')' ]; then
            depth=$((depth - 1))
            [ "$depth" -eq 0 ] && { printf '%s' "$i"; return; }
        fi
        i=$((i + 1))
    done
    printf '%s' -1
}

# ── scan_rhs — walk one right-hand side, honouring bash's own quoting ────────
# ⚠️ QUOTING IS WHY THIS IS A SCANNER AND NOT A grep. `'$VAR'` is a literal
# dollar and `"$VAR"` is the box-killer; a regex that cannot tell them apart
# either misses the second or cries wolf on the first, and a checker that cries
# wolf gets switched off.
scan_rhs() {  # <file> <lineno> <rhs> <srcline>
    local file=$1 lineno=$2 s=$3 src=$4
    local n=${#s} i=0 q=none c nx body name rest tail close

    while [ "$i" -lt "$n" ]; do
        c=${s:i:1}

        if [ "$q" = sq ]; then
            # Inside single quotes NOTHING expands, not even a backslash.
            [ "$c" = "'" ] && q=none
            i=$((i + 1)); continue
        fi

        if [ "$c" = '\' ]; then i=$((i + 2)); continue; fi

        if [ "$q" = none ]; then
            case $c in
                "'") q=sq;  i=$((i + 1)); continue ;;
                '"') q=dq;  i=$((i + 1)); continue ;;
                '#') # A `#` starts a comment only at a WORD BOUNDARY. Measured:
                     # `A=b #$OTHER` survives (the `$OTHER` is commented out) and
                     # `A=b#$OTHER` aborts. ⚠️ And a `#` in the first position of
                     # the right-hand side is NOT a comment either — `A=#x` sets
                     # A to the string `#x`.
                     if [ "$i" -gt 0 ] && [[ ${s:i-1:1} == [[:space:]] ]]; then return; fi ;;
            esac
        else
            [ "$c" = '"' ] && { q=none; i=$((i + 1)); continue; }
        fi

        if [ "$c" = '`' ]; then
            report "$file" "$lineno" '`…`' 'command substitution' \
                   'a command that exits non-zero aborts the whole source under errexit; use a literal value' "$src"
            # Skip to the closing backtick so the body is reported once, not
            # once per `$` inside it.
            rest=${s:i+1}
            case $rest in
                *'`'*) tail=${rest#*\`}      # everything AFTER the closing backtick
                       i=$((n - ${#tail})) ;;
                *)     i=$((i + 1)) ;;
            esac
            continue
        fi

        [ "$c" = '$' ] || { i=$((i + 1)); continue; }

        nx=${s:i+1:1}

        # ── IS THIS A `$` THAT EXPANDS AT ALL? ───────────────────────────────
        # A `$` before a space, a quote, `/`, `.` or end of line is a literal
        # dollar character. Measured: `A=100$` and `A="cost 5$"` both source
        # fine. This is a LEXICAL question about where an expansion begins, not
        # an exemption from the rule — there is no expansion here to judge.
        # ⚠️ EVERY INTRODUCER IS ITS OWN QUOTED ALTERNATIVE, NOT A BRACKET CLASS.
        # A `case` PATTERN is expanded before it is matched, so `[…$!…]` makes
        # bash read `$!` as the last background pid — unset, `set -u`, and the
        # checker dies on its own pattern. Measured while writing this.
        case $nx in
            '{'|'('|'$'|'?'|'!'|'#'|'-'|'@'|'*'|[A-Za-z_0-9]) ;;
            *) i=$((i + 1)); continue ;;
        esac

        # ── THE WHITELIST GATE — THE ONLY PLACE ANYTHING IS ACCEPTED ─────────
        # One shape: `${` + a plain NAME + one of `-` `:-` `+` `:+`. Note what
        # is NOT here: no list of hazards, and no arm that has to recognise
        # `${!IND-}` or `$((…))` in order to refuse them. `!IND` is not a plain
        # NAME and `$((` does not begin `${NAME`, so both miss the shape and
        # fall through to be rejected like anything else unrecognised.
        # ⚠️ EVERYTHING BELOW THIS BLOCK RUNS ONLY ON A LINE ALREADY REFUSED. It
        # picks the WORDING; it cannot change the verdict.
        if [ "$nx" = '{' ]; then
            close=$(close_brace "$s" "$i")
            if [ "$close" -ge 0 ]; then
                body=${s:i+2:close-i-2}
                if [[ $body =~ ^([A-Za-z_][A-Za-z0-9_]*)(:?[-+]) ]]; then
                    # ✅ ACCEPTED. Resume scanning from just after the operator,
                    # INSIDE the fallback text, so every nested level is held to
                    # the same rule — measured, `${A:-${B}}` aborts on an unset
                    # B while `${A:-${B-}}` survives.
                    i=$(( i + 2 + ${#BASH_REMATCH[1]} + ${#BASH_REMATCH[2]} ))
                    continue
                fi
            fi
        fi

        # ── REJECTED. From here down, only the message is being chosen. ──────
        case $nx in
        '{')
            if [ "$close" -lt 0 ]; then
                report "$file" "$lineno" "${s:i}" 'unterminated expansion' \
                       'the `${` never closes; the file will not parse' "$src"
                return
            fi
            case $body in
            '!'*)
                # 🚨 THE FORM THAT KILLED THE PROPERTY RULE. Measured: `${!IND-}`
                # aborts with "invalid indirect expansion", exactly as `${!IND}`
                # does — it carries the fallback and dies anyway. A rule phrased
                # as "has a dash ⇒ fine" ships this hole; the whitelist never
                # sees a plain NAME here and so never had the chance to.
                report "$file" "$lineno" "\${$body}" 'indirect expansion' \
                       'this aborts under `set -u` even WITH a fallback; name the variable directly' "$src" ;;
            '#'*)
                report "$file" "$lineno" "\${$body}" 'length expansion' \
                       'aborts when the name is unset; write the value out, or `${VAR-}`' "$src" ;;
            *)
                # name, then whatever operator follows it
                if [[ $body =~ ^([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; then
                    name=${BASH_REMATCH[1]}; rest=${BASH_REMATCH[2]}
                    case $rest in
                    '')
                        report "$file" "$lineno" "\${$name}" 'unguarded expansion' \
                               "braces alone do NOT help; write \${$name-}" "$src" ;;
                    :=*|=*)
                        # 🚨 SAFE TO SOURCE AND REJECTED ANYWAY — the one rule
                        # deliberately stricter than bash. `=` ASSIGNS: the child
                        # keeps the name, `set -a` exports it, and the loader's
                        # `env -0` diff applies it as a setting the user never
                        # wrote.
                        report "$file" "$lineno" "\${$body}" 'assign-default expansion' \
                               "this also SETS $name in the child shell and \`set -a\` exports it, so the loader's env diff would apply $name as a setting nobody wrote; write \${$name-} to substitute without assigning" "$src" ;;
                    :\?*|\?*)
                        report "$file" "$lineno" "\${$body}" 'deliberately fatal expansion' \
                               "a config file may not stop the box; write \${$name-}" "$src" ;;
                    \[*)
                        report "$file" "$lineno" "\${$body}" 'an array element' \
                               "a config file carries plain scalar names — \`env -0\` cannot bring an array back out of the child; write \${$name-}" "$src" ;;
                    *)
                        report "$file" "$lineno" "\${$body}" 'unguarded expansion' \
                               "only \${$name-} \${$name:-…} \${$name+…} \${$name:+…} are allowed here" "$src" ;;
                    esac
                else
                    report "$file" "$lineno" "\${$body}" 'unrecognised expansion' \
                           'the only allowed form is `${NAME-…}`, `${NAME:-…}`, `${NAME+…}` or `${NAME:+…}`' "$src"
                fi ;;
            esac
            i=$((close + 1)); continue ;;
        '(')
            if [ "${s:i+2:1}" = '(' ]; then
                # 🚨 THE OTHER FORM THAT KILLED THE PROPERTY RULE. A NAME INSIDE
                # `$((…))` CARRIES NO `$`, so no `$`-anchored property could ever
                # inspect it — and `$((OTHER+1))` aborts. Under the whitelist it
                # needs no insight at all: it does not begin `${NAME<op>`.
                report "$file" "$lineno" "\$((…))" 'arithmetic expansion' \
                       'a bare name inside it still aborts under `set -u`; write the number' "$src"
            else
                report "$file" "$lineno" "\$(…)" 'command substitution' \
                       'a command that exits non-zero aborts the whole source under errexit; use a literal value' "$src"
            fi
            close=$(close_paren "$s" "$i")
            if [ "$close" -lt 0 ]; then i=$((i + 2)); else i=$((close + 1)); fi
            continue ;;
        [A-Za-z_])
            [[ ${s:i+1} =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]
            name=${BASH_REMATCH[1]}
            report "$file" "$lineno" "\$$name" 'unguarded expansion' \
                   "aborts the whole file when $name is unset; write \${$name-}" "$src"
            i=$((i + 1 + ${#name})); continue ;;
        [1-9@*])
            report "$file" "$lineno" "\$$nx" 'a positional parameter' \
                   'a sourced config file sees the RESOLVER arguments, not its own; write the value' "$src"
            i=$((i + 2)); continue ;;
        '$'|'?'|'-'|'!'|'0'|'#')
            report "$file" "$lineno" "\$$nx" 'shell state, not configuration' \
                   'this describes the throwaway child shell, not the box; write the value' "$src"
            i=$((i + 2)); continue ;;
        *)
            # ⚠️ THE BACKSTOP, AND IT MUST STAY A REJECTION. Every character that
            # can introduce an expansion has an arm above; a literal `$` already
            # returned at the lexical gate. So nothing should reach here — and if
            # a future bash grows an introducer nobody listed, the whitelist has
            # already refused it and this is the message it gets. A `*)` that
            # skipped instead would quietly re-open the hole the whitelist closed.
            report "$file" "$lineno" "\$$nx" 'an expansion this checker does not recognise' \
                   'the only allowed form is `${NAME-…}`, `${NAME:-…}`, `${NAME+…}` or `${NAME:+…}`' "$src"
            i=$((i + 2)); continue ;;
        esac
    done
}

# ── main ────────────────────────────────────────────────────────────────────
status=0
for f in "${FILES[@]}"; do
    if [ ! -r "$f" ]; then
        printf 'check-env-fallbacks: cannot read %s\n' "$f" >&2
        status=2; continue
    fi
    before=$findings
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        # Cheap gate: a line with neither a `$` nor a backtick cannot carry an
        # expansion, and skipping it keeps this a sub-second run over five
        # ~400-line files. ⚠️ THE BACKTICK HALF IS NOT DECORATION — gating on `$`
        # alone let `` A=`cmd` `` through the whole scanner, silently, and the
        # row that caught it is in g1lab/envfile.sh.
        case $line in *'$'*|*'`'*) ;; *) continue ;; esac
        # An assignment, optionally commented out, optionally exported.
        [[ $line =~ ^[[:space:]]*(#[[:space:]]*)?(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=(.*)$ ]] || continue
        scan_rhs "$f" "$lineno" "${BASH_REMATCH[3]}" "$line"
    done < "$f"
    if [ "$QUIET" = no ] && [ "$findings" -eq "$before" ]; then
        printf 'ok   %s\n' "$f"
    fi
done

if [ "$findings" -gt 0 ]; then
    printf '\n%d disallowed expansion(s). A `$` on a right-hand side may only be written\n' "$findings"
    printf '`${NAME-…}`, `${NAME:-…}`, `${NAME+…}` or `${NAME:+…}` (nesting allowed, every\n'
    printf 'level the same). The file is sourced as a unit, so one name outside that shape\n'
    printf 'either loses EVERY setting after it or leaves a setting nobody wrote.\n'
    exit 1
fi
exit "$status"
