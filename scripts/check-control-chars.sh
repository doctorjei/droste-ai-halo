#!/usr/bin/env bash
# check-control-chars.sh — does anything emit a control character outside the
# four the output contract allows?
#
# 🚨 AN ALLOWLIST, NOT A BLOCKLIST (Jei, s66): "we really should exclude ALL
# control characters except for those 4; including sectioning, null, etc."
# ALLOWED, everywhere and always:
#     \t  09   \n  0A   \v  0B   \f  0C
# EVERYTHING ELSE IS OUT -- NUL, BEL, backspace, the shift-outs, DLE, the four
# separators FS/GS/RS/US, DEL, and the C1 range. Two get a conditional pass:
#     \r  0D   permitted only when the repaint level allows it, via the $CR atom
#     \e  1B   permitted only when the ansi level allows it, via $EL and the C_* atoms
#
# ⭐ WHY AN ALLOWLIST. A blocklist has to anticipate every character someone might
# reach for, and the C0 range has thirty-odd of them; the four that are safe are a
# closed set and cannot grow. Same reasoning that made droste::bool a whitelist
# after a boolean blocklist failed in the dangerous direction.
#
# ⭐ WHY THOSE FOUR. The rule is FORWARD-ONLY MOTION. \t, \n, \v and \f all move
# the cursor onward and can never reach back over what was already written, so the
# byte stream still records what was displayed. \r and \b move BACK and destroy
# that property -- "ABCDEFGHIJ\r0123" shows 0123EFGHIJ and nothing in the bytes
# says so. NUL and the separators are invisible, so they misrepresent it too.
#
# WHAT IT SCANS. The installer fragments, for (a) control characters written as
# printf escapes and (b) raw control bytes embedded in the source. The atom
# definitions are exempt by name: they are the ONE place \r and \e may be spelled,
# because the rendering levels blank them there.
#
# Exit: 0 clean · 1 a forbidden character is emitted · 2 the check could not run
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
die() { printf 'check-control-chars: %s\n' "$*" >&2; exit 2; }
cd "$REPO" || die "cannot enter $REPO"
shopt -s nullglob
files=(installer/*.sh)
[[ ${#files[@]} -gt 0 ]] || die "no installer fragments found"

printf '\ncontrol characters outside the four the contract allows\n\n'
fail=0

# ── (a) escapes naming a forbidden character ────────────────────────────────
# \a \b \r \e \E, \cX, and any octal or hex escape landing outside 09-0C.
# ⚠️ THE OCTAL BRANCH IS {0,3}, NOT {1,3}, AND A MUTATION FOUND THAT. With {1,3}
# a bare \0 -- NUL, the most basic forbidden character there is -- matched nothing
# and the check passed clean, because the pattern demanded a digit after the zero.
# ⚠️ NOT \\t \\n \\v \\f -- those four are the allowlist and must never be flagged.
while IFS= read -r hit; do
  case "$hit" in
    *"CR=\$'\\r'"*)      continue ;;   # the \r atom's own definition
    *"EL=\$'\\e[K'"*)    continue ;;   # the erase atom's own definition
    *"C_"*"=\$'\\e["*)   continue ;;   # a color atom's own definition
    *"RESET=\$'\\e[0m'"*) continue ;;
  esac
  printf '  FAIL %s\n' "$hit"; fail=1
done < <(grep -nE '\\(a|b|r|e|E|c[A-Za-z]|0[0-7]{0,3}|x[0-9A-Fa-f]{2})' "${files[@]}" \
         | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
         | grep -vE '\\(x0[9abcABC]|011|012|013|014)' \
         | grep -E 'printf|echo' || true)

# ── (b) raw control bytes sitting in the source ─────────────────────────────
# A literal ESC or NUL pasted into a string is invisible to the check above.
# Tab and newline are the file's own formatting, so only the rest are hunted.
while IFS= read -r hit; do
  printf '  FAIL raw control byte: %s\n' "$hit"; fail=1
done < <(LC_ALL=C grep -nP '[\x00-\x08\x0d-\x1f\x7f\xff]' "${files[@]}" 2>/dev/null || true)

if [[ $fail -eq 0 ]]; then
  printf '  ok   no fragment names a control character outside \\t \\n \\v \\f\n'
  printf '  ok   no raw control byte is embedded in a fragment\n'
  printf '  ok   %d fragments scanned\n\n' "${#files[@]}"
  printf '  the output contract holds: bytes still record what was displayed.\n'
  exit 0
fi
printf '\n  a control character is emitted outside the atom system.\n'
printf '  Route it through a variable the rendering level can blank, as CR and EL are,\n'
printf '  or drop it: only \\t \\n \\v \\f are allowed unconditionally.\n'
exit 1
