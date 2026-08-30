#!/usr/bin/env bash
# check-env-fallbacks.sh — every `$` on a config template's right-hand side must
# carry a fallback.
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
# cross-reference, it was the MISSING FALLBACK:
#
#     "there may be isolated cases where the user wants to grab a value from
#      another variable"
#
# `${OTHER-}` is mechanically safe and legitimately useful — it is exactly how a
# class-2 line says "default is whatever is already there, replace the right-hand
# side to set your own". So this checker bans the thing that actually killed a
# box, and nothing else.
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
# ── THE FORM TABLE, EVERY ROW MEASURED under `set -euo pipefail` (s57) ───────
# The measurement is `set -a; source <file>` with the referenced name UNSET.
#
#   ACCEPTED — the expansion supplies a value and the source survives:
#     ${VAR-…}  ${VAR:-…}   default
#     ${VAR+…}  ${VAR:+…}   alternate — safe by construction: it can only expand
#                           when VAR is set, so `set -u` has nothing to trip on
#     ${VAR=…}  ${VAR:=…}   assign-default; measured safe, and it is a fallback
#                           by any reading of the rule
#   REJECTED — measured to ABORT the source when the name is unset:
#     $VAR   "$VAR"   ${VAR}   x$VAR      the original box-killer, braces or not
#     ${#VAR}                             length
#     ${VAR/…} ${VAR#…} ${VAR%…}
#     ${VAR^…} ${VAR,…} ${VAR@Q} ${VAR:0:2}
#     ${!VAR}  ${!VAR-}                   🚨 INDIRECT ABORTS EVEN WITH A `-`
#                                         ("invalid indirect expansion"), so a
#                                         checker that only looked for a dash
#                                         would wave this through
#     ${VAR?msg} ${VAR:?msg}              deliberately fatal is still fatal: a
#                                         config file may not stop the box
#     $((VAR+1))                          arithmetic; and note the name inside
#                                         carries NO `$`, so no `$`-anchored rule
#                                         could ever see it — the form goes
#     $(cmd)  `cmd`                       command substitution: `$(false)`, a
#                                         failing pipeline and a missing command
#                                         all abort under errexit
#   REJECTED — safe to source, but never what the writer meant:
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

Verify that every `$` expansion on the right-hand side of an assignment in a
box config template carries a fallback, so that sourcing the file under
`set -u` cannot abort and lose every setting after the offending line.

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
        case $nx in
        '{')
            close=$(close_brace "$s" "$i")
            if [ "$close" -lt 0 ]; then
                report "$file" "$lineno" "${s:i}" 'unterminated expansion' \
                       'the `${` never closes; the file will not parse' "$src"
                return
            fi
            body=${s:i+2:close-i-2}
            case $body in
            '!'*)
                # 🚨 THE ONE FORM A `-` DOES NOT SAVE. Measured: `${!IND-}`
                # aborts with "invalid indirect expansion", exactly as `${!IND}`
                # does. Anyone writing a shorter rule ("has a dash ⇒ fine")
                # ships this hole.
                report "$file" "$lineno" "\${$body}" 'indirect expansion' \
                       'this aborts under `set -u` even WITH a fallback; name the variable directly' "$src" ;;
            '#'*)
                report "$file" "$lineno" "\${$body}" 'length expansion' \
                       'aborts when the name is unset; write the value out, or `${VAR-}`' "$src" ;;
            *)
                # name, then whatever operator follows it
                if [[ $body =~ ^([A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?)(.*)$ ]]; then
                    name=${BASH_REMATCH[1]}; rest=${BASH_REMATCH[3]}
                    case $rest in
                    '')
                        report "$file" "$lineno" "\${$name}" 'unguarded expansion' \
                               "braces alone do NOT help; write \${$name-}" "$src" ;;
                    :[-+=]*|[-+=]*)
                        # ✅ ACCEPTED. Keep scanning from just after the operator
                        # so a nested expansion in the FALLBACK is checked too —
                        # measured, `${A:-$B}` aborts on an unset B.
                        case $rest in :?*) i=$((i + 2 + ${#name} + 2)) ;;
                                       *)  i=$((i + 2 + ${#name} + 1)) ;; esac
                        continue ;;
                    :\?*|\?*)
                        report "$file" "$lineno" "\${$body}" 'deliberately fatal expansion' \
                               "a config file may not stop the box; write \${$name-}" "$src" ;;
                    *)
                        report "$file" "$lineno" "\${$body}" 'unguarded expansion' \
                               "this form aborts when $name is unset; write \${$name-}" "$src" ;;
                    esac
                else
                    report "$file" "$lineno" "\${$body}" 'unrecognised expansion' \
                           'if it is safe under `set -u`, add it to the form table in this checker' "$src"
                fi ;;
            esac
            i=$((close + 1)); continue ;;
        '(')
            if [ "${s:i+2:1}" = '(' ]; then
                # 🚨 A NAME INSIDE `$((…))` CARRIES NO `$`, so no `$`-anchored
                # rule can see it — and `$((OTHER+1))` aborts. The form goes.
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
            # A `$` before a space, a quote, `/`, or end of line is a literal
            # dollar. Measured: `A=100$` and `A="cost 5$"` both source fine.
            i=$((i + 1)); continue ;;
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
    printf '\n%d unguarded expansion(s). Every `$` on a right-hand side must carry a\n' "$findings"
    printf 'fallback — `${VAR-}` or `${VAR:-default}` — because the file is sourced as a\n'
    printf 'unit and one unguarded name loses EVERY setting after it.\n'
    exit 1
fi
exit "$status"
