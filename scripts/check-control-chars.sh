#!/usr/bin/env bash
# check-control-chars.sh — does anything emit a cursor-moving control character
# outside the atom system?
#
# WHY THIS EXISTS. The rendering rungs (installer/ui.sh) are pipe < terminal <
# escapes, and the bottom rung promises that the captured bytes ARE what was
# displayed. That promise is kept by ATOMS -- $CR and $EL are blanked when the
# rung forbids them -- so a printf that hardcodes a control character bypasses
# the whole mechanism and nothing at runtime would notice.
#
# THE TEST IS THE HUMAN ONE (Jei, s66): can a reader of the bytes tell what was
# shown? \n yes. \t yes. Everything below, no:
#   \r  returns to column 0    -- "ABC\r0" displays 0BC, unreconstructible
#   \b  moves back one column  -- same defect
#   \a  bell -- invisible entirely
# ⭐ \v AND \f ARE ALLOWED, and the rule that admits them is the better one
# (Jei, s66): the line is FORWARD-ONLY MOTION. Both move onward and can never
# reach back over what was already written, so the stream still records what was
# shown. Only \r and \b move BACK, and that is what destroys the property.
#   \e  escape sequences -- gated by the ANSI rung, allowed only via $EL et al
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

printf '\ncontrol characters outside the atom system\n\n'
fail=0
# A literal \r \b \f \v \a inside a double- or single-quoted printf argument.
# $'\r' assigned to CR is the ONE legitimate site: it defines the atom.
while IFS= read -r hit; do  # \r \b \a only: \v and \f are forward-only
  case "$hit" in
    *"CR=\$'\\r'"*) continue ;;          # the atom's own definition
    *check-control-chars*) continue ;;
  esac
  printf '  FAIL %s\n' "$hit"; fail=1
done < <(grep -nE "\\\\[rba]" "${files[@]}" \
         | grep -vE '^\S+:[0-9]+:\s*#' \
         | grep -E "printf|echo" || true)

if [[ $fail -eq 0 ]]; then
  printf '  ok   no fragment hardcodes \\r, \\b or \\a in output\n'
  printf '  ok   %d fragments scanned\n\n' "${#files[@]}"
  printf '  the bottom rung can still promise that bytes == display.\n'
  exit 0
fi
printf '\n  a control character is emitted directly instead of through an atom.\n'
printf '  Route it through a variable that the rung can blank, as CR/EL are.\n'
exit 1
