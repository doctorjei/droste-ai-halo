# ── Usage ────────────────────────────────────────────────────────────────────
# The delimiter is UNQUOTED so the typography atoms below expand; the block has
# no other $, backtick or escaped character, so nothing else expands with them
# (its \t / \n / \r are literal two-character spellings, not escapes).
usage() {
  cat <<EOF
Usage: droste-setup.sh [OPTIONS] [BOX ...]

Interactive setup for the droste *-halo AI boxes (Strix Halo / gfx1151).
ONE container per box (droste-<box>-halo), entered with distrobox and
served with podman. Guides binds, ports, serve-at-box-start and
serve-at-host-boot, and filesystem gotchas; writes per-box recreation
records (<box>-halo.ini) plus a NOTES.md, and can pull images, create
boxes, record your port and startup answers in each box's own
<box>.cfg, and start servers.

BOX      comfyui llama vllm ds4 finetuning   (default: interactive menu)

Options:
  --ascii    output limited to printable ASCII characters and tab (\t),
             linefeed (\n), and carriage return (\r) $EMD no escape
             sequences, no line editing. For pipes, captures, and dumb
             terminals (TERM=dumb auto-detects).
  -h, --help show this help

Safe to re-run: existing setups are detected and never clobbered.
EOF
}

# ═════════════════════════════════════════════════════════════════════════════
# THE UI LAYER — everything from here down to the State section
# ═════════════════════════════════════════════════════════════════════════════
# Three sections stand together as ONE layer: Output / display helpers, Path
# fitting, and Prompt plumbing. It is the drawing and the asking, and nothing
# else. It ends where the State section begins.
#
# THE RULE, and it is a rule rather than a habit:
#
#   1. Nothing in here may name a box, a bind, an emit dir, an action, or any
#      other global belonging to this program. The layer's inputs are its
#      arguments plus the two UI_* values set at the top of the file; its
#      outputs are the globals it defines itself (ASCII, the palette, ANS and
#      its ANS_* siblings). It does not read droste's model, ever.
#   2. Nothing in here may call a function defined below it. Calls go one way
#      — the program calls into the layer, the layer never calls back out.
#   3. Within the layer the same asymmetry holds one level down: the PROMPT
#      half calls the DISPLAY half freely, and the display half never calls a
#      prompt function. A drawing routine that stops to ask a question is a
#      drawing routine that cannot be lifted out on its own.
#
# WHY IT IS WRITTEN DOWN. All three properties were already TRUE before anyone
# stated them — measured, not designed: zero outward calls, zero project
# globals once ask_port moved down to per-box configuration, zero calls from
# the display half into the prompt half. That is not luck in a file this size,
# it is someone's taste, and taste is exactly the kind of thing that erodes one
# reasonable-looking edit at a time. Jei's ask is that this drawing stay clean
# enough to drop into another project of his; what would cost him that option
# is not the absence of a published interface, it is a single line reaching for
# a box name because the box name happened to be in scope. Nobody would notice
# the day it happened.
#
# So it is checked rather than trusted: ~/canon/notebook/scripts/
# installer-layering.sh asserts all three and is meant to run in CI once this
# file has a job to run in.
#
# TWO THINGS THE RULE DOES NOT COVER, named here so nobody has to discover
# them and conclude the rule is a fiction. The layer's top-level code — the
# --ascii pre-pass and the option loop — calls usage(), which is written ABOVE
# the layer: rule 2 forbids reaching DOWN, and reaching up to the help text a
# host program supplies is how the layer gets one. And ARG_BOXES, the option
# loop's leftovers, is spelled in droste's vocabulary while being an ordinary
# "whatever was not an option" list; it is written here and read below, which
# is the allowed direction, so only its NAME is a wart.
#
# WHAT IS DELIBERATELY NOT CLAIMED. This is a LAYER, not a library. Callers
# reach into its palette variables and format inline far more often than they
# call its atoms, and the palette's names are semantic to droste's own screens
# (C_SVCN, C_PORT, C_SBOX). Extracting the layer is a small job; extracting
# something a stranger could program against is a much larger one, and is not
# what these three rules buy. They buy the option.

# ── Output / display helpers ─────────────────────────────────────────────────
# The mode is settled BEFORE the option loop proper, because usage() and the
# unknown-option error are themselves output: they have to be able to print
# through the atoms below. So --ascii is read from argv in a pass of its own,
# and the loop that consumes the arguments runs after the atoms exist.
ASCII=0
for arg in "$@"; do case "$arg" in --ascii) ASCII=1 ;; esac; done
case "${TERM:-dumb}" in dumb|unknown) ASCII=1 ;; esac
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]*8*|*[Uu][Tt][Ff]*) : ;;
  *) ASCII=1 ;;
esac

if [[ $ASCII -eq 1 ]]; then
  RESET="" DIVCH="-"
  # Prose typography, transliterated at the mode boundary so the sentences
  # themselves are written once: em-dash -> "--", ellipsis -> "...". ELL has no
  # caller at the moment (its last one was a preflight hint the marker rework
  # retired) and is kept anyway: it is one of exactly two atoms standing between
  # a typed "…" and a broken --ascii byte contract, and it costs one assignment.
  # shellcheck disable=SC2034
  EMD="--" ELL="..."
  # Foreground-only palette (see the rework spec). EVERY color rides on one of
  # these variables so --ascii / dumb terminals stay byte-for-byte colorless.
  C_FRAME="" C_TITLE="" C_BTITLE="" C_LABEL="" C_LABEL2="" C_SUB="" C_SUB2="" C_TEXT=""
  C_BRK="" C_OKB="" C_OK="" C_BADB="" C_NOTB="" C_WARNI=""
  C_TBRK="" C_TIDX="" C_ARROW="" C_SUBJ=""
  C_HDR="" C_SVC="" C_PORT="" C_GLYPH="" C_STAR=""
  C_EXE="" C_CMD="" C_TGT="" C_PH=""
  C_EXH="" C_FILE="" C_ERR="" C_STOPW="" C_STOPT=""
  C_PBRK="" C_PDEF="" C_PALT="" C_IN=""
  C_OPTD="" C_OPTN="" C_CTR="" C_SVCN=""
  C_SBOX="" C_SBUL="" C_SHDR="" C_SVAL="" C_SGRP="" C_MOPT="" C_MCAT=""
  C_QTXT="" C_QEXIT="" C_QKEY="" C_DETH="" C_DETN="" C_SELP=""
  C_PATHB="" C_PATHG=""
  C_EMLBL="" C_EMBOX="" C_EMPTH=""
  # Repaint plumbing for the pull progress bar. Empty here on purpose: --ascii
  # (and any dumb terminal) gets the APPEND-ONLY bar instead — a drawing that
  # only ever grows to the right and down, so the section stays byte-for-byte
  # free of control sequences and reads the same in a pipe or a log. BAR_E has
  # no caller there (an append-only bar never draws the part it has not
  # reached), and is kept because the pair is one atom.
  CR="" EL="" BAR_F="#" BAR_E="-"
  # Dashboard state cell — ONE glyph triplet serves all three of On/BoxSv/HostSv.
  # The ASCII glyph already carries its own brackets, so the Legend adds none
  # (GB_L/GB_R empty). Jei's rev-2 spelling is [Y]/[N]/[?] (it supersedes the
  # earlier [+]/[-]/[?], and only here — no other ASCII fallback changed).
  GS_YES="[Y]" GS_NO="[N]" GS_NA="[?]" W_STATE=3 GB_L="" GB_R=""
  BULLET="-" ARROW_G=" ---> " ARROW_M="-->"
  # The three status markers: ok / caution / blocker. They open every preflight
  # row, and the caution sign is also the one marker a QUESTION wears (the
  # stale-cache offer). ASCII keeps the transcript's long-standing [ok]/[!!]
  # pair, so CAUT and BAD deliberately COLLAPSE onto [!!] here: this palette has
  # never spelled a third state, and inventing one ([XX]) would change rows the
  # ASCII transcript has drawn the same way since the rework.
  MK_OK="[ok]" MK_CAUT="[!!]" MK_BAD="[!!]"
  # Hint indent = 2 (row indent) + 4 (marker width) + 1 (the space after it), so a
  # follow-on line starts under its parent row's TEXT rather than under the marker.
  PF_IND="       "
  BOXTL="." BOXTR="." BOXBL="'" BOXBR="'" BOXH="-" BOXV="|"
  # The two banner weights collapse onto the same ASCII drawing in --ascii.
  BANTL="." BANTR="." BANBL="'" BANBR="'" BANH="-" BANV="|"
  BANTL2="." BANTR2="." BANBL2="'" BANBR2="'" BANH2="-" BANV2="|"
else
  RESET=$'\e[0m' DIVCH="─"
  # shellcheck disable=SC2034   # ELL: see the ASCII twin above
  EMD="—" ELL="…"
  C_FRAME=$'\e[0;94m'   # box-drawing frames + section rules
  C_TITLE=$'\e[1;96m'   # installer title (top banner only)
  C_BTITLE=$'\e[0;96m'  # per-box banner title
  C_LABEL=$'\e[0;97m'   # section label inside the rule
  C_LABEL2=$'\e[1;97m'  # section label, intro variant (Preflight, Resource Path)
  C_SUB=$'\e[4;97m'     # underlined subtitle / table header
  C_SUB2=$'\e[4;37m'    # underlined subtitle, intro variant (Resource Path)
  C_TEXT=$'\e[0;37m'    # body + prompt text
  C_BRK=$'\e[0;32m'     # option-list brackets, default row
  # Preflight row text, one shade per marker: green behind ✅, red behind 🚨,
  # yellow behind 🔶. The marker itself is never painted (it is emoji), so each
  # of these opens the row AFTER the glyph and runs to the reset. C_OK is the
  # bright green of the pull section's [OK] tag, which is a different animal
  # from a preflight row and keeps its own bracketed drawing.
  C_OKB=$'\e[0;32m' C_OK=$'\e[0;92m'                      # preflight ✅ row
  C_BADB=$'\e[0;31m'                                      # preflight 🚨 row
  # Reset-prefixed like every other entry so no shade inherits a neighbour's
  # weight; also worn by the one QUESTION that carries the caution sign.
  C_NOTB=$'\e[0;33m'                                      # preflight 🔶 row
  # The one WARNING that rides under an option list: bold italic yellow (Jei's
  # markup). Reset-prefixed like the rest, or it would inherit the weight of
  # whatever drew last.
  C_WARNI=$'\e[0;1;3;33m'
  C_TBRK=$'\e[0;34m' C_TIDX=$'\e[0;94m'  # table [N] + option-list, other rows
  C_ARROW=$'\e[1;91m'   # sub-notice `-> arrow
  C_SUBJ=$'\e[1;97m'    # sub-notice subject
  C_HDR=$'\e[1;4;97m'   # dashboard section titles + column headers
  C_SVC=$'\e[3;37m'     # dashboard service name, and inline asides
  C_PORT=$'\e[1;93m'    # dashboard host port
  C_STAR=$'\e[1;3;97m'  # the *ComfyUI footnote
  C_EXE=$'\e[0;33m'     # a command's executable   (podman, distrobox)
  C_CMD=$'\e[0;95m'     # its verb                 (enter, start, assemble create)
  C_TGT=$'\e[0;92m'     # its target               (paths, container names)
  C_PH=$'\e[0;94m'      # the <box> placeholder inside a target
  C_EXH=$'\e[1;4;97m'   # Executing-section headers (same SGR as C_HDR)
  C_FILE=$'\e[3;37m'    # emitted file names + the closing "Wrote NOTES.md."
  C_ERR=$'\e[1;91m'     # the [ERROR] tag of a failed pull/create status line
  # The word "stop" inside the Shortcuts parenthetical — the one word in it the
  # reader has to TYPE. Its own entry rather than a borrowed one: C_ERR and
  # C_ARROW are the same bold red but mean "this failed" / "aside follows"
  # everywhere else. Deliberately NOT italic: 3;37 renders bold-bright on Jei's
  # terminal, which is why the parenthetical is coloured instead of slanted.
  C_STOPW=$'\e[1;91m'   # ...and its tail, italic grey. Reset-prefixed on purpose:
  C_STOPT=$'\e[0;3;37m'  # it follows the bold red above and must not inherit it.
  # Answer PROMPTS (the "<text> [options] {:|?} " line). Deliberately a
  # different bracket colour from the option LISTS above them: in a prompt the
  # bracket is punctuation around the choice, in a list it indexes the row.
  C_PBRK=$'\e[1;97m'    # prompt [ ]
  C_PDEF=$'\e[1;92m'    # prompt default option / default value
  C_PALT=$'\e[1;94m'    # prompt non-default option
  C_IN=$'\e[1;93m'      # what the user types
  # Option LIST rows: the bracket keeps the dark shade, the whole row text takes
  # the bright one (default = green, everything else = blue).
  C_OPTD=$'\e[1;92m' C_OPTN=$'\e[1;94m'
  C_CTR=$'\e[0;33m'     # box table: Container column
  C_SVCN=$'\e[1;95m'    # box table: Service column
  # Per-box summary box: C_SGRP = its "* Paths" / "* Server" group headers,
  # C_SHDR = the "+ Data Path:" row labels (body-text grey — the label says what
  # the row is, the VALUE is what the eye is looking for).
  C_SBOX=$'\e[0;36m' C_SBUL=$'\e[1;92m' C_SHDR=$'\e[0;37m' C_SVAL=$'\e[1;96m'
  C_SGRP=$'\e[1;4;94m'
  C_MOPT=$'\e[1;92m'    # mitigation line: the option applied (fuse/copy/ignore)
  C_MCAT=$'\e[1;94m'    # mitigation line: the path categories it applies to
  # Quit notice + the detected-configurations listing + inline path emphasis.
  # LEAK-PRONE BY CONSTRUCTION (fixed): "3;37" adds italic and sets the
  # foreground but clears NO weight, so re-entering it after a bold fragment on
  # the same line inherits the bold. This one re-enters twice (after "exit" and
  # after "quit"), hence the explicit leading reset. Its siblings C_SVC / C_FILE
  # are the same shape but only ever open a line or follow a RESET, so they are
  # left exactly as they are.
  C_QTXT=$'\e[0;3;37m'  # quit notice body (light grey italic)
  C_QEXIT=$'\e[1;93m'   # the word "exit" in the quit notice
  C_QKEY=$'\e[1;92m'    # the word "quit" (what the user actually types)
  C_DETH=$'\e[1;3;4;95m'  # "Previous box setup configurations detected:"
  C_DETN=$'\e[0;33m'    # box names in the detected-configurations listing
  C_SELP=$'\e[1;3;95m'  # "Select the boxes you wish to edit, modify, or rebuild."
  C_PATHB=$'\e[1;94m'   # inline emphasis, bold bright blue (paths / keywords)
  C_PATHG=$'\e[1;92m'   # inline emphasis, bold bright green (paths)
  # The three fragments Jei marked up BY NAME in his s41 move-flow examples
  # (droste-s41-move-{with,without}-base-files.txt). Each is derived from a
  # weight that already exists in this palette rather than invented, and each is
  # reset-prefixed — they open INSIDE a prompt line, after other painted
  # fragments, so without the leading 0; they would inherit whatever ran last.
  #   C_EMLBL  "<label> path", the subject of the course-of-action question:
  #            "bold, italic, bright purple". Bright purple is 95, the shade
  #            C_SELP/C_DETH already use for a line addressed AT the reader.
  #   C_EMBOX  "all boxes", in both batch questions: "bold, italic, dark
  #            yellow" — the same three attributes as C_WARNI (0;1;3;33), which
  #            is the *Warning: line rendered directly above it.
  #   C_EMPTH  "all data paths": "bold, italic" with no colour named, so it
  #            keeps body text's own grey (C_TEXT is 0;37) and adds 1;3.
  C_EMLBL=$'\e[0;1;3;95m'
  C_EMBOX=$'\e[0;1;3;33m'
  C_EMPTH=$'\e[0;1;3;37m'
  # Repaint plumbing for the pull progress bar: carriage return + erase-to-EOL
  # (the bar can be wider than the status line that replaces it).
  CR=$'\r' EL=$'\e[K' BAR_F="▓" BAR_E="░"
  # The emoji glyphs bring their own color, so the state cell resets to bare.
  C_GLYPH=$RESET
  # Dashboard state cell — ONE glyph triplet serves all three of On/BoxSv/HostSv.
  # ⚫ covers NA *and* unknown, so there is no separate "unknown" glyph. The
  # Legend wraps the emoji in its own brackets (GB_L/GB_R).
  GS_YES=$'\U1F7E2' GS_NO=$'\U1F6D1' GS_NA=$'⚫' W_STATE=2 GB_L="[" GB_R="]"
  BULLET="·" ARROW_G=" 🭹🭹🭹⮞ " ARROW_M="🭹🭹⮞"
  # The three status markers — ✅ ok / 🔶 something to decide about / 🚨 blocker.
  # BORN-EMOJI ONLY (U+2705, U+1F536, U+1F6A8): each is Emoji_Presentation by
  # default, so it is two columns wide with no VS16 promotion in sight — a
  # VS16-promoted glyph (⚠️ and its class) is what breaks the width math. They
  # bring their own colour, so nothing is painted onto them; the row's colour
  # opens AFTER the marker.
  MK_OK=$'\U2705' MK_CAUT=$'\U1F536' MK_BAD=$'\U1F6A8'
  # Same arithmetic, different marker width: these are BORN-emoji and occupy exactly
  # two display columns, so 2 + 2 + 1 = 5.
  PF_IND="     "
  BOXTL="┌" BOXTR="┐" BOXBL="└" BOXBR="┘" BOXH="─" BOXV="│"
  # Banners come in two weights: DOUBLE for the one installer title, HEAVY for
  # the per-box titles. The light set above is the summary box's.
  BANTL="╔" BANTR="╗" BANBL="╚" BANBR="╝" BANH="═" BANV="║"
  BANTL2="┏" BANTR2="┓" BANBL2="┗" BANBR2="┛" BANH2="━" BANV2="┃"
fi

# The options themselves. --ascii was already read above; it is matched again
# here only so it does not fall through to the box list.
ARG_BOXES=()
for arg in "$@"; do
  case "$arg" in
    --ascii) ;;
    -h|--help) usage; exit 0 ;;
    -*) printf '%s: unknown option: %s\n' "$UI_PROG" "$arg" >&2; usage >&2; exit 2 ;;
    *) ARG_BOXES+=("$arg") ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" | fold -s -w "$(disp_width)"; }
die()  { printf '%s: %s\n' "$UI_PROG" "$*" >&2; exit 1; }
wrap() { printf '%s\n' "$*" | fold -s -w "$(disp_width)"; }

section() {   # ── Name ──────... divider, 78 cols.  name [intro]
  # "intro" = the opening sections (Preflight, Resource Path), which Jei drew
  # with a bolder label than the rest.
  # 78 is the drawn width; on a narrower terminal the rule clamps to the screen
  # rather than wrapping onto a second line of stray divider characters.
  local name=$1 style=${2:-} line fill i n w lcol=$C_LABEL
  [[ $style == intro ]] && lcol=$C_LABEL2
  w=$(disp_width)
  n=$(( w - ${#name} - 5 ))
  [[ $n -lt 1 ]] && n=1
  fill=""
  # shellcheck disable=SC2324  # string append of the divider char, not math
  for (( i = 0; i < n; i = i + 1 )); do fill+=$DIVCH; done
  printf '\n%s%s %s%s%s %s%s%s\n' \
    "$C_FRAME" "$DIVCH$DIVCH" "$lcol" "$name" "$C_FRAME" "$fill" "$DIVCH" "$RESET"
}

# One combined SGR ("1;4;97") rather than color-then-attributes: three separate
# codes render identically but cost three sequences instead of one.
hdr() { printf '%s%s%s\n' "$C_HDR" "$1" "$RESET"; }

# One selectable menu option row: "  [x]rest<pad>tail". The option that is the
# CURRENT DEFAULT wears the green [default] colors; every other option wears
# the blue index colors.
#
# The letter's CASE is set here, not by the caller: capital when it is the
# current default, lowercase otherwise -- the [Y/n] convention, and the same
# rule ask_choice's own "[d/s/B]" hint follows. Callers used to hard-code it,
# which pinned each group's INITIAL default (K, F, B, A) capital forever, so a
# moved default left the rows contradicting the hint one line below them. Case
# is display-only: ask_choice lowercases both sides before validating.
# Padding is emitted only when there is a tail.
#
# Colour: the brackets keep the dark shade (green when this row is the current
# default, blue otherwise) and EVERYTHING else on the row — letter, rest, pad,
# tail — takes the matching bright one, so a row reads as one object.
opt_row() {   # letter rest tail column-width is-default
  local ltr=$1 rest=$2 tail=$3 cw=$4 isdef=$5 brk txt pad=0
  if [[ $isdef -eq 1 ]]; then
    brk=$C_BRK txt=$C_OPTD ltr=${ltr^^}
  else
    brk=$C_TBRK txt=$C_OPTN ltr=${ltr,,}
  fi
  if [[ -n $tail ]]; then
    pad=$(( cw - ${#rest} - 3 )); [[ $pad -lt 1 ]] && pad=1
  fi
  printf '  %s[%s%s%s]%s%s%*s%s%s\n' \
    "$brk" "$txt" "$ltr" "$brk" "$txt" "$rest" "$pad" "" "$tail" "$RESET"
}

# 1 when $1 is the default letter of an ask_choice letters string ($2 = that
# string; its first character is the default, by ask_choice's own contract).
isdef() { [[ $1 == "${2:0:1}" ]] && printf 1 || printf 0; }

# PROMPT STRUCTURE (installer-wide, Jei s33):
#     <prompt text> [options] {':'|'?'} <one trailing space>
# The terminal punctuation sits AFTER the options cluster — ':' closes a value
# prompt, '?' a yes/no one — and the prompt text itself never ends in '?'.
# y/n options are always listed y-first with the DEFAULT capitalised.
#
# A colored "[default]" bracket for value prompts (white [ ], green value).
dflt() { printf '%s[%s%s%s]%s' "$C_PBRK" "$C_PDEF" "$1" "$C_PBRK" "$C_TEXT"; }

# The multi-option cluster "[d/s/B]" of a choice prompt, painted per option:
# the DEFAULT (the capital letter, matched case-insensitively against $2) green,
# every other option blue, the separators and the closing punctuation body text.
# $1 = slash-separated options in DISPLAY order, $2 = the default option.
hint() {   # "d/s/B" default
  local opts=$1 def=$2 tok first=1 out=""
  local IFS=/
  for tok in $opts; do
    [[ $first -eq 1 ]] || out+="$C_TEXT/"
    first=0
    if [[ ${tok,,} == "${def,,}" ]]; then out+="$C_PDEF$tok"; else out+="$C_PALT$tok"; fi
  done
  printf '%s[%s%s]%s' "$C_PBRK" "$out" "$C_PBRK" "$C_TEXT"
}

# The y/n cluster: always [y/N] order, the default capitalised.
hint_yn() {   # Y|N
  if [[ $1 == Y ]]; then hint "Y/n" Y; else hint "y/N" N; fi
}

# Indented red `-> sub-notice (secondary information about the answer above),
# set off from the next prompt by a blank line.
subnote() { printf '  %s `-> %s%s%s\n\n' "$C_ARROW" "$C_TEXT" "$1" "$RESET"; }

# Preflight rows, one marker each — ✅ this is fine / 🔶 a possible blocker, or
# something the reader has to decide about / 🚨 a definite blocker. A preflight
# problem is reported here rather than through warn(), and only one of them ends
# the run (pf_session); the markers say which rows the reader must act on
# without making the run stop to say it.
#
# Layout, byte for byte: two spaces, the marker (two columns — born-emoji, see
# the palette), the row colour, ONE space, the text, reset. The colour opens
# after the glyph so nothing repaints the emoji, and the space lives inside it
# so the row ends in exactly one reset.
pf_ok()   { printf '  %s%s %s%s\n' "$MK_OK"   "$C_OKB"  "$1" "$RESET"; }
pf_bad()  { printf '  %s%s %s%s\n' "$MK_BAD"  "$C_BADB" "$1" "$RESET"; }
pf_note() { printf '  %s%s %s%s\n' "$MK_CAUT" "$C_NOTB" "$1" "$RESET"; }

# Follow-on detail under a preflight row — body-text grey, with any command emph()'d
# inside the string.
# ⚠️ THE INDENT IS MODE-DEPENDENT AND MUST BE (s45). It used to be a hardcoded four
# spaces, inherited from linger_fallback_note() rather than measured against the row it
# hangs under, so it landed one column left of the parent text in terminal mode and
# THREE left in --ascii (the ASCII markers are `[ok]`/`[!!]`, four columns wide, while
# the emoji are two). PF_IND is set beside the markers themselves, which is the only
# place that knows how wide they are.
pf_hint() { printf '%s%s%s%s\n' "$PF_IND" "$C_TEXT" "$1" "$RESET"; }

# A titled box drawn with the banner glyphs (ASCII in --ascii mode).
# banner text [bold]  — titles are all-ASCII so byte length == display width.
# Two weights: the ONE installer title is DOUBLE-ruled, each per-box title HEAVY.
BANNER_W=0                       # outer width of the last banner drawn
banner() {   # text [bold] [min-inner-width]
  local text=$1 bold=${2:-} minw=${3:-0} n i fill top mid bot tcol pad
  local tl=$BANTL tr=$BANTR bl=$BANBL br=$BANBR h=$BANH v=$BANV
  n=$(( ${#text} + 2 ))          # text plus one space of padding each side
  # A caller that knows what will be drawn UNDER the banner (a per-box summary
  # box) hands its width in, and the banner grows to it: the title stays where
  # it is and the extra columns are added on the right, inside the frame.
  [[ $minw -gt $n ]] && n=$minw
  # "bold" marks the per-box banners; the top installer banner is the title one.
  if [[ $bold == bold ]]; then
    tcol=$C_BTITLE
    tl=$BANTL2 tr=$BANTR2 bl=$BANBL2 br=$BANBR2 h=$BANH2 v=$BANV2
  else
    tcol=$C_TITLE
  fi
  BANNER_W=$(( n + 2 ))
  fill=""
  for (( i = 0; i < n; i = i + 1 )); do fill+=$h; done
  top="$tl$fill$tr"
  bot="$bl$fill$br"
  # The padding after the title is FRAME-coloured (it is frame, not title), and
  # it is one space in the ordinary case — the same line the banner always drew.
  printf -v pad '%*s' "$(( n - ${#text} - 1 ))" ''
  mid="$v $tcol$text$C_FRAME$pad$v"
  printf '\n'
  # Wrap each line separately so it renders even when RESET is empty (--ascii).
  printf '  %s%s%s\n' "$C_FRAME" "$top" "$RESET"
  printf '  %s%s%s\n' "$C_FRAME" "$mid" "$RESET"
  printf '  %s%s%s\n' "$C_FRAME" "$bot" "$RESET"
}

# Jei's coloured droste mark, the same art the in-box toolbox banners draw
# (droste-ai-halo commit 198f3f9), re-indented to sit above the installer title.
# It is ANSI + private-use box glyphs by construction, so --ascii skips it.
logo_header() {
  [[ $ASCII -eq 1 ]] && return 0
  printf '\n'
  printf '%s\n' \
    $' \033[1;97m ╔\033[1;96m═╤\033[1;94m═╤\033[0;34m════╗ \033[1;90m🭺🭺🭺🭺🭺\033[0;37m🭺🭺🭺🭺🭺🭺\033[1;97m🭺🭺🭺🭺🭺🭺🭺🭺\033[0;37m🭺🭺🭺🭺🭺🭺\033[1;90m' \
    $' \033[1;96m ╟─┘\033[0;37m■\033[0;94m│\033[0;34m    ║ \033[1;90m █🮂🮂\033[0;37m🭕🭏    \033[1;97m        \033[0;37m🭋' \
    $' \033[1;94m ╟───┘ \033[0;34m\033[1;97m██ \033[0;34m║ \033[1;90m █ \033[0;37m  █ 🭩🬂\033[1;97m🭗🭄🮂🭏 🭄🮀🭧\033[0;37m🭢🬨🬂🭗🭂🮀\033[1;90m🭍' \
    $' \033[0;34m ║ \033[0;34m\033[0;34m\033[0;34m       ║ \033[1;90m █\033[0;37m  🭊🭠 🭞\033[1;97m  🭕▂🭠 ▄ \033[0;37m🭨🭬🭦🭩🭛🭓\033[1;90m🬭🬽' \
    $' \033[0;34m\033[0;34m\033[0;34m\033[0;34m ╚════════╝ \033[1;90m`\033[0;37m🮃🮃🮃🭘🭷🭷\033[1;97m🭷🭷🭷🭷🭷🭷🭷🭣\033[0;37m🬂🭘🭷🭷🭷🭷\033[1;90m🭷🭷🭷🭷\033[0m'
  return 0
}

# "[a, b, c]" — light-grey brackets and separators, the names in $1's colour.
name_list() {   # colour name...
  local col=$1 n out="" first=1
  shift
  for n in "$@"; do
    [[ $first -eq 1 ]] || out+="$C_TEXT, "
    first=0
    out+="$col$n"
  done
  printf '%s[%s%s]%s' "$C_TEXT" "$out" "$C_TEXT" "$RESET"
}

# Inline emphasis inside a prompt: the fragment takes the named colour and the
# prompt's body colour is restored after it (ask_raw opened the line in C_TEXT).
emph()  { printf '%s%s%s' "$C_PATHB" "$1" "$C_TEXT"; }
emphg() { printf '%s%s%s' "$C_PATHG" "$1" "$C_TEXT"; }
# The same thing in a colour the caller names — for the marked-up fragments that
# have one entry each rather than one shared "emphasis" shade. Restoring C_TEXT
# (0;37, reset-prefixed) is what CLEARS the bold and the italic again: the hint
# cluster that follows opens on C_PBRK (1;97), which sets no reset of its own,
# so an unrestored italic would slant the "[Y/n]?" too.
emphc() { printf '%s%s%s' "$1" "$2" "$C_TEXT"; }

# Underlined subtitle printed under a section divider (blank line, then indent).
# "intro" = the Resource Path subtitle, drawn a shade dimmer in the mockup.
sub() {   # text [intro]
  local scol=$C_SUB
  [[ ${2:-} == intro ]] && scol=$C_SUB2
  printf '\n  %s%s%s\n' "$scol" "$1" "$RESET"
}

# A SUBHEADER inside a section — bold, bright white, underlined (the heavier
# cousin of sub()). It groups a run of questions that share a subject:
# "Networking" / "Storage Paths" in General Setup, "Networking" / "<Box> Paths"
# in a per-box Box Settings section.
subhdr() {   # text
  printf '\n  %s%s%s\n' "$C_HDR" "$1" "$RESET"
}

# An EXPLAINER above a run of prompts: sub()'s placement (blank line, indent
# two) in the quit notice's voice — light grey italic, the shade this installer
# uses for a sentence that explains rather than titles. A subtitle names the
# block it opens; this one tells the reader what the block is going to ask for,
# so it is deliberately NOT the underlined subtitle style (Jei's mock).
explain() {   # text
  printf '\n  %s%s%s\n' "$C_QTXT" "$1" "$RESET"
}

# Pad a cell whose DISPLAY width may differ from its byte length (emoji).
pad_cell() {   # text display-width column-width
  local text=$1 dw=$2 cw=$3 n
  n=$(( cw - dw )); [[ $n -lt 1 ]] && n=1
  printf '%s%*s' "$text" "$n" ""
}

# Same as pad_cell, but styles the WORDS only — the padding stays plain.
# UNDERLINE is the one attribute in this palette that renders on blanks (a bold
# space is a space; a colored space is a space), which is why this variant, and
# only this variant, spends a RESET before the padding.
pad_cell_u() {   # text display-width column-width
  local text=$1 dw=$2 cw=$3 n
  n=$(( cw - dw )); [[ $n -lt 1 ]] && n=1
  printf '%s%s%s%*s' "$C_HDR" "$text" "$RESET" "$n" ""
}

# Responsive output width, one column under the terminal so nothing ever touches
# the right edge. 59 is the floor (a phone) — narrower than that we accept
# wrapping rather than eliding, because the command lines below the table are
# copy-paste payload and a truncated command is worse than a wrapped one.
#
# `tput cols` FIRST, not COLUMNS: bash only maintains COLUMNS in an interactive
# shell with checkwinsize, so in the documented `curl … | bash` path it is always
# unset and a COLUMNS-only reading would silently pin the width to the fallback
# forever. COLUMNS still wins when explicitly exported, which is how the tests
# drive this.
term_width() {
  local w=${COLUMNS:-}
  [[ -z $w ]] && w=$(tput cols 2>/dev/null || echo 80)
  case "$w" in ''|*[!0-9]*) w=80 ;; esac
  w=$(( w - 1 )); [[ $w -lt 59 ]] && w=59
  printf '%s' "$w"
}

# THE DRAWN WIDTH of everything this script prints: the design is 78 columns
# and it does NOT stretch — a wide terminal shows the same shape as an 80-column
# one, because these blocks are read as a fixed layout, not as flowed text. A
# NARROW terminal clamps down to it, which is what keeps a 60-column phone from
# ragged-wrapping every table row. Every budget, pad and elision below measures
# against this, never against the raw terminal.
DESIGN_W=78
disp_width() {
  local w
  w=$(term_width)
  [[ $w -gt $DESIGN_W ]] && w=$DESIGN_W
  printf '%s' "$w"
}

# Clip a plain (non-path) string to a column budget, marking the cut with the
# same three literal dots fit_path uses. Paths keep their own shrinker, which
# protects their shape; this is for prose cells like the box-table description.
clip() {   # text width
  local t=$1 w=$2
  if [[ ${#t} -le $w ]]; then printf '%s' "$t"; return 0; fi
  if [[ $w -lt 4 ]]; then printf '%.*s' "$w" "$t"; return 0; fi
  _fp_cut "$t" $(( w - 3 ))
}

# (home_disp, which compressed $HOME → ~ for display, is GONE as of s39. Every
# path this installer shows is now shown as the person who chose it wrote it —
# typed, read back out of their ini, or inherited from the root it hangs off —
# and a factory default is spelled with a literal ~ to begin with. There is
# nothing left for a re-speller to do, and keeping one would only offer a way
# to put the bug back.)

# ── Path fitting ─────────────────────────────────────────────────────────────
# Shrink a path to a cell budget, surrendering detail in this order (the LAST
# item surrendered is the most protected):
#   4. inner directories — revealed a character at a time from BOTH ends
#   3. the rest of the leaf filename
#   2. ~, the level below it, and the leaf's PARENT directory
#   1. the leaf's first 8 characters — held while anything else remains
# Tier 2 outranks tier 3, so a squeezed path keeps its SHAPE (where the file
# lives) even at the cost of a blunter filename. It is CONDITIONAL: a path that
# already fits is left alone. Abbreviation is three literal dots, never "…",
# because the ellipsis character is tofu on some of the terminals this runs on.
# Widths are character counts: these are filesystem paths, all narrow.
FP_LEAF_MIN=8
_FP_HEAD="" _FP_D1="" _FP_PARENT="" _FP_LEAF="" _FP_INNER="" _FP_BUDGET=0

# Truncate to n characters and append "..." — stripping any separator left
# stranded against it first, since "vllm_config." + "..." reads as four dots.
_fp_cut() {   # text n
  local s=${1:0:$2}
  while [[ -n $s && $s == *[-._\ ] ]]; do s=${s%?}; done
  printf '%s...' "$s"
}

# One candidate rendering. leaf_k/inner_n of -1 mean "whole", inner_n of 0 means
# "replaced by ...", and keep_d1/keep_parent are the two tier-2 components.
_fp_render() {   # leaf_k inner_n keep_d1 keep_parent
  local lk=$1 inn=$2 kd1=$3 kp=$4 ls mid="" l r parts=()
  if [[ $lk -lt 0 ]]; then ls=$_FP_LEAF; else ls=$(_fp_cut "$_FP_LEAF" "$lk"); fi
  if [[ -n $_FP_INNER ]]; then
    if [[ $inn -lt 0 ]]; then mid=$_FP_INNER
    elif [[ $inn -eq 0 ]]; then mid="..."
    else
      l=$(( (inn + 1) / 2 )); r=$(( inn - l ))
      mid="${_FP_INNER:0:l}..."
      [[ $r -gt 0 ]] && mid+="${_FP_INNER: -r}"
    fi
  fi
  parts=("$_FP_HEAD")
  [[ $kd1 -eq 1 ]] && parts+=("$_FP_D1")
  if [[ -n $mid ]]; then parts+=("$mid")
  elif [[ $kd1 -eq 0 ]]; then parts+=("...")   # never let the head abut the parent
  fi
  [[ $kp -eq 1 ]] && parts+=("$_FP_PARENT")
  parts+=("$ls")
  local IFS=/
  printf '%s' "${parts[*]}"
}

# The richest rendering that fits for one tier-2 configuration: buy back the
# leaf first (tier 3), then the inner directories (tier 4). Returns 1 when even
# the bluntest rendering of this configuration is too wide.
_fp_best() {   # keep_d1 keep_parent
  local kd1=$1 kp=$2 lk cand out k n
  cand=$(_fp_render "$FP_LEAF_MIN" 0 "$kd1" "$kp")
  [[ ${#cand} -le $_FP_BUDGET ]] || return 1
  lk=$FP_LEAF_MIN
  cand=$(_fp_render -1 0 "$kd1" "$kp")
  if [[ ${#cand} -le $_FP_BUDGET ]]; then
    lk=-1
  else
    for (( k = ${#_FP_LEAF} - 1; k >= FP_LEAF_MIN; k = k - 1 )); do
      cand=$(_fp_render "$k" 0 "$kd1" "$kp")
      if [[ ${#cand} -le $_FP_BUDGET ]]; then lk=$k; break; fi
    done
  fi
  # Re-maximise the inner directories against the leaf we just settled on: an
  # earlier draft kept the first fit and wasted up to five cells.
  out=$(_fp_render "$lk" 0 "$kd1" "$kp")
  cand=$(_fp_render "$lk" -1 "$kd1" "$kp")
  if [[ ${#cand} -le $_FP_BUDGET ]]; then
    out=$cand
  else
    for (( n = ${#_FP_INNER}; n >= 1; n = n - 1 )); do
      cand=$(_fp_render "$lk" "$n" "$kd1" "$kp")
      if [[ ${#cand} -le $_FP_BUDGET ]]; then out=$cand; break; fi
    done
  fi
  printf '%s' "$out"
}

fit_path() {   # path budget → path shrunk to fit
  local p=$1 comps=() n m i cand
  # Tier-2 configurations, richest first: keep ~/<level>/…/<parent>, then drop
  # the level below ~, then drop the leaf's parent too.
  local kd1s=(1 0 0) kps=(1 1 0)
  _FP_BUDGET=$2
  if [[ ${#p} -le $_FP_BUDGET ]]; then printf '%s' "$p"; return 0; fi
  IFS=/ read -r -a comps <<<"$p"
  n=${#comps[@]}
  m=$(( _FP_BUDGET - 3 )); [[ $m -lt 1 ]] && m=1
  if [[ $n -lt 4 ]]; then _fp_cut "$p" "$m"; return 0; fi
  _FP_HEAD=${comps[0]} _FP_D1=${comps[1]}
  _FP_PARENT=${comps[n - 2]} _FP_LEAF=${comps[n - 1]}
  _FP_INNER=$(IFS=/; printf '%s' "${comps[*]:2:n - 4}")
  for (( i = 0; i < 3; i = i + 1 )); do
    if cand=$(_fp_best "${kd1s[i]}" "${kps[i]}"); then
      printf '%s' "$cand"; return 0
    fi
  done
  _fp_cut "$_FP_LEAF" "$m"
}

# Shrink the PAYLOAD of a "label: payload" note (the label is the part that says
# what to do, so it is never touched). Notes with no label shrink whole.
fit_note() {   # note budget → note
  local note=$1 budget=$2 label=""
  [[ -z $note ]] && { printf ''; return 0; }
  if [[ $note == *": "* ]]; then label="${note%%: *}: "; note=${note#"$label"}; fi
  printf '%s' "$label"
  fit_path "$note" "$(( budget - ${#label} ))"
}

# A BARE WORD IS A HOME-RELATIVE PATH, NEVER A CWD-RELATIVE ONE. The installer
# is documented as `curl … | bash`, so its cwd is wherever the user happened to
# be standing — a repo checkout, /tmp, anywhere. Resolving "droste2" against
# that quietly created (and mkdir -p'd) a directory in a stranger's working
# directory; resolving it against $HOME puts it where every default the
# installer offers already lives. `./foo` lands there too: the leading ./ is the
# quit-escape marker (see quit_notice), not a request for the cwd.
#
# A SYMLINK IS AN ANSWER, NOT A DETOUR. `realpath -m` used to resolve the whole
# spelling down to its physical target, so answering ~/models (a link to
# /mnt/fast/models today, /mnt/bigger/models next month) stored the target and
# froze the choice into every ini, unit and NOTES line. The link is a level of
# indirection the user is keeping deliberately, so what they typed is what is
# stored — -s (--no-symlinks) keeps the tidy-up LEXICAL. Anything needing
# the physical path resolves it for itself, transiently: findmnt --target in
# probe_fstype follows the link at probe time, and the kernel follows it at
# mkdir / mount time (so a re-pointed link takes effect at the next box start,
# which is the whole point of keeping it).
#
# AND A ~ IS AN ANSWER TOO (Jei s39). This used to expand ~ in the same breath,
# which meant a stored path could never say ~ again — the installer showed a
# spelling the user had never typed, and on a host whose $HOME is reached by an
# unusual name it showed one that appeared nowhere in their files. The two jobs
# are separate and only one of them belongs to STORAGE:
#
#   "A relative path is different from a symbolic path. We can't deal in
#    relative paths, so they have to be made absolute. But ~/foo and /srv are
#    both absolute in terms of resolvability within a given context." — Jei
#
# So: relatives are absolutized HERE, at input, because they are unresolvable
# without a cwd the installer refuses to guess (a bare word means $HOME, per the
# note above) — and after that the absolute form IS what the user typed. A ~
# spelling is already resolvable, so it is left exactly as written; fs_path
# resolves it, transiently, for the kernel and for the volume= lines podman
# binds. Nothing stores or displays the result of that.
abs_path() {  # absolutize (relative → $HOME) + lexical normalize; ~ kept as ~
  local p=$1 q tail
  # shellcheck disable=SC2088  # matching a LITERAL leading ~ is the point
  case "$p" in
    "~"|"~/") printf '~'; return 0 ;;
    # The tail is normalised as if it were rooted, then the ~ is put back:
    # `realpath` has no idea what a ~ is and would read it as a directory name
    # in the CWD, which is the one place this installer never resolves against.
    "~/"*) tail=${p#\~/}; p=/$tail ;;
    /*) : ;;
    *) p=$HOME/$p ;;
  esac
  # Collapse ., .., //  without requiring the path to exist AND without walking
  # any link. Assigned only on success: a host with no realpath(1) would
  # otherwise get an EMPTY path out of a substitution that failed.
  if q=$(realpath -m -s -- "$p" 2>/dev/null); then p=$q; fi
  # shellcheck disable=SC2088  # putting the LITERAL ~ back is the point
  case "$1" in
    # "~/.." normalises its tail down to "/", which as a tail means the home
    # directory itself — the bare ~ spelling, not a trailing slash fs_path
    # would then have to special-case.
    "~/"*) if [[ $p == / ]]; then printf '~'; else printf '~%s' "$p"; fi ;;
    *)     printf '%s' "$p" ;;
  esac
}

# The transient other half: the path to hand the KERNEL (and podman). Called at
# the filesystem boundary and nowhere else — every mkdir, test, glob, redirect
# and volume= source goes through it, and its result is never stored, never
# compared against a stored value and never printed.
fs_path() {  # stored spelling → resolved path
  local p=$1
  # shellcheck disable=SC2088  # matching a LITERAL leading ~ is the point
  case "$p" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${p#\~/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# Do two spellings name the SAME directory? Walking symlinks is precisely what
# abs_path refuses to do when STORING a path (a link is an answer, not a
# detour), but a comparison is transient and has to see through them — the same
# licence probe_fstype's `findmnt --target` takes. Falls back to a literal
# compare on a host with no realpath(1).
#
# EVERY MACHINE DECISION IS SPELLING-INDEPENDENT: this is what lets ~/foo and
# /srv/foo be recognised as one directory (they are, whatever the ini says), so
# a difference in spelling can change what is DISPLAYED and nothing else.
same_dir() {  # a b → 0 when both spellings resolve to one directory
  local a b
  a=$(fs_path "$1"); b=$(fs_path "$2")
  a=$(realpath -m -- "$a" 2>/dev/null) || a=$(fs_path "$1")
  b=$(realpath -m -- "$b" 2>/dev/null) || b=$(fs_path "$2")
  [[ $a == "$b" ]]
}

# ── Prompt plumbing (curl|bash-safe: /dev/tty, or the scripted-input hook) ───
ASK_FD=""
SCRIPTED=0
READLINE=0        # 1 = prompts are read through readline (line editing works)
init_input() {
  # One read of the hook, through its NAME (see UI_INPUT_VAR at the top): the
  # value is used three times and the name once, in the message, so a caller
  # that spells the hook differently gets an error that names ITS variable.
  local src=${!UI_INPUT_VAR-}
  if [[ -n "$src" ]]; then
    [[ -r "$src" ]] || die "cannot read $UI_INPUT_VAR=$src"
    exec {ASK_FD}<"$src"
    SCRIPTED=1
  else
    if ! exec {ASK_FD}</dev/tty; then
      die "no controlling terminal for prompts (this installer is interactive)"
    fi
    # A bare `read` leaves the terminal in canonical mode, where the LINE
    # DISCIPLINE echoes an arrow key as the literal bytes it sent: pressing ←
    # printed "^[[D" and put ESC [ D in the answer. `read -e` hands the line to
    # readline instead, which is what turns those keys back into editing (and
    # brings TAB path completion + bracketed paste along). Scripted input never
    # takes this door: `read -p` prints nothing when stdin is not a terminal,
    # which would silently swallow every prompt in the transcript.
    #
    # Probed rather than assumed — a bash built without readline rejects -e,
    # and this script runs on whatever the host has. The here-string feeds the
    # probe one empty line: reading EOF would fail for want of INPUT (status 1)
    # and say nothing about the option.
    #
    # Not under --ascii: that mode is the BYTE-STREAM tier (TERM=dumb, pipes,
    # captures) — zero escape bytes on the wire, and readline would break the
    # contract all by itself (bracketed-paste toggles ESC[?2004h/l around
    # every prompt). Line editing is a terminal feature; --ascii's consumers
    # are not terminals, so nothing of value is given up.
    if [[ $ASCII -eq 0 ]] && (IFS= read -e -r _rl_probe <<<"") >/dev/null 2>&1; then
      READLINE=1
    fi
  fi
}

# Readline places the cursor by counting the prompt it was GIVEN, so every
# non-printing SGR sequence inside it has to be fenced with \001..\002 or the
# escape bytes are counted as width. Unfenced, the first redraw that goes back
# to the start of the line (Ctrl-A, then type) reprints the answer OVER the
# prompt — which is how this was found.
rl_prompt() {   # painted prompt → the same prompt, its colours fenced
  local s=$1 out="" esc=$'\e' re
  re="^([^$esc]*)($esc\[[0-9;]*[a-zA-Z])(.*)$"
  while [[ $s =~ $re ]]; do
    out+="${BASH_REMATCH[1]}"$'\001'"${BASH_REMATCH[2]}"$'\002'
    s=${BASH_REMATCH[3]}
  done
  printf '%s%s' "$out" "$s"
}

# QUIT ANYWHERE. Every prompt in the installer goes through ask_raw, so ONE
# check here covers ask_yn / ask_choice / ask_path_as / ask_port / the box
# selection. It is armed by the notice printed after Preflight (nothing is
# prompted before that), and it matches the RAW answer only — a user who really
# does want a directory called "quit" writes "./quit", which abs_path
# absolutizes (to $HOME/quit — never to the cwd) and this test never sees.
QUIT_ARMED=0
quit_now() {
  printf '\n  %sExiting %s %s no further changes made.%s\n\n' \
    "$C_TEXT" "$UI_PROG" "$EMD" "$RESET"
  exit 0
}

# The notice itself: body light grey italic, "exit" bold bright yellow, "quit"
# (the word you actually type) bold bright green.
quit_notice() {
  printf '\n  %sTo %s%s%s at any time, enter %s%s%s at the prompt.%s\n' \
    "$C_QTXT" "$C_QEXIT" "exit" "$C_QTXT" "$C_QKEY" "quit" "$C_QTXT" "$RESET"
  QUIT_ARMED=1
  return 0
}

ANS=""
# Text printed between the indent and the prompt's body colour, for the one
# prompt shape that opens with something that is NOT body text (the caution
# sign and the clause it introduces). Empty for every other prompt, and cleared
# by the helper that sets it — ask_raw only reads it.
ASK_LEAD=""
# What TAB inserts at this prompt. Empty = leave readline's own TAB alone, which is
# FILENAME COMPLETION — the thing that made `read -e` worth having at a path prompt.
# Set to a short answer (a letter) by the choice helpers below, which is what makes
# TAB fill the default in at a [Y/n], [y/n/c] or [M/r/u/k] prompt.
#
# Jei ruled the behaviour (s45): "tab at Y/n should fill in the default answer".
# ⭐ It FILLS, it does not ANSWER: the macro inserts the letter into the line and the
# user still presses Enter, so TAB never commits a choice on its own. Pre-filling with
# `read -e -i` was the other candidate and is a different thing — it shows the default
# as already-typed text before the user touches anything, which changes what every
# prompt looks like.
# ⚠️ Filename completion at a y/n prompt was never harmful (the answer is validated and
# re-prompted); it was USELESS, and TAB is the key a user presses when they want the
# obvious thing to happen. This makes the obvious thing happen.
ASK_TAB=""
# 🔧 `bind` in a NON-INTERACTIVE shell prints "line editing not enabled" on stderr and
# still returns 0 — and the binding really does reach a later `read -e`. Measured
# through a pty before this was written, because the warning reads like a refusal and
# is not one. stderr is discarded for that reason, and `|| :` keeps errexit out of it.
ask_tab_bind() {   # macro → TAB inserts it; empty → TAB is filename completion again
  [[ $READLINE -eq 1 ]] || return 0
  if [[ -n $1 ]]; then
    bind "\"\\t\": \"$1\"" 2>/dev/null || :
  else
    bind '"\t": complete' 2>/dev/null || :
  fi
  return 0
}
ask_raw() {  # $1 = prompt text (printed without newline)
  # ONE place owns the 2-space prompt indent and the body-text colour — call
  # sites pass bare text (which may carry its own [option] colours inside).
  #
  # What the user TYPES is bright yellow. On a tty the colour is opened before
  # the read so the terminal's own echo wears it, and closed after (the RESET
  # lands at the head of the next line, where it is invisible). Under scripted
  # input there is no echo, so the answer is printed here already dressed —
  # which is also what makes a scripted transcript byte-comparable to the
  # approved runthrough.
  #
  # With readline (see init_input) the SAME painted string is handed over as
  # readline's own prompt instead of being printed here: readline has to own
  # the prompt to know where the answer starts. One visible consequence —
  # readline writes it to stderr, as bash does for `read -p` and for PS1 — so a
  # run whose STDOUT is redirected keeps showing its prompts on the terminal.
  local ok=1 p
  if [[ $READLINE -eq 1 ]]; then
    p=$(rl_prompt "  $ASK_LEAD$C_TEXT$1$C_IN")
    # TAB is per-prompt: the default answer where there is one, filename completion
    # everywhere else. ⭐ THE FIRST CALL IS THE LOAD-BEARING ONE — every prompt SETS its
    # own binding before reading, which is what stops a path prompt after a [Y/n] from
    # inheriting a stray "y" macro. The trailing restore is belt-and-braces for a future
    # caller that reaches readline without coming through here; today nothing does.
    # (Measured, not assumed: removing the trailing restore changes no test, removing
    # the leading one fails four — g1lab/pty.sh.)
    ask_tab_bind "$ASK_TAB"
    IFS= read -e -r -p "$p" ANS <&"$ASK_FD" || ok=0
    ask_tab_bind ""
  else
    printf '  %s%s%s' "$ASK_LEAD" "$C_TEXT" "$1"
    [[ $SCRIPTED -eq 1 ]] || printf '%s' "$C_IN"
    IFS= read -r ANS <&"$ASK_FD" || ok=0
  fi
  if [[ $ok -eq 0 ]]; then
    printf '%s\n' "$RESET"
    die "prompt input exhausted"
  fi
  if [[ $SCRIPTED -eq 1 ]]; then
    if [[ -n $ANS ]]; then printf '%s%s%s\n' "$C_IN" "$ANS" "$RESET"
    else printf '%s\n' "$RESET"; fi
  else
    printf '%s' "$RESET"
  fi
  if [[ $QUIT_ARMED -eq 1 && ${ANS,,} =~ ^[[:space:]]*quit[[:space:]]*$ ]]; then
    quit_now
  fi
  return 0
}

ANS_YN=0
ask_yn() {  # question default(Y|N)  → ANS_YN=1/0   (renders "... [Y/n]? ")
  local q=$1 def=$2 h
  h=$(hint_yn "$def")
  ASK_TAB=${def,,}      # TAB fills the default: y or n
  while :; do
    ask_raw "$q $h? "
    case "$ANS" in
      "") [[ $def == Y ]] && ANS_YN=1 || ANS_YN=0; ASK_TAB=""; return 0 ;;
      y|Y) ANS_YN=1; ASK_TAB=""; return 0 ;;
      n|N) ANS_YN=0; ASK_TAB=""; return 0 ;;
    esac
  done
}

# The same question with a CAUTION SIGN and a clause in front of it: the sign
# (unpainted — it brings its own colour), then the reason the question is being
# asked in the preflight note's yellow, then the question itself in body text.
# The clause rides in ASK_LEAD rather than in the question string because
# ask_raw opens its line in body text, and both the sign and the clause have to
# be printed before that colour is set. The separating space belongs to the
# QUESTION for the same reason (it is body text in the mock, not clause yellow).
ask_yn_caution() {  # clause question default(Y|N) → ANS_YN
  ASK_LEAD="$MK_CAUT $C_NOTB$1"
  ask_yn " $2" "$3"
  ASK_LEAD=""
  return 0
}

# The INLINE three-way cluster "[y]es, [N]o, or [c]ase-by-case". It is written
# out as prose rather than squeezed into a "[y/n/c]" hint because the middle
# option needs a name a reader can act on, and it wears OPTION-LIST colours
# (Jei's mockup comment): the current default green with its letter capitalised,
# the other two blue — exactly what opt_row does one row at a time.
YNC_WORDS="y:es n:o c:ase-by-case"
opt_inline() {   # default(y|n|c) → the painted cluster
  local def=$1 pair ltr rest brk txt out="" i=0
  for pair in $YNC_WORDS; do
    ltr=${pair%%:*} rest=${pair#*:}
    if [[ $ltr == "$def" ]]; then brk=$C_BRK txt=$C_OPTD ltr=${ltr^^}
    else brk=$C_TBRK txt=$C_OPTN; fi
    case "$i" in
      0) : ;;
      1) out+="$C_TEXT, " ;;
      *) out+="$C_TEXT, or " ;;
    esac
    out+="${brk}[$txt$ltr$brk]$txt$rest"
    i=$((i + 1))
  done
  printf '%s%s' "$out" "$C_TEXT"
}

# The three-way question itself. Answers: a bare letter, the whole word, or
# empty for the default. ANS_3 is always one of y|n|c.
ANS_3=""
ask_ync() {  # "label" default(y|n|c) → ANS_3
  local q=$1 def=$2
  ASK_TAB=$def          # TAB fills the default: y, n or c
  while :; do
    ask_raw "$q: $(opt_inline "$def")? "
    [[ -z $ANS ]] && ANS=$def
    case "${ANS,,}" in
      y|yes)              ANS_3=y; ASK_TAB=""; return 0 ;;
      n|no)               ANS_3=n; ASK_TAB=""; return 0 ;;
      c|case|case-by-case) ANS_3=c; ASK_TAB=""; return 0 ;;
    esac
  done
}

ANS_CH=""
ask_choice() {  # prompt letters(first=default, shown capital) → ANS_CH (lower)
  local q=$1 letters=$2 def=${2:0:1} c
  ASK_TAB=${def,,}      # TAB fills the default: the capitalised letter in the cluster
  # Paint a trailing "[a/b/C]" cluster per option (the cluster is part of the
  # caller's prompt text, in DISPLAY order, so it is re-wrapped here).
  if [[ $q =~ ^(.*)\[([^][]*)\]$ ]]; then
    q="${BASH_REMATCH[1]}$(hint "${BASH_REMATCH[2]}" "$def")"
  fi
  while :; do
    ask_raw "$q: "
    [[ -z $ANS ]] && ANS=$def
    c=${ANS,,}
    if [[ ${#c} -eq 1 && ${letters,,} == *"$c"* ]]; then
      ANS_CH=$c
      ASK_TAB=""
      return 0
    fi
  done
}

# The caller supplies the FULL prompt label; we append the "[default]: " suffix.
# The old "-> /absolute/path" echo under the answer is gone (Jei s32): the path
# is repeated in the summary box, and the echo doubled every prompt.
#
# ONE FORM, SHOWN AS WRITTEN. The default is printed exactly as it is held —
# there is no display conversion left to do, because nothing on the way in
# rewrote the user's spelling (abs_path only settles what a relative answer
# means). A default that says ~/models says ~/models; one that says
# /srv/models says /srv/models; and a factory default is the installer's own
# construction, spelled ~ because that is how the installer would write it.
ANS_PATH=""
ask_path_as_raw() {  # "prompt label" default → ANS_PATH (absolute-or-~; NOT created)
  local label=$1 def=$2
  ask_raw "$label $(dflt "$def"): "
  [[ -z $ANS ]] && ANS=$def
  ANS_PATH=$(abs_path "$ANS")
  return 0
}

# No silent mkdir, ever: an existing dir is accepted as-is; a missing one is
# confirmed first. The confirmation can be answered ONCE for the whole run —
# immediately after the FIRST create, "Do this for all new paths?" turns every
# later missing directory into a silent mkdir.
CREATE_ALL=0
CREATE_ASKED=0
# The DISCLOSURE the confirmation makes is the stored spelling itself, and it
# needs no exception: a relative answer was already absolutized on the way in
# (that is the one class of answer whose spelling would have hidden where it
# lands), and every other answer is shown back the way it was written.
ensure_dir() {   # path → 0 when it exists (or was created), 1 otherwise
  local p=$1 yn real
  real=$(fs_path "$p")
  [[ -d $real ]] && return 0
  if [[ $CREATE_ALL -eq 1 ]]; then
    mkdir -p "$real" 2>/dev/null && return 0
    warn "could not create $p"
    return 1
  fi
  ask_yn "Create $p" Y
  yn=$ANS_YN
  # Offered once, and only after a YES: "do this for all" is meaningless as a
  # follow-up to a refusal (the path is about to be re-asked).
  if [[ $CREATE_ASKED -eq 0 && $yn -eq 1 ]]; then
    CREATE_ASKED=1
    ask_yn "Do this for all new paths" Y
    [[ $ANS_YN -eq 1 ]] && CREATE_ALL=1
  fi
  if [[ $yn -eq 1 ]]; then
    mkdir -p "$real" 2>/dev/null && return 0
    warn "could not create $p $EMD pick another location"
  fi
  return 1
}

ask_path_as() {  # "prompt label" default → ANS_PATH (existing dir, or confirm-create, else re-ask)
  while :; do
    ask_path_as_raw "$1" "$2"
    ensure_dir "$ANS_PATH" && return 0
  done
}

# The OPTIONAL twin of ask_path_as (s38): the default is the WORD "None", not a
# path, so an empty answer leaves the bind switched off and anything else is a
# path, confirmed/created exactly like a required one. It replaces the old
# "bind X? [y/N]" toggle plus its follow-up path prompt — one prompt, one
# answer. The literal word is matched BEFORE abs_path, which would otherwise
# turn a typed "None" into a directory called $HOME/None.
ANS_OPT_PATH=""
ask_path_or_none() {  # "prompt label" default("" = none) → ANS_OPT_PATH ("" = none)
  # $2 twice on purpose: bash expands the whole line before any of these
  # assignments happen, so ${def:-None} here would always read the word.
  local label=$1 def=$2 shown=${2:-None}
  while :; do
    ask_raw "$label $(dflt "$shown"): "
    [[ -z $ANS ]] && ANS=${def:-none}
    if [[ ${ANS,,} == none ]]; then
      ANS_OPT_PATH=""
      return 0
    fi
    ANS_PATH=$(abs_path "$ANS")
    if ensure_dir "$ANS_PATH"; then
      ANS_OPT_PATH=$ANS_PATH
      return 0
    fi
  done
}

