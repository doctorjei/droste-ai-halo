#!/usr/bin/env bash
# droste-setup.sh — interactive host-side installer for the droste *-halo AI boxes
# (gfx1151 / Strix Halo images: comfyui, llama, vllm, ds4, finetuning).
#
# ONE self-contained script, zero repo-checkout dependencies — safe to run as
#   curl <url> | bash            (all prompts read from /dev/tty)
#   curl <url> | bash -s -- comfyui llama     (argv = direct-to-box shortcut)
#
# ONE CONTAINER PER BOX, TWO DOORS (the merged shape): `distrobox assemble`
# creates `droste-<box>-halo`; `distrobox enter` is the interactive door and
# `podman start` is the server door (the init hook reads server.env from the
# box's data dir and launches the service on its configured port). There is no
# separate server container and no compose file any more.
#
# It guides every bind in the mount contract, host ports, whether each box
# serves at box start / at host boot, and overlay-hostile-filesystem
# mitigation; then it EMITS per-box recreation records into an emit dir
# (default ~/droste/):
#   <box>-halo.ini                   (distrobox assemble record — the ONE
#                                     container definition, healthcheck flags
#                                     and all)
#   <data dir>/server.env            (the serve config the box reads at every
#                                     start: SERVE=1/0 + PORT=<host port>)
#   NOTES.md                         (full guide with YOUR real paths baked in)
# and optionally pulls images / creates boxes / starts servers (build ladder).
# Boxes asked to start at HOST BOOT also get a systemd user unit
# (~/.config/systemd/user/droste-<box>.service) doing `podman start`.
#
# Re-runs are safe: existing definition files are detected and listed, and you
# choose keep / modify / recreate for them — SETTINGS FILES are never silently
# clobbered. (Containers are the build ladder's business: its create rung
# always replaces the container it is about to build.)
#
# "quit" at any prompt exits cleanly; "./quit" if you really do mean the path.
#
# Test hooks (deliberately undocumented in --help):
#   DROSTE_SETUP_INPUT=<file>   read all prompt answers from <file> (one per
#                               line) instead of /dev/tty.
#   DROSTE_SETUP_FSTYPE=<type>  force the filesystem probe result for every
#                               data dir (e.g. ecryptfs) — exercises the
#                               overlay-mitigation path without such a mount.
set -euo pipefail

# ── Static per-box contract table ────────────────────────────────────────────
# CANONICAL SOURCE: targets/<box>/build-spec and targets/<box>/distrobox.ini in
# github.com/doctorjei/droste-ai-halo. This is a hand-synced snapshot so the
# installer works with no repo checkout and before any image is pulled; on any
# drift, the build-specs win. Keep in sync (reviewed against d823b8b).

BOXES=(comfyui llama vllm ds4 finetuning)

declare -A BOX_PITCH=(
  [comfyui]="ComfyUI web UI — image/video generation"
  [llama]="llama.cpp server — GGUF LLMs (turboquant fork)"
  [vllm]="vLLM — OpenAI-compatible LLM server"
  [ds4]="DwarfStar 4 server + cockpit — huge DeepSeek MoE quants"
  [finetuning]="JupyterLab — unsloth/HF finetuning"
)

# All-ASCII per-box banner titles (drawn in a box by banner()) + short display
# names (used wherever a prompt needs the box's proper name).
declare -A BOX_BANNER=(
  [comfyui]="ComfyUI Container(s) - Image/Video Generation"
  [llama]="llama.cpp Container(s) - GGUF LLM Server"
  [vllm]="vLLM Container(s) - OpenAI-Compatible LLM Server"
  [ds4]="DwarfStar 4 Container(s) - DeepSeek MoE Quants"
  [finetuning]="Finetuning Container(s) - unsloth/HF Training"
)
declare -A BOX_NAME=(
  [comfyui]="ComfyUI" [llama]="llama.cpp" [vllm]="vLLM" [ds4]="DwarfStar 4" [finetuning]="Finetuning"
)

# Human-readable titles for each prompted bind family (used in the path prompt).
declare -A BIND_TITLE=(
  [data]="Program Data" [input]="Input Files" [output]="Output Files" [workspace]="Workspace"
)

# Summary-box row headers for the same families (shorter — the box is narrow).
declare -A BIND_ROW=(
  [data]="Data Path" [input]="Input" [output]="Output" [workspace]="Workspace"
)

# Default HOST-side port offered at the prompt. In the merged shape there is no
# publish/remap to be had (distrobox containers use HOST networking), so this is
# the port the service BINDS: droste-setup.sh writes it into server.env and the
# init hook passes it to the service. ds4's upstream default is 8000, same as
# vllm, so its default is nudged to 8001 to keep both runnable side by side.
declare -A BOX_HOST_PORT=(
  [comfyui]=8188 [llama]=8080 [vllm]=8000 [ds4]=8001 [finetuning]=8888
)

# Box-selection table columns: service name + one-line description.
declare -A BOX_SERVICE=(
  [comfyui]="ComfyUI" [llama]="llama.cpp" [vllm]="vLLM"
  [ds4]="DwarfStar 4" [finetuning]="JupyterLab"
)
declare -A BOX_DESC=(
  [comfyui]="image/video generation (web)"
  [llama]="GGUF LLMs (turboquant fork)"
  [vllm]="OpenAI-compatible LLM server"
  [ds4]="DS4 server+cockpit; DS MoE quants"
  [finetuning]="unsloth/HF finetuning"
)

# Extra CRITICAL binds beyond /opt/data + the shared HF cache (CRITICAL rows):
# space-separated "label:container-dest". These hold irreplaceable user work.
# ORDER IS DISPLAY ORDER: it drives both the path prompts and the summary box
# rows, so comfyui lists output before input (Jei's mockup, both places).
declare -A BOX_EXTRA_BINDS=(
  [comfyui]="output:/opt/ComfyUI/output input:/opt/ComfyUI/input"
  [llama]=""
  [vllm]=""
  [ds4]=""
  [finetuning]="workspace:/opt/workspace"
)

# OPTIONAL /opt/models bind point (OPTIONAL row; finetuning has none).
declare -A BOX_HAS_MODELS=(
  [comfyui]=1 [llama]=1 [vllm]=1 [ds4]=1 [finetuning]=0
)

# Config file seeded (if missing) onto /opt/data at first start.
declare -A BOX_CONFIG=(
  [comfyui]="extra_model_paths.yaml"
  [llama]="llama.env"
  [vllm]="vllm_config.yaml"
  [ds4]="ds4.env"
  [finetuning]=""
)

# One-line explanations for the prompted bind families (what lives there).
# Reference only since the per-bind headers were dropped — kept as the record of
# what each prompted bind actually holds.
# shellcheck disable=SC2034
declare -A BIND_DESC=(
  [data]="venv overlay upper, caches, seeded config"
  [input]="source files you feed ComfyUI"
  [output]="generated images/videos"
  [workspace]="notebooks + trained adapters - your work"
)

# The ONE pre-first-use action (dashboard Notes column; @DATA@ substituted).
declare -A BOX_NOTE=(
  [comfyui]=""
  [llama]="Model: @DATA@/llama.env"
  [vllm]="Model: @DATA@/vllm_config.yaml"
  [ds4]="Model: @DATA@/ds4.env"
  [finetuning]="Token: podman logs droste-finetuning-halo"
)

IMAGE_PREFIX="ghcr.io/doctorjei/droste-"   # + <box> + "-halo:" + tag
IMAGE_SUFFIX="-halo:latest"
# ONE container per box, named exactly like the image stem: droste-<box>-halo.
# (The old -server / -box lane suffixes are gone with the lanes; see box_ctr().)
INIT_HOOK="/opt/resources/resolve/droste-init-hook.sh"

# ── Healthcheck contract (P1's droste-healthcheck.sh, baked in every image) ───
# droste-setup.sh wires podman's healthcheck at CREATE time (the images carry no
# HEALTHCHECK of their own): the probe reads the box's server.env for the port
# and the build-spec for the endpoint, and answers HEALTHY for a box that is not
# configured to serve — so these flags are unconditional, interactive-only boxes
# included. With --health-on-failure=restart a failing probe restarts the
# container, which re-runs the init line and therefore relaunches the service.
HEALTH_CMD="/opt/resources/resolve/droste-healthcheck.sh"
HEALTH_INTERVAL="30s"
HEALTH_RETRIES=3
# ⚠️ START PERIOD IS THE LOAD-BEARING NUMBER (P1 finding). Failures inside it do
# not count, so it must comfortably cover the box's WORST first-start: these
# services answer nothing (llama actively 503s on /health) until multi-GB
# weights are read off disk. Too short + on-failure=restart = a restart loop
# that never finishes loading, so every value below is deliberately generous —
# the only cost of erring long is a later first detection of a real failure.
#   comfyui     torch import + model-tree rescan of the whole HF cache
#   llama       GGUF load, 503s throughout
#   vllm        weight load + torch.compile / graph capture on first run
#   ds4         80-430 GB of MoE quants off disk
#   finetuning  jupyter is up in seconds; keep a margin for the resolver
declare -A BOX_HEALTH_START=(
  [comfyui]=10m [llama]=30m [vllm]=45m [ds4]=90m [finetuning]=5m
)
# Graceful stop: distrobox-init does NOT forward SIGTERM to the served process
# (P1 finding 4), so on `podman stop` the service is killed rather than asked to
# exit. distrobox-init itself answers SIGTERM promptly (0.32 s measured), so a
# roomier timeout costs nothing in practice and leaves the door open for a
# future signal-forwarding shim. NOTES.md states the consequence plainly.
STOP_TIMEOUT=20

# ── Copy-mode size + fuse speed constants ────────────────────────────────────
# Rough size of the baked content copy-mode would duplicate onto /opt/data
# (mostly the venv; torch-stack boxes are multi-GB, llama/ds4 are compiled
# binaries with a small venv). TODO(Jei-tune): replace with measured numbers
# from `podman image inspect` / du on a real host; same for the fuse ballpark.
# Reference only since Data Mapping became a WHOLE-INSTALL decision (it is asked
# once, for the most primary path, and applied to the rest), so its copy-mode row
# quotes the install-wide range rather than one box's share.
# shellcheck disable=SC2034
declare -A BOX_COPY_GB=(
  [comfyui]=14 [llama]=1 [vllm]=15 [ds4]=1 [finetuning]=16
)
FUSE_SPEED_NOTE="~30% on app files; models unaffected"  # TODO(Jei-tune)

# Filesystems kernel overlayfs rejects as an upper (the ecryptfs lesson).
overlay_hostile_fs() {
  case "$1" in
    ecryptfs|nfs*|virtiofs|fuse*|vfat|exfat|msdos|cifs|smb*|9p|overlay)
      return 0 ;;
    *) return 1 ;;
  esac
}

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: droste-setup.sh [OPTIONS] [BOX ...]

Interactive setup for the droste *-halo AI boxes (Strix Halo / gfx1151).
ONE container per box (droste-<box>-halo), entered with distrobox and
served with podman. Guides binds, ports, serve-at-box-start and
serve-at-host-boot, and filesystem gotchas; writes per-box recreation
records (<box>-halo.ini + server.env) plus a NOTES.md, and can pull
images, create boxes, and start servers.

BOX      comfyui llama vllm ds4 finetuning   (default: interactive menu)

Options:
  --plain    ASCII output (no emoji / ANSI) — auto-detected on dumb terminals
  -h, --help show this help

Safe to re-run: existing setups are detected and never clobbered.
EOF
}

# ── Output / display helpers ─────────────────────────────────────────────────
PLAIN=0
ARG_BOXES=()
for arg in "$@"; do
  case "$arg" in
    --plain) PLAIN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'droste-setup.sh: unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    *) ARG_BOXES+=("$arg") ;;
  esac
done
case "${TERM:-dumb}" in dumb|unknown) PLAIN=1 ;; esac
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]*8*|*[Uu][Tt][Ff]*) : ;;
  *) PLAIN=1 ;;
esac

if [[ $PLAIN -eq 1 ]]; then
  RESET="" DIVCH="-"
  # Foreground-only palette (see the rework spec). EVERY color rides on one of
  # these variables so --plain / dumb terminals stay byte-for-byte colorless.
  C_FRAME="" C_TITLE="" C_BTITLE="" C_LABEL="" C_LABEL2="" C_SUB="" C_SUB2="" C_TEXT=""
  C_BRK="" C_OKB="" C_OK="" C_OKT="" C_BADB="" C_BAD=""
  C_TBRK="" C_TIDX="" C_ARROW="" C_SUBJ=""
  C_HDR="" C_SVC="" C_PORT="" C_GLYPH="" C_STAR=""
  C_EXE="" C_CMD="" C_TGT="" C_PH=""
  C_EXH="" C_FILE="" C_ERR="" C_STOPW="" C_STOPT=""
  C_PBRK="" C_PDEF="" C_PALT="" C_IN=""
  C_OPTD="" C_OPTN="" C_CTR="" C_SVCN=""
  C_SBOX="" C_SBUL="" C_SHDR="" C_SVAL="" C_SGRP="" C_MOPT="" C_MCAT=""
  C_QTXT="" C_QEXIT="" C_QKEY="" C_DETH="" C_DETN="" C_SELP=""
  C_PATHB="" C_PATHG=""
  # Repaint plumbing for the pull progress bar. Empty here on purpose: --plain
  # (and any dumb terminal) gets ONE static status line per image instead, so
  # the section stays byte-for-byte free of control sequences.
  CR="" EL="" BAR_F="#" BAR_E="-"
  # Dashboard state cell — ONE glyph triplet serves all three of On/BoxSv/HostSv.
  # The ASCII glyph already carries its own brackets, so the Legend adds none
  # (GB_L/GB_R empty). Jei's rev-2 spelling is [Y]/[N]/[?] (it supersedes the
  # earlier [+]/[-]/[?], and only here — no other ASCII fallback changed).
  GS_YES="[Y]" GS_NO="[N]" GS_NA="[?]" W_STATE=3 GB_L="" GB_R=""
  BULLET="-" ARROW_G=" ---> " ARROW_M="-->"
  BOXTL="." BOXTR="." BOXBL="'" BOXBR="'" BOXH="-" BOXV="|"
  # The two banner weights collapse onto the same ASCII drawing in --plain.
  BANTL="." BANTR="." BANBL="'" BANBR="'" BANH="-" BANV="|"
  BANTL2="." BANTR2="." BANBL2="'" BANBR2="'" BANH2="-" BANV2="|"
else
  RESET=$'\e[0m' DIVCH="─"
  C_FRAME=$'\e[0;94m'   # box-drawing frames + section rules
  C_TITLE=$'\e[1;96m'   # installer title (top banner only)
  C_BTITLE=$'\e[0;96m'  # per-box banner title
  C_LABEL=$'\e[0;97m'   # section label inside the rule
  C_LABEL2=$'\e[1;97m'  # section label, intro variant (Preflight, Resource Path)
  C_SUB=$'\e[4;97m'     # underlined subtitle / table header
  C_SUB2=$'\e[4;37m'    # underlined subtitle, intro variant (Resource Path)
  C_TEXT=$'\e[0;37m'    # body + prompt text
  C_BRK=$'\e[0;32m'     # option-list brackets, default row
  C_OKB=$'\e[0;32m' C_OK=$'\e[0;92m' C_OKT=$'\e[0;36m'    # preflight ok row
  C_BADB=$'\e[0;31m' C_BAD=$'\e[0;91m'                    # preflight [!!] row
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
  # reader has to TYPE. Its own entry rather than a borrowed one: C_BAD is
  # 0;91 (not bold), and C_ERR/C_ARROW mean "this failed" / "aside follows"
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
  BOXTL="┌" BOXTR="┐" BOXBL="└" BOXBR="┘" BOXH="─" BOXV="│"
  # Banners come in two weights: DOUBLE for the one installer title, HEAVY for
  # the per-box titles. The light set above is the summary box's.
  BANTL="╔" BANTR="╗" BANBL="╚" BANBR="╝" BANH="═" BANV="║"
  BANTL2="┏" BANTR2="┓" BANBL2="┗" BANBR2="┛" BANH2="━" BANV2="┃"
fi

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" | fold -s -w "$(disp_width)"; }
die()  { printf 'droste-setup.sh: %s\n' "$*" >&2; exit 1; }
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

# Preflight rows: cyan [ok] / red [!!]. Preflight never blocks, so a problem is
# reported here rather than through warn().
pf_ok()  { printf '  %s[%s%s%s]%s %s%s\n' "$C_OKB" "$C_OK" "ok" "$C_OKB" "$C_OKT" "$1" "$RESET"; }
pf_bad() { printf '  %s[%s%s%s]%s %s%s\n' "$C_BADB" "$C_BAD" "!!" "$C_BADB" "$C_BADB" "$1" "$RESET"; }

# A titled box drawn with the banner glyphs (ASCII in --plain mode).
# banner text [bold]  — titles are all-ASCII so byte length == display width.
# Two weights: the ONE installer title is DOUBLE-ruled, each per-box title HEAVY.
BANNER_W=0                       # outer width of the last banner drawn
banner() {   # text [bold]
  local text=$1 bold=${2:-} n i fill top mid bot tcol
  local tl=$BANTL tr=$BANTR bl=$BANBL br=$BANBR h=$BANH v=$BANV
  n=$(( ${#text} + 2 ))          # text plus one space of padding each side
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
  mid="$v $tcol$text$C_FRAME $v"
  printf '\n'
  # Wrap each line separately so it renders even when RESET is empty (--plain).
  printf '  %s%s%s\n' "$C_FRAME" "$top" "$RESET"
  printf '  %s%s%s\n' "$C_FRAME" "$mid" "$RESET"
  printf '  %s%s%s\n' "$C_FRAME" "$bot" "$RESET"
}

# Jei's coloured droste mark, the same art the in-box toolbox banners draw
# (droste-ai-halo commit 198f3f9), re-indented to sit above the installer title.
# It is ANSI + private-use box glyphs by construction, so --plain skips it.
logo_header() {
  [[ $PLAIN -eq 1 ]] && return 0
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

home_disp() {  # compress $HOME → ~ for display
  local p=$1
  if [[ $p == "$HOME" ]]; then printf '~'
  elif [[ $p == "$HOME"/* ]]; then printf '~%s' "${p#"$HOME"}"
  else printf '%s' "$p"; fi
}

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

expand_path() {  # ~ expansion + absolutize + normalize (realpath -m style)
  local p=$1
  # shellcheck disable=SC2088  # matching a LITERAL leading ~ is the point
  case "$p" in
    "~") p=$HOME ;;
    "~/"*) p=$HOME/${p#\~/} ;;
    /*) : ;;
    *) p=$PWD/$p ;;
  esac
  # Collapse ., .., //  without requiring the path to exist.
  p=$(realpath -m -- "$p" 2>/dev/null) || :
  printf '%s' "$p"
}

# ── Prompt plumbing (curl|bash-safe: /dev/tty, or the scripted-input hook) ───
ASK_FD=""
SCRIPTED=0
init_input() {
  if [[ -n "${DROSTE_SETUP_INPUT:-}" ]]; then
    [[ -r "$DROSTE_SETUP_INPUT" ]] || die "cannot read DROSTE_SETUP_INPUT=$DROSTE_SETUP_INPUT"
    exec {ASK_FD}<"$DROSTE_SETUP_INPUT"
    SCRIPTED=1
  else
    if ! exec {ASK_FD}</dev/tty; then
      die "no controlling terminal for prompts (this installer is interactive)"
    fi
  fi
}

# QUIT ANYWHERE. Every prompt in the installer goes through ask_raw, so ONE
# check here covers ask_yn / ask_choice / ask_path_as / ask_port / the box
# selection. It is armed by the notice printed after Preflight (nothing is
# prompted before that), and it matches the RAW answer only — a user who really
# does want a directory called "quit" writes "./quit", which expand_path
# resolves and this test never sees.
QUIT_ARMED=0
quit_now() {
  printf '\n  %sExiting droste-setup.sh — no further changes made.%s\n\n' \
    "$C_TEXT" "$RESET"
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
  printf '  %s%s' "$C_TEXT" "$1"
  [[ $SCRIPTED -eq 1 ]] || printf '%s' "$C_IN"
  if ! IFS= read -r ANS <&"$ASK_FD"; then
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
  while :; do
    ask_raw "$q $h? "
    case "$ANS" in
      "") [[ $def == Y ]] && ANS_YN=1 || ANS_YN=0; return 0 ;;
      y|Y) ANS_YN=1; return 0 ;;
      n|N) ANS_YN=0; return 0 ;;
    esac
  done
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
  while :; do
    ask_raw "$q: $(opt_inline "$def")? "
    [[ -z $ANS ]] && ANS=$def
    case "${ANS,,}" in
      y|yes)              ANS_3=y; return 0 ;;
      n|no)               ANS_3=n; return 0 ;;
      c|case|case-by-case) ANS_3=c; return 0 ;;
    esac
  done
}

ANS_CH=""
ask_choice() {  # prompt letters(first=default, shown capital) → ANS_CH (lower)
  local q=$1 letters=$2 def=${2:0:1} c
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
      return 0
    fi
  done
}

# The caller supplies the FULL prompt label; we append the "[default]: " suffix.
# The old "-> /absolute/path" echo under the answer is gone (Jei s32): the path
# is repeated in the summary box, and the echo doubled every prompt.
ANS_PATH=""
ask_path_as_raw() {  # "prompt label" default → ANS_PATH (absolute; NOT created)
  local label=$1 def=$2
  ask_raw "$label $(dflt "$(home_disp "$def")"): "
  [[ -z $ANS ]] && ANS=$def
  ANS_PATH=$(expand_path "$ANS")
  return 0
}

# No silent mkdir, ever: an existing dir is accepted as-is; a missing one is
# confirmed first. The confirmation can be answered ONCE for the whole run —
# immediately after the FIRST create, "Do this for all new paths?" turns every
# later missing directory into a silent mkdir.
CREATE_ALL=0
CREATE_ASKED=0
ensure_dir() {   # path → 0 when it exists (or was created), 1 otherwise
  local p=$1 yn
  [[ -d $p ]] && return 0
  if [[ $CREATE_ALL -eq 1 ]]; then
    mkdir -p "$p" 2>/dev/null && return 0
    warn "could not create $p"
    return 1
  fi
  ask_yn "Create $(home_disp "$p")" Y
  yn=$ANS_YN
  # Offered once, and only after a YES: "do this for all" is meaningless as a
  # follow-up to a refusal (the path is about to be re-asked).
  if [[ $CREATE_ASKED -eq 0 && $yn -eq 1 ]]; then
    CREATE_ASKED=1
    ask_yn "Do this for all new paths" Y
    [[ $ANS_YN -eq 1 ]] && CREATE_ALL=1
  fi
  if [[ $yn -eq 1 ]]; then
    mkdir -p "$p" 2>/dev/null && return 0
    warn "could not create $p — pick another location"
  fi
  return 1
}

ask_path_as() {  # "prompt label" default → ANS_PATH (existing dir, or confirm-create, else re-ask)
  while :; do
    ask_path_as_raw "$1" "$2"
    ensure_dir "$ANS_PATH" && return 0
  done
}

ANS_PORT=""
ask_port() {  # box default → ANS_PORT
  local box=$1 def=$2 other
  while :; do
    ask_raw "Host port for ${BOX_NAME[$box]} $(dflt "$def"): "
    [[ -z $ANS ]] && ANS=$def
    if [[ ! $ANS =~ ^[0-9]+$ ]] || (( ANS < 1 || ANS > 65535 )); then
      say "  Please give a port number (1-65535)."
      continue
    fi
    other=""
    local b
    for b in "${BOXES[@]}"; do
      [[ $b == "$box" ]] && continue
      [[ "${CFG_PORT[$b]:-}" == "$ANS" ]] && other=$b
    done
    if [[ -n $other ]]; then
      subnote "Port $ANS is already assigned to $other — pick another."
      continue
    fi
    ANS_PORT=$ANS
    return 0
  done
}

# ── State ────────────────────────────────────────────────────────────────────
declare -A ACTION            # box → new|keep|recreate|modify
declare -A CFG_BOXSV         # box → 1|""  serve when the BOX starts (server.env)
declare -A CFG_HSTSV         # box → 1|""  start the box at HOST BOOT (user unit)
declare -A CFG_PORT          # box → host port the service binds
declare -A CFG_MODE          # box → ""|fuse|copy|ignore  (overlay mitigation)
declare -A CFG_FS            # box → probed fstype of the data dir
declare -A PATHS             # "box:label" → absolute host path
declare -A EX_INI EX_CTR     # detection (1/"" ; EX_CTR = container state)
declare -A EXD_PATH          # "box:label" → parsed host path from the old ini
declare -A EXD_PORT EXD_BOXSV EXD_HSTSV EXD_MODE   # parsed defaults
declare -A SESSION_STATE     # box → ACTIVE|STOPPED (what this run did)
SELECTED=()                  # chosen boxes, canonical order
CONFIGURE=()                 # SELECTED minus keeps (definitions (re)generated)
KEEP=()                      # kept boxes (untouched files; ladder still offered)
HF_CACHE=""
COMPUTE_CACHE=""             # shared MIOpen/Triton/torch/vLLM kernel cache
MODELS_DIR=""                # "" = not configured
EMIT_DIR=""
RUNG="w"                     # w|p|c|a

RUNTIME="" RUNTIME_BIN="" ROOTLESS=0 HAVE_DISTROBOX=0
LINGER=""                    # yes|no|"" (unknown) — user-manager lingering

# ── Preflight (warn, never block) ────────────────────────────────────────────
preflight() {
  section "Preflight" intro
  say ""
  if command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
    RUNTIME_BIN=$(command -v podman)
    [[ ${EUID:-$(id -u)} -ne 0 ]] && ROOTLESS=1
    pf_ok "podman found ($([[ $ROOTLESS -eq 1 ]] && echo rootless || echo rootful))"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME=docker
    RUNTIME_BIN=$(command -v docker)
    pf_ok "docker found (podman not present)"
  else
    pf_bad "neither podman nor docker found — definitions will still be written"
  fi
  if [[ -e /dev/kfd && -e /dev/dri ]]; then
    pf_ok "GPU devices present: /dev/kfd /dev/dri"
  else
    pf_bad "GPU devices missing (/dev/kfd, /dev/dri) — fine on a non-GPU host"
  fi
  # ONE list, used twice: the prose names the groups exactly as the usermod
  # argument spells them (bare commas), which is also what brings the row to 79
  # columns — the width the whole report is drawn to.
  local g missing=""
  for g in render video; do
    id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$g" || missing="$missing,$g"
  done
  missing=${missing#,}
  if [[ -n $missing ]]; then
    pf_bad "not in $missing (fix: sudo usermod -aG $missing \$USER; re-login)"
  else
    pf_ok "user is in the render + video groups"
  fi
  if [[ -e /dev/fuse ]]; then
    pf_ok "/dev/fuse present (fuse-overlayfs fallback option)"
  else
    pf_bad "/dev/fuse missing — fuse-overlayfs fallback unavailable"
  fi
  # The pull path is curl (POST to the podman REST API) piped into python3
  # (which aggregates the per-layer byte counts into one bar). Both are hard
  # dependencies of an image pull; neither is needed to write definitions.
  if command -v python3 >/dev/null 2>&1; then
    pf_ok "python3 found (image-pull progress)"
  else
    pf_bad "python3 not found — image pulls will fail (definitions still written)"
  fi
  if command -v curl >/dev/null 2>&1; then
    pf_ok "curl found (image-pull transport)"
  else
    pf_bad "curl not found — image pulls will fail (definitions still written)"
  fi
  # Lingering: a rootless user manager exits at logout unless the user lingers,
  # which would take BOTH the boot auto-start units and podman's own healthcheck
  # timers down with it. Reported here; offered for real (bare `loginctl
  # enable-linger`, no sudo — verified on hardware) only if a box actually asks
  # to start at host boot. See enable_linger().
  probe_linger
  case "$LINGER" in
    yes) pf_ok "user lingering enabled (boot auto-start + healthcheck timers)" ;;
    no)  pf_bad "user lingering off — needed to start boxes at host boot (offered later)" ;;
    *)   pf_bad "cannot read user lingering state (loginctl missing?)" ;;
  esac
  command -v distrobox >/dev/null 2>&1 && HAVE_DISTROBOX=1
  [[ $HAVE_DISTROBOX -eq 0 ]] && pf_bad "distrobox not found (it creates every box)"
  return 0
}

# `loginctl show-user -p Linger` without --value (systemd < 231 lacks it), and
# without failing the run when there is no loginctl / no session at all.
probe_linger() {
  local out
  LINGER=""
  command -v loginctl >/dev/null 2>&1 || return 0
  out=$(loginctl show-user "${USER:-$(id -un)}" -p Linger 2>/dev/null) || return 0
  case "${out#Linger=}" in
    yes) LINGER=yes ;;
    no)  LINGER=no ;;
  esac
  return 0
}

# ── Existing-setup detection + parsing (re-run safety) ───────────────────────
# ONE container per box, named exactly like the image stem. The FILE name drops
# the redundant "droste-" prefix (the emit dir is a user-facing directory), and
# the systemd user unit that starts the box at host boot drops the "-halo".
box_ctr()   { printf 'droste-%s-halo' "$1"; }
ini_file()  { printf '%s/%s-halo.ini' "$EMIT_DIR" "$1"; }
unit_name() { printf 'droste-%s.service' "$1"; }
unit_file() { printf '%s/.config/systemd/user/%s' "$HOME" "$(unit_name "$1")"; }
# The serve config the box reads at EVERY start (P1's droste-serve.sh), living
# on the box's data volume as /opt/data/server.env.
serve_env_file() {  # box → path ("" when the data dir is not known yet)
  local d=${PATHS["$1:data"]:-${EXD_PATH["$1:data"]:-}}
  [[ -n $d ]] && printf '%s/server.env' "$d"
}

dest_to_label() {  # box dest → label ("" if unknown)
  local box=$1 dest=$2 pair
  case "$dest" in
    /opt/data) printf 'data'; return 0 ;;
    /opt/models) printf 'models'; return 0 ;;
    /opt/caches) printf 'caches'; return 0 ;;
    */.cache/huggingface) printf 'hf'; return 0 ;;
  esac
  for pair in ${BOX_EXTRA_BINDS[$box]}; do
    if [[ ${pair#*:} == "$dest" ]]; then printf '%s' "${pair%%:*}"; return 0; fi
  done
  printf ''
}

parse_existing_ini() {  # box
  local box=$1 f line vols entry src dest label
  f=$(ini_file "$box")
  [[ -f $f ]] || return 0
  while IFS= read -r line; do
    if [[ $line =~ ^volume=\"(.*)\"$ ]]; then
      vols=${BASH_REMATCH[1]}
      for entry in $vols; do
        src=${entry%%:*}
        dest=${entry#*:}; dest=${dest%%:*}
        src=$(expand_path "$src")
        label=$(dest_to_label "$box" "$dest")
        [[ -n $label && -z "${EXD_PATH["$box:$label"]:-}" ]] \
          && EXD_PATH["$box:$label"]=$src
      done
    elif [[ $line =~ DROSTE_OVERLAY_MODE=([a-z]+) ]]; then
      # additional_flags carries --env DROSTE_OVERLAY_MODE=<mode>.
      EXD_MODE[$box]=${BASH_REMATCH[1]}
    elif [[ $line =~ ^#[[:space:]]*droste-setup:[[:space:]]*port=([0-9]+)[[:space:]]+box-start=([a-z]+)[[:space:]]+host-boot=([a-z]+) ]]; then
      # The record line emit_ini writes: what THIS installer last answered. It
      # is the fallback for the two live sources below (server.env + systemd),
      # which are what the user may have changed by hand since.
      EXD_PORT[$box]=${BASH_REMATCH[1]}
      [[ ${BASH_REMATCH[2]} == yes ]] && EXD_BOXSV[$box]=1
      [[ ${BASH_REMATCH[3]} == yes ]] && EXD_HSTSV[$box]=1
    fi
  done < "$f"
  return 0
}

# The LIVE serve state of a box: server.env (which the user may have edited with
# an editor — that is the whole point of the file) wins over the ini's record of
# what droste-setup.sh last wrote. Parsed the same defensive way P1's serve library
# parses it: shell-sourceable KEY=VALUE, anything unusable simply ignored.
parse_serve_env() {  # box
  local box=$1 f line k v
  f=$(serve_env_file "$box") || return 0
  [[ -n $f && -f $f && -r $f ]] || return 0
  while IFS= read -r line; do
    line=${line%%#*}
    [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$ ]] || continue
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
    case "$k" in
      SERVE)
        case "${v,,}" in
          1|true|yes|on) EXD_BOXSV[$box]=1 ;;
          *)             EXD_BOXSV[$box]="" ;;
        esac ;;
      PORT)
        [[ $v =~ ^[0-9]+$ ]] && EXD_PORT[$box]=$v ;;
    esac
  done < "$f"
  return 0
}

# Host-boot state comes from systemd itself, not from a file we wrote: the user
# may have disabled the unit by hand. `is-enabled` exits non-zero for disabled
# AND for "no such unit", which are the same answer to us.
parse_host_unit() {  # box
  local box=$1
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl --user is-enabled "$(unit_name "$box")" >/dev/null 2>&1; then
    EXD_HSTSV[$box]=1
  elif [[ ! -f $(unit_file "$box") ]]; then
    EXD_HSTSV[$box]=""
  fi
  return 0
}

detect_existing() {
  local box state
  for box in "${BOXES[@]}"; do
    [[ -f $(ini_file "$box") ]] && EX_INI[$box]=1
    if [[ -n $RUNTIME ]]; then
      state=$("$RUNTIME" ps -a --filter "name=^$(box_ctr "$box")\$" \
              --format '{{.State}}' 2>/dev/null | head -n1) || state=""
      [[ -n $state ]] && EX_CTR[$box]=$state
    fi
    # ini FIRST: it is what says where the data dir (hence server.env) is.
    parse_existing_ini "$box"
    parse_serve_env "$box"
    parse_host_unit "$box"
  done
  return 0
}

# The conditional block under the resource-path answer: which definition files
# the just-named resource path already holds. Printed BEFORE the box table
# because it is the reason a re-runner is about to pick a subset.
detected_block() {
  local box
  local -a ini=()
  for box in "${BOXES[@]}"; do
    [[ -n "${EX_INI[$box]:-}" ]] && ini+=("$box")
  done
  [[ ${#ini[@]} -eq 0 ]] && return 0
  say ""
  # ONE list now: one container per box means one settings file per box, so the
  # old two-lane listing (ini + yaml) has nothing left to distinguish.
  printf '  %s%s%s %s%s%s\n' "$C_ARROW" "$ARROW_M" "$RESET" \
    "$C_DETH" "Previous box setup configurations detected:" "$RESET"
  printf '  %sBox settings (ini):  %s\n' "$C_TEXT" "$(name_list "$C_DETN" "${ini[@]}")"
  say ""
  printf '  %s%s%s\n' "$C_SELP" \
    "Select the boxes you wish to edit, modify, or rebuild." "$RESET"
  return 0
}

# ── Box selection ────────────────────────────────────────────────────────────
# The answer is parsed ROBUSTLY: anything that is not an ASCII letter or digit
# is a separator, so "1,2 3", "comfyui/llama" and "[1] [2]" all work. Tokens we
# cannot place are named back rather than silently dropped, and the prompt
# repeats.
select_boxes() {
  local box tok idx pick clean bad dw
  declare -A want=()
  if [[ ${#ARG_BOXES[@]} -gt 0 ]]; then
    for tok in "${ARG_BOXES[@]}"; do
      [[ -n "${BOX_HOST_PORT[$tok]:-}" ]] || die "unknown box: $tok"
      want[$tok]=1
    done
  else
    say ""
    # Columns land at 2 / 8 / 21 / 34 / 69. Each column carries its own colour
    # THROUGH its padding, so the row reads as four coloured fields, and the
    # [All] row wears the whole default-option scheme of an option list.
    # DESCRIPTION IS THE ELASTIC COLUMN: it is the only prose here, so a narrow
    # terminal takes its width out of that cell (clipped, not wrapped) and every
    # other column keeps its place. It never grows past its drawn 35.
    dw=$(( $(disp_width) - 39 ))
    [[ $dw -gt 35 ]] && dw=35
    [[ $dw -lt 8 ]] && dw=8
    printf '  %s %-5s%-13s%-13s%-*s%-5s%s\n' \
      "$C_SUB" "#" "Container" "Service" "$dw" "Description" "Port" "$RESET"
    idx=1
    for box in "${BOXES[@]}"; do
      printf '  %s[%s%d%s]%s   %s%-13s%s%-13s%s%-*s%s%s%s\n' \
        "$C_TBRK" "$C_TIDX" "$idx" "$C_TBRK" "$RESET" \
        "$C_CTR" "$box" "$C_SVCN" "${BOX_SERVICE[$box]}" \
        "$C_TEXT" "$dw" "$(clip "${BOX_DESC[$box]}" "$dw")" \
        "$C_PORT" "${BOX_HOST_PORT[$box]}" "$RESET"
      idx=$((idx+1))
    done
    printf '  %s[%s%s%s]%s%s%s\n' \
      "$C_BRK" "$C_OPTD" "All" "$C_BRK" "$C_OPTD" " All boxes" "$RESET"
    say ""
    while :; do
      ask_raw "Select boxes - names or numbers, space-separated $(dflt All): "
      [[ -z $ANS ]] && ANS=All
      want=()
      bad=""
      # Separators first, then one token per word.
      clean=${ANS//[!a-zA-Z0-9]/ }
      for tok in $clean; do
        case "${tok,,}" in
          all|6) for box in "${BOXES[@]}"; do want[$box]=1; done ;;
          [1-5]) pick=${BOXES[$((tok-1))]}; want[$pick]=1 ;;
          *) if [[ -n "${BOX_HOST_PORT[${tok,,}]:-}" ]]; then want[${tok,,}]=1
             else bad="$bad $tok"; fi ;;
        esac
      done
      if [[ -n $bad ]]; then
        subnote "Unrecognized:$bad — use the names or numbers above."
        continue
      fi
      [[ ${#want[@]} -gt 0 ]] && break
    done
  fi
  SELECTED=()
  for box in "${BOXES[@]}"; do
    [[ -n "${want[$box]:-}" ]] && SELECTED+=("$box")
  done
  return 0
}

# ── Existing Settings (K/m/r — SETTINGS FILES ONLY) ──────────────────────────
# K/m/r decides what happens to a box's DEFINITION FILES and nothing else:
#   keep     — its interview and its file write are both skipped
#   modify   — full interview, defaults taken from the parsed existing values
#   recreate — full interview, "factory" defaults
# Containers are NOT its business: the build ladder's create rung always
# replaces whatever is there (see create_server / create_distrobox).
# CONFIGURE = boxes whose definitions are (re)generated (new/recreate/modify).
# KEEP      = boxes left untouched, but STILL offered the build ladder so a
#             prior "write only" run can later pull/create/start them.
action_of()   { case "$1" in k) printf 'keep' ;; m) printf 'modify' ;; r) printf 'recreate' ;; esac; }
action_verb() { case "$1" in keep) printf 'Keeping' ;; modify) printf 'Modifying' ;; *) printf 'Recreating' ;; esac; }
action_tail() { case "$1" in keep) printf ' as-is' ;; *) printf '' ;; esac; }

# The "[K/r/m]" cluster with the CURRENT default capitalised (opt_row and the
# prompt hint follow the same rule everywhere else in the installer).
kmr_cluster() {  # k|m|r
  case "$1" in
    m) printf 'k/r/M' ;;
    r) printf 'k/R/m' ;;
    *) printf 'K/r/m' ;;
  esac
}

box_options() {  # box-with-settings...
  local -a have=("$@")
  local box letters="Krm" choice all=1 act pl
  CONFIGURE=()
  KEEP=()
  for box in "${SELECTED[@]}"; do ACTION[$box]=""; done
  if [[ ${#have[@]} -gt 0 ]]; then
    say ""
    printf '  %s%s%s\n' "$C_HDR" "Box Options" "$RESET"
    opt_row K "eep settings as-is (make no modifications)" "" 0 "$(isdef K "$letters")"
    opt_row m "odify settings (set defaults to existing values)" "" 0 "$(isdef m "$letters")"
    opt_row r "ecreate settings (start from \"factory\" settings)" "" 0 "$(isdef r "$letters")"
    say ""
    ask_choice "Please indicate how to proceed [$(kmr_cluster k)]" "$letters"
    choice=$ANS_CH
    if [[ ${#have[@]} -gt 1 ]]; then
      ask_yn "Do the same for all boxes" Y
      all=$ANS_YN
    fi
    if [[ $all -eq 1 ]]; then
      act=$(action_of "$choice")
      for box in "${have[@]}"; do ACTION[$box]=$act; done
      say ""
      if [[ ${#have[@]} -eq 1 ]]; then
        printf '  %s%s %s%s-halo%s settings%s.%s\n' "$C_TEXT" "$(action_verb "$act")" \
          "$C_DETN" "${have[0]}" "$C_TEXT" "$(action_tail "$act")" "$RESET"
      else
        printf '  %s%s droste-halo settings%s: %s\n' "$C_TEXT" \
          "$(action_verb "$act")" "$(action_tail "$act")" \
          "$(name_list "$C_DETN" "${have[@]}")"
      fi
    else
      # A1 + Jei's round-2 correction: the answer just given IS the first box's
      # answer (it is not asked again); only the REMAINING selected boxes are
      # prompted, each defaulting to that first answer.
      pl="${choice^}${letters//[$choice${choice^}]/}"
      ACTION[${have[0]}]=$(action_of "$choice")
      for box in "${have[@]:1}"; do
        ask_choice "Please indicate how to proceed for $box [$(kmr_cluster "$choice")]" "$pl"
        ACTION[$box]=$(action_of "$ANS_CH")
      done
      say ""
      for box in "${have[@]}"; do
        act=${ACTION[$box]}
        printf '  %s%s %s%s%s settings%s.%s\n' "$C_TEXT" "$(action_verb "$act")" \
          "$C_DETN" "$box-halo" "$C_TEXT" "$(action_tail "$act")" "$RESET"
      done
    fi
  fi
  for box in "${SELECTED[@]}"; do
    [[ -n "${ACTION[$box]}" ]] || ACTION[$box]=new
    case "${ACTION[$box]}" in
      keep) KEEP+=("$box") ;;
      *)    CONFIGURE+=("$box") ;;
    esac
  done
  return 0
}

# The section itself (A6): it exists to ask K/m/r about SETTINGS, so it renders
# only when a selected box actually has settings to keep/modify/recreate —
# banner included. A virgin system never sees it, and neither does a system
# whose images are pulled but whose settings files are gone (Jei, live test:
# the images listing was cut entirely — nothing here reports on images).
existing_settings() {
  local box
  local -a haveset=()
  for box in "${SELECTED[@]}"; do
    [[ -n "${EX_INI[$box]:-}" ]] && haveset+=("$box")
  done
  # The SECTION is drawn only when a selected box has settings to ask about.
  # box_options runs EITHER WAY: besides the K/m/r question it is what sorts
  # every selected box into CONFIGURE/KEEP (a box with no settings is "new",
  # and nobody is asked anything about it).
  [[ ${#haveset[@]} -gt 0 ]] && section "Existing Settings"
  box_options ${haveset[@]+"${haveset[@]}"}
  return 0
}

# Populate a kept box's CFG_*/PATHS from its parsed existing files so the build
# ladder (pull/create/start) and the dashboard/notes work without re-asking.
hydrate_keep() {  # box
  local box=$1 pair label
  CFG_PORT[$box]=${EXD_PORT[$box]:-${BOX_HOST_PORT[$box]}}
  CFG_BOXSV[$box]=${EXD_BOXSV[$box]:-}
  CFG_HSTSV[$box]=${EXD_HSTSV[$box]:-}
  CFG_MODE[$box]=${EXD_MODE[$box]:-}
  CFG_FS[$box]=${CFG_FS[$box]:-?}
  [[ -n "${EXD_PATH["$box:data"]:-}" ]] && PATHS["$box:data"]=${EXD_PATH["$box:data"]}
  for pair in ${BOX_EXTRA_BINDS[$box]}; do
    label=${pair%%:*}
    [[ -n "${EXD_PATH["$box:$label"]:-}" ]] && PATHS["$box:$label"]=${EXD_PATH["$box:$label"]}
  done
  # Shared dirs, so a kept box can still describe itself in NOTES/the dashboard.
  [[ -z $HF_CACHE      && -n "${EXD_PATH["$box:hf"]:-}" ]]     && HF_CACHE=${EXD_PATH["$box:hf"]}
  [[ -z $COMPUTE_CACHE && -n "${EXD_PATH["$box:caches"]:-}" ]] && COMPUTE_CACHE=${EXD_PATH["$box:caches"]}
  [[ -z $MODELS_DIR    && -n "${EXD_PATH["$box:models"]:-}" ]] && MODELS_DIR=${EXD_PATH["$box:models"]}
  return 0
}

# ── Global default seeding (K/m/r is known; the files are parsed) ────────────
# EVERY question except the resource-path one (which has to come first — until
# it is answered no file can be found) takes its default from what the old
# definition files say, paths AND toggles, install-wide questions included.
#
# The SOURCE is strictly narrow (Jei s34): only boxes that are BOTH selected
# this run AND marked MODIFY. Recreate means a clean slate, so a recreate box
# contributes nothing and sees the factory value; a kept box is frozen and
# skipped, so it contributes nothing either. A pure-recreate selection gets
# factory defaults everywhere. That is why this runs AFTER Box Options.
SEED_PORTS=Y                 # "use default ports for all services"
SEED_SERVE=n SEED_HOST=n     # the two three-way start questions (y|n|c)
SEED_DATA_Q1=Y SEED_DATA_Q2=N SEED_DATA_BASE=""     # service-data placement
SEED_OTHER_Q1=Y SEED_OTHER_Q2=N SEED_OTHER_BASE=""  # input/output/workspace
SEED_HF="" SEED_COMPUTE="" SEED_MODELS_Q=N SEED_MODELS=""
SEED_SRC=()                  # the boxes whose files may seed anything at all

# Selected AND modify — the only boxes a default may be read from.
seed_sources() {
  local box
  SEED_SRC=()
  for box in "${SELECTED[@]}"; do
    [[ ${ACTION[$box]:-} == modify ]] && SEED_SRC+=("$box")
  done
  return 0
}

# The common base of a family of recorded paths, or "" when they do not share
# the <base>/<box>/<leaf> shape (or disagree about the base).
family_base() {   # leaf...
  local leaf box p base first="" seen=0
  for box in ${SEED_SRC[@]+"${SEED_SRC[@]}"}; do
    for leaf in "$@"; do
      p=${EXD_PATH["$box:$leaf"]:-}
      [[ -n $p ]] || continue
      if [[ $p == */"$box"/"$leaf" ]]; then base=${p%/"$box"/"$leaf"}; else base="-"; fi
      if [[ $seen -eq 0 ]]; then first=$base seen=1
      elif [[ $base != "$first" ]]; then printf '-'; return 0
      fi
    done
  done
  [[ $seen -eq 0 ]] && return 0     # nothing recorded: caller keeps its factory
  printf '%s' "$first"
  return 0
}

seed_globals() {
  local box base first_leaf yes=0 no=0
  seed_sources
  # Factory values first: with no seed source (all-recreate, all-new, all-keep)
  # these are exactly what every question below offers.
  SEED_PORTS=Y
  SEED_SERVE=n SEED_HOST=n
  SEED_DATA_Q1=Y SEED_DATA_Q2=N
  SEED_OTHER_Q1=Y SEED_OTHER_Q2=N
  SEED_MODELS_Q=N
  SEED_HF=$HOME/.cache/huggingface
  SEED_COMPUTE=$EMIT_DIR/caches
  # The model collection lives UNDER the resource path by default (Jei s34):
  # one directory holds the whole droste installation unless told otherwise.
  SEED_MODELS=$EMIT_DIR/models
  SEED_DATA_BASE=$EMIT_DIR
  SEED_OTHER_BASE=$EMIT_DIR
  [[ ${#SEED_SRC[@]} -eq 0 ]] && return 0
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_PATH["$box:hf"]:-}" ]] && { SEED_HF=${EXD_PATH["$box:hf"]}; break; }
  done
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_PATH["$box:caches"]:-}" ]] && { SEED_COMPUTE=${EXD_PATH["$box:caches"]}; break; }
  done
  # A recorded /opt/models bind is the answer to the toggle AND to the path.
  for box in "${SEED_SRC[@]}"; do
    if [[ -n "${EXD_PATH["$box:models"]:-}" ]]; then
      SEED_MODELS_Q=Y
      SEED_MODELS=${EXD_PATH["$box:models"]}
      break
    fi
  done
  # Ports: wholesale defaults only if nothing recorded moved off them.
  for box in "${SEED_SRC[@]}"; do
    if [[ -n "${EXD_PORT[$box]:-}" && ${EXD_PORT[$box]} != "${BOX_HOST_PORT[$box]}" ]]; then
      SEED_PORTS=N
      break
    fi
  done
  # The two three-way questions: unanimous seed boxes seed their own answer,
  # a split seeds "case-by-case" (which is what the split IS).
  yes=0 no=0
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_BOXSV[$box]:-}" ]] && yes=$((yes + 1)) || no=$((no + 1))
  done
  if [[ $yes -gt 0 && $no -gt 0 ]]; then SEED_SERVE=c
  elif [[ $yes -gt 0 ]]; then SEED_SERVE=y
  else SEED_SERVE=n
  fi
  # Host boot is only meaningful for boxes that serve at box start (the
  # invariant), so only those boxes get a vote here.
  yes=0 no=0
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_BOXSV[$box]:-}" ]] || continue
    [[ -n "${EXD_HSTSV[$box]:-}" ]] && yes=$((yes + 1)) || no=$((no + 1))
  done
  if [[ $yes -gt 0 && $no -gt 0 ]]; then SEED_HOST=c
  elif [[ $yes -gt 0 ]]; then SEED_HOST=y
  else SEED_HOST=n
  fi
  # Service data: same base as the resource path → Y; a different single base →
  # N + "different base" prefilled; anything else → both N (ask per box).
  base=$(family_base data)
  if [[ -n $base ]]; then
    if [[ $base == "$EMIT_DIR" ]]; then
      SEED_DATA_Q1=Y
    elif [[ $base == "-" ]]; then
      SEED_DATA_Q1=N SEED_DATA_Q2=N
    else
      SEED_DATA_Q1=N SEED_DATA_Q2=Y SEED_DATA_BASE=$base
    fi
  fi
  # Other data (input/output/workspace) against the service-data base.
  first_leaf=$(family_base input output workspace)
  if [[ -n $first_leaf ]]; then
    if [[ $first_leaf == "-" ]]; then
      SEED_OTHER_Q1=N SEED_OTHER_Q2=N
    elif [[ -n $base && $base != "-" && $first_leaf == "$base" ]]; then
      SEED_OTHER_Q1=Y
    elif [[ -z $base && $first_leaf == "$EMIT_DIR" ]]; then
      SEED_OTHER_Q1=Y
    else
      SEED_OTHER_Q1=N SEED_OTHER_Q2=Y SEED_OTHER_BASE=$first_leaf
    fi
  fi
  return 0
}

# ── General Setup ────────────────────────────────────────────────────────────
# Everything that can be settled ONCE for the whole install: the two networking
# questions that would otherwise repeat per box (ports, and when a box's server
# comes up), then where the two data families and the shared caches live.
general_setup() {
  local box wants_other=0
  for box in "${CONFIGURE[@]}"; do
    [[ -n "${BOX_EXTRA_BINDS[$box]}" ]] && wants_other=1
  done
  section "General Setup"
  subhdr "Networking"
  # One answer settles every per-box port question (the table above just showed
  # the defaults, so this is the moment they can be accepted wholesale).
  ask_yn "Use default ports for all services" "$SEED_PORTS"
  [[ $ANS_YN -eq 1 ]] && PORTS_DEFAULT=1
  # Does a box's SERVICE come up when its container starts? (server.env SERVE.)
  # "case-by-case" hands the question to each box's own section.
  ask_ync "Start servers at box start" "$SEED_SERVE"
  SERVE_MODE=$ANS_3
  # And does the BOX come up at host boot? (a systemd user unit doing `podman
  # start`.) INVARIANT (Jei): host boot ⇒ box start. So a box that does not
  # serve at box start is never asked about host boot, at any level:
  #   box-start = no   → host boot is no, no question anywhere
  #   box-start = c    → host boot is implicitly case-by-case, and only the
  #                      boxes that answered yes above are asked
  #   box-start = yes  → the install-wide question below
  case "$SERVE_MODE" in
    y) ask_ync "Start servers at host boot" "$SEED_HOST"; HOST_MODE=$ANS_3 ;;
    c) HOST_MODE=c ;;
    *) HOST_MODE=n ;;
  esac
  subhdr "Storage Paths"
  # The prompts name the BASE, not the templated leaf (Jei, live test): the
  # per-box "<base>/<box>/data" shape is the installer's business, and spelling
  # it out here read as though the literal string were the answer.
  ask_yn "Store all service data in $(emph "$(home_disp "$EMIT_DIR")")" \
    "$SEED_DATA_Q1"
  if [[ $ANS_YN -eq 1 ]]; then
    DATA_AUTO=1
  else
    ask_yn "Provide a different base path for service data" "$SEED_DATA_Q2"
    if [[ $ANS_YN -eq 1 ]]; then
      ask_path_as "Base path for service data" "$SEED_DATA_BASE"
      DATA_ROOT=$ANS_PATH
      DATA_AUTO=1
    fi
  fi
  # The other CRITICAL binds (input/output/workspace). Answering this places
  # them all; declining it hands them back to the per-box "<Box> Paths" questions (A2).
  if [[ $wants_other -eq 1 ]]; then
    # Same rule, and the base shown is the SERVICE-DATA one — so a different
    # base just chosen above is what this question offers to share.
    ask_yn "Store other data $(emph "(input, output, workspace, etc.)") in $(emphg "$(home_disp "$(data_root)")")" \
      "$SEED_OTHER_Q1"
    if [[ $ANS_YN -eq 1 ]]; then
      OTHER_AUTO=1
    else
      ask_yn "Provide a different base path for other box data" "$SEED_OTHER_Q2"
      if [[ $ANS_YN -eq 1 ]]; then
        ask_path_as "Base path for other box data" "$SEED_OTHER_BASE"
        OTHER_ROOT=$ANS_PATH
        OTHER_AUTO=1
      fi
    fi
  fi
  sub "Please provide paths for shared box data (caches, models)."
  ask_path_as "HuggingFace cache (models)" "$SEED_HF"
  HF_CACHE=$ANS_PATH
  ask_path_as "Compute cache (MIOpen/Triton/torch)" "$SEED_COMPUTE"
  COMPUTE_CACHE=$ANS_PATH
  ask_yn "Bind read-only model collection to /opt/models" "$SEED_MODELS_Q"
  if [[ $ANS_YN -eq 1 ]]; then
    ask_path_as "Path for local model collections" "$SEED_MODELS"
    MODELS_DIR=$ANS_PATH
  fi
  return 0
}

# ── Filesystem probe + overlay mitigation (the ecryptfs lesson) ──────────────
FSTYPE=""
probe_fstype() {  # dir → FSTYPE
  local d=$1
  if [[ -n "${DROSTE_SETUP_FSTYPE:-}" ]]; then
    FSTYPE=$DROSTE_SETUP_FSTYPE
    return 0
  fi
  while [[ ! -e $d && $d != / ]]; do d=$(dirname "$d"); done
  FSTYPE=$(findmnt -n -o FSTYPE --target "$d" 2>/dev/null) \
    || FSTYPE=$(stat -f -c %T "$d" 2>/dev/null) || FSTYPE=unknown
  [[ -z $FSTYPE ]] && FSTYPE=unknown
  return 0
}

MIT_ALL=""        # ""=unset, else fuse|copy|ignore applied to all later paths
MIT_ASKED=0
MIT_MODE=""       # result of the last mitigate_path call ("" = nothing needed)

# One continuous block of prose, word-wrapped to the screen and indented two.
prose() {   # text
  local w line
  w=$(( $(disp_width) - 2 ))
  while IFS= read -r line; do
    printf '  %s%s%s\n' "$C_TEXT" "$line" "$RESET"
  done < <(printf '%s\n' "$1" | fold -s -w "$w" | sed 's/[[:space:]]*$//')
  return 0
}

# The Data Mapping section: shown for the FIRST writable path that lands on a
# filesystem kernel overlayfs will not take, and again later for any path still
# unaccounted for (the "apply to all" answer is what stops the repeats).
# "nested" = shown from inside a per-box section, which wants a blank line above.
data_mapping_menu() {  # dir [nested] → ANS_CH in {f,c,n,i}
  local dir=$1 nested=${2:-} letters="Fcni"
  [[ $nested == nested ]] && say ""
  section "Data Mapping"
  say ""
  prose "The filesystem for $(home_disp "$dir") is incompatible with droste's default tool, Linux's overlayfs. Note: if ignored, filesystem must be changed before any containers can load."
  sub "Select an option to address filesystem incompatibility."
  opt_row F "use overlay" \
    "(app files ~30% slower; models OK)" 16 "$(isdef F "$letters")"
  opt_row c "opied files" \
    "(approx. 10-20 GB more storage)" 16 "$(isdef c "$letters")"
  opt_row n "ew path" "(most efficient)" 16 "$(isdef n "$letters")"
  opt_row i "gnore" "(\"ostrich solution\"; will fail on start)" 16 "$(isdef i "$letters")"
  say ""
  ask_choice "Identify how to proceed [F/c/n/i]" "$letters"
  return 0
}

# Probe ONE path and settle its overlay mitigation.
#   MIT_MODE=""            the filesystem is fine (or the path is not writable)
#   MIT_MODE=fuse|copy|ignore
#   return 2               the user asked for a NEW PATH — the caller re-asks
# The first hostile path opens the menu; "Apply this decision to all paths" is
# offered exactly once and, when accepted, silences every later path.
mitigate_path() {  # dir [nested]
  local dir=$1 nested=${2:-}
  MIT_MODE=""
  probe_fstype "$dir"
  overlay_hostile_fs "$FSTYPE" || return 0
  if [[ -n $MIT_ALL ]]; then
    MIT_MODE=$MIT_ALL
    return 0
  fi
  data_mapping_menu "$dir" "$nested"
  case "$ANS_CH" in
    f) MIT_MODE=fuse ;;
    c) MIT_MODE=copy ;;
    i) MIT_MODE=ignore ;;
    n) return 2 ;;
  esac
  if [[ $MIT_ASKED -eq 0 ]]; then
    MIT_ASKED=1
    ask_yn "Apply this decision to all paths" Y
    [[ $ANS_YN -eq 1 ]] && MIT_ALL=$MIT_MODE
  fi
  return 0
}

# The paths that exist before any box section, most primary first.
mitigation_slot_path() {  # slot → path ("" when that slot is not in play)
  case "$1" in
    rc)      printf '%s' "$EMIT_DIR" ;;
    base)    [[ -n $DATA_ROOT && $DATA_ROOT != "$EMIT_DIR" ]] \
               && printf '%s' "$DATA_ROOT" ;;
    other)   [[ -n $OTHER_ROOT && $OTHER_ROOT != "$(data_root)" ]] \
               && printf '%s' "$OTHER_ROOT" ;;
    compute) printf '%s' "$COMPUTE_CACHE" ;;
    hf)      printf '%s' "$HF_CACHE" ;;
  esac
  return 0
}

# Re-ask ONE of those paths (the "new path" answer) and take the new value.
reask_slot() {  # slot → 0 when re-asked
  case "$1" in
    rc)
      ask_path_as "Identify a path for droste resource storage" "$EMIT_DIR"
      # A data base that merely tracked the resource path keeps tracking it.
      [[ $DATA_ROOT == "$EMIT_DIR" ]] && DATA_ROOT=""
      EMIT_DIR=$ANS_PATH
      DEFAULT_ROOT=$EMIT_DIR
      # Everything the old resource path implied has to be re-derived: which
      # boxes already exist there, and what the user wants done about them.
      EX_INI=() EX_CTR=() EXD_PATH=()
      EXD_PORT=() EXD_BOXSV=() EXD_HSTSV=() EXD_MODE=()
      detect_existing
      existing_settings
      seed_globals
      ;;
    base)
      ask_path_as "Base path for service data" "$(data_root)"
      DATA_ROOT=$ANS_PATH ;;
    other)
      ask_path_as "Base path for other box data" "$OTHER_ROOT"
      OTHER_ROOT=$ANS_PATH ;;
    compute)
      ask_path_as "Compute cache (MIOpen/Triton/torch)" "$COMPUTE_CACHE"
      COMPUTE_CACHE=$ANS_PATH ;;
    hf)
      ask_path_as "HuggingFace cache (models)" "$HF_CACHE"
      HF_CACHE=$ANS_PATH ;;
    *) return 1 ;;
  esac
  return 0
}

# Data Mapping over the paths chosen BEFORE any box section. Only the FIRST /
# most primary hostile one opens the section (Jei's spec); whatever the user
# answers there either covers every path that follows ("apply to all") or leaves
# the remaining paths to raise it again where they arise, box paths included.
global_mitigation() {
  local slot dir rc
  while :; do
    dir=""
    for slot in rc base other compute hf; do
      dir=$(mitigation_slot_path "$slot")
      [[ -n $dir ]] || continue
      probe_fstype "$dir"
      overlay_hostile_fs "$FSTYPE" && break
      dir=""
    done
    [[ -z $dir ]] && return 0
    rc=0
    mitigate_path "$dir" || rc=$?
    if [[ $rc -ne 2 ]]; then
      # Close the section the way a per-box section closes, so the banner
      # below it keeps the same two-line gap as every other banner.
      say ""
      return 0
    fi
    reask_slot "$slot" || return 0
  done
}

# ── Where the two path families live ─────────────────────────────────────────
# Both are settled up front in General Setup; the old "would you like this
# pattern applied to everything?" follow-up (PATTERN_ROOT) is retired with it.
DEFAULT_ROOT=""  # emit dir (default ~/droste)

# Base path for the SERVICE DATA family (/opt/data) and for the OTHER data
# family (input/output/workspace). Caches are deliberately in neither: they
# were asked separately.
DATA_ROOT=""     # "" = the resource path itself
DATA_AUTO=0      # 1 = every box's data dir is <base>/<box>/data, never asked
OTHER_ROOT=""    # "" = wherever the service data family lives
OTHER_AUTO=0     # 1 = every box's other binds are <base>/<box>/<label>
PORTS_DEFAULT=0  # 1 = every box takes the default host port, never asked
SERVE_MODE=n     # y|n|c — serve at box start, install-wide (c = ask per box)
HOST_MODE=n      # y|n|c — start at host boot, install-wide (c = ask per box)

data_root()  { printf '%s' "${DATA_ROOT:-$DEFAULT_ROOT}"; }
other_root() { printf '%s' "${OTHER_ROOT:-$(data_root)}"; }

# 1 when this label needs no question (General Setup already placed it).
auto_label() {  # label
  if [[ $1 == data ]]; then [[ $DATA_AUTO -eq 1 ]]; else [[ $OTHER_AUTO -eq 1 ]]; fi
}

path_default() {  # box label → default path (existing value > family base)
  local box=$1 label=$2 root
  if [[ ${ACTION[$box]} == modify && -n "${EXD_PATH["$box:$label"]:-}" ]]; then
    printf '%s' "${EXD_PATH["$box:$label"]}"
  else
    [[ $label == data ]] && root=$(data_root) || root=$(other_root)
    printf '%s/%s/%s' "$root" "$box" "$label"
  fi
}

# Which labels of a box ended up on an overlay-hostile filesystem, and the
# filesystem that triggered it (both feed the mitigation line under the box).
declare -A MIT_LABELS MIT_FS

# Settle ONE bind path of a box: pick it (automated, pattern-filled, or asked),
# make sure it exists, and answer its filesystem question. Sets PATHS[box:label]
# — plus CFG_FS/CFG_MODE when the label is the data dir, since /opt/data is the
# bind the in-box overlay is actually built on.
set_bind_path() {  # box label
  local box=$1 label=$2 def rc force=0
  while :; do
    def=$(path_default "$box" "$label")
    if [[ $force -eq 0 ]] && auto_label "$label"; then
      # General Setup placed this family; a modify box's recorded path is
      # its own default, so an auto-placed run leaves it exactly where it was.
      ANS_PATH=$def
      ensure_dir "$ANS_PATH" || :
    else
      # No per-bind header: the prompt itself names the box + bind family.
      ask_path_as "Path for ${BOX_NAME[$box]} ${BIND_TITLE[$label],,}" "$def"
    fi
    PATHS["$box:$label"]=$ANS_PATH
    # Modify with the SAME path keeps the mitigation already recorded for it
    # (re-prompts default to current values); a changed path is re-decided.
    if [[ $label == data && ${ACTION[$box]} == modify && -n "${EXD_MODE[$box]:-}" \
          && $ANS_PATH == "${EXD_PATH["$box:data"]:-}" ]]; then
      probe_fstype "$ANS_PATH"
      CFG_FS[$box]=$FSTYPE
      if overlay_hostile_fs "$FSTYPE"; then
        CFG_MODE[$box]=${EXD_MODE[$box]}
        MIT_LABELS[$box]="${MIT_LABELS[$box]:-} $label"
        MIT_FS[$box]=$FSTYPE
      fi
      return 0
    fi
    rc=0
    mitigate_path "$ANS_PATH" nested || rc=$?
    if [[ $rc -eq 2 ]]; then
      # "new path": this one gets asked explicitly, whatever settled it before.
      force=1
      continue
    fi
    break
  done
  [[ $label == data ]] && CFG_FS[$box]=$FSTYPE
  if [[ -n $MIT_MODE ]]; then
    [[ $label == data ]] && CFG_MODE[$box]=$MIT_MODE
    MIT_LABELS[$box]="${MIT_LABELS[$box]:-} $label"
    MIT_FS[$box]=$FSTYPE
  elif [[ $label == data ]]; then
    CFG_MODE[$box]=""
  fi
  return 0
}

# ── Per-box configuration ────────────────────────────────────────────────────
# ONE section per box now ("Box Settings"), carrying whatever General Setup left
# unanswered for it: a Networking subheader (its port, and the two start
# questions when either was answered "case-by-case") and a "<Box> Paths"
# subheader (the binds no wholesale answer placed). A box with nothing left to
# ask shows its banner and its summary, and no section at all.
configure_box() {  # box
  local box=$1 pair label dest
  local asked=0 bw sv_def=N hs_def=N pdef
  banner "${BOX_BANNER[$box]}" bold
  bw=$BANNER_W

  # Which of this box's questions are still open? Data and the other binds are
  # skipped when General Setup placed their family; the port when the defaults
  # were accepted wholesale; the two start questions unless their install-wide
  # answer was "case-by-case" (and, for host boot, unless this box serves).
  local -a todo=()
  local want_port=0 want_sv=0
  [[ $DATA_AUTO -eq 0 ]] && todo+=(data)
  if [[ $OTHER_AUTO -eq 0 ]]; then
    for pair in ${BOX_EXTRA_BINDS[$box]}; do
      todo+=("${pair%%:*}")
    done
  fi
  [[ $PORTS_DEFAULT -eq 0 ]] && want_port=1
  [[ $SERVE_MODE == c ]] && want_sv=1
  if [[ $want_port -eq 1 || $want_sv -eq 1 || $HOST_MODE == c ]]; then
    asked=1
    section "Box Settings"
  fi

  # ── Networking ────────────────────────────────────────────────────────────
  # Port first (it is the value the other two answers switch on and off), then
  # box start, then — only if this box serves — host boot.
  if [[ $want_port -eq 1 || $want_sv -eq 1 || $HOST_MODE == c ]]; then
    subhdr "Networking"
  fi
  pdef=${BOX_HOST_PORT[$box]}
  [[ ${ACTION[$box]} == modify && -n "${EXD_PORT[$box]:-}" ]] && pdef=${EXD_PORT[$box]}
  if [[ $want_port -eq 1 ]]; then
    ask_port "$box" "$pdef"
    CFG_PORT[$box]=$ANS_PORT
  else
    CFG_PORT[$box]=$pdef
  fi
  CFG_BOXSV[$box]=""
  if [[ $want_sv -eq 1 ]]; then
    [[ ${ACTION[$box]} == modify && -n "${EXD_BOXSV[$box]:-}" ]] && sv_def=Y
    ask_yn "Start the ${BOX_NAME[$box]} server at box start" "$sv_def"
    [[ $ANS_YN -eq 1 ]] && CFG_BOXSV[$box]=1
  elif [[ $SERVE_MODE == y ]]; then
    CFG_BOXSV[$box]=1
  fi
  CFG_HSTSV[$box]=""
  if [[ -n "${CFG_BOXSV[$box]}" ]]; then
    if [[ $HOST_MODE == c ]]; then
      [[ ${ACTION[$box]} == modify && -n "${EXD_HSTSV[$box]:-}" ]] && hs_def=Y
      ask_yn "Start the ${BOX_NAME[$box]} server at host boot" "$hs_def"
      [[ $ANS_YN -eq 1 ]] && CFG_HSTSV[$box]=1
    elif [[ $HOST_MODE == y ]]; then
      CFG_HSTSV[$box]=1
    fi
  fi

  # ── <Box> Paths ───────────────────────────────────────────────────────────
  # The data dir (+ fs probe / overlay mitigation), then the other CRITICAL
  # binds. /opt/data is where server.env lands, so this path is what decides
  # where the box reads its serve config from.
  if [[ ${#todo[@]} -gt 0 ]]; then
    if [[ $asked -eq 0 ]]; then
      asked=1
      section "Box Settings"
    fi
    subhdr "${BOX_NAME[$box]} Paths"
  fi
  set_bind_path "$box" data
  for pair in ${BOX_EXTRA_BINDS[$box]}; do
    label=${pair%%:*} dest=${pair#*:}
    : "$dest"          # the container side is the emitters' business, not ours
    set_bind_path "$box" "$label"
  done

  [[ $asked -eq 1 ]] && say ""
  summary_box "$box" "$bw"
  mitigation_line "$box"
  say ""
  return 0
}

# ── Per-box summary ──────────────────────────────────────────────────────────
# The box that closes each per-box section: where its data lands, which host
# port it answers on, and when its server comes up. Values are BARE (no
# brackets). The rows are GROUPED — "* Paths" then "* Server" — because the two
# halves answer different questions and the box is read at a glance.
# Width: the banner's, so the two stack; wider only when a path needs it, and
# never past the screen — a path that still will not fit is elided by fit_path.
SUM_HDR_W=14       # "Start w Host: " is the longest header, and sets the column

summary_box() {  # box banner-width
  local box=$1 bw=$2 inner avail pair label
  local -a keys=() vals=() kind=()
  keys+=("Paths") vals+=("") kind+=(g)
  keys+=("${BIND_ROW[data]}:") vals+=("$(home_disp "${PATHS["$box:data"]}")") kind+=(v)
  for pair in ${BOX_EXTRA_BINDS[$box]}; do
    label=${pair%%:*}
    keys+=("${BIND_ROW[$label]}:") vals+=("$(home_disp "${PATHS["$box:$label"]}")") kind+=(v)
  done
  # One blank line between the groups (Jei) — pushed only when the Paths group
  # actually produced rows, so a box with nothing above it grows no leading gap.
  [[ ${#kind[@]} -gt 0 ]] && { keys+=("") vals+=("") kind+=(s); }
  keys+=("Server") vals+=("") kind+=(g)
  keys+=("Port:") vals+=("${CFG_PORT[$box]}") kind+=(v)
  keys+=("Start w Box:") vals+=("$(yn_word "${CFG_BOXSV[$box]:-}")") kind+=(v)
  keys+=("Start w Host:") vals+=("$(yn_word "${CFG_HSTSV[$box]:-}")") kind+=(v)
  # Widest row wins, floored at the banner and capped at the screen. A row that
  # sets the width keeps one space in front of the right border, mirroring the
  # one after the left one.
  inner=$(( bw - 2 ))
  local i n w
  n=${#vals[@]}
  for (( i = 0; i < n; i = i + 1 )); do
    w=$(( 4 + SUM_HDR_W + ${#vals[i]} ))
    [[ $w -gt $inner ]] && inner=$w
  done
  avail=$(( $(disp_width) - 4 ))
  [[ $inner -gt $avail ]] && inner=$avail
  local fill="" v
  # shellcheck disable=SC2324  # string append of the border char, not math
  for (( i = 0; i < inner; i = i + 1 )); do fill+=$BOXH; done
  printf '  %s%s%s%s%s\n' "$C_SBOX" "$BOXTL" "$fill" "$BOXTR" "$RESET"
  for (( i = 0; i < n; i = i + 1 )); do
    if [[ ${kind[i]} == s ]]; then
      # The spacer: borders and nothing else.
      printf '  %s%s%*s%s%s\n' \
        "$C_SBOX" "$BOXV" "$inner" "" "$BOXV" "$RESET"
      continue
    fi
    if [[ ${kind[i]} == g ]]; then
      # A group header: "* Name", underlined — and the underline is why the
      # RESET lands before the padding (a coloured blank is a blank, an
      # underlined one is a visible rule out to the border).
      printf '  %s%s%s %s*%s %s%s%s%*s%s%s%s\n' \
        "$C_SBOX" "$BOXV" "$RESET" "$C_SBUL" "$RESET" \
        "$C_SGRP" "${keys[i]}" "$RESET" \
        "$(( inner - 3 - ${#keys[i]} ))" "" "$C_SBOX" "$BOXV" "$RESET"
      continue
    fi
    v=$(fit_path "${vals[i]}" $(( inner - 4 - SUM_HDR_W )))
    printf '  %s%s%s %s+%s %s%-*s%s%s%*s%s%s%s\n' \
      "$C_SBOX" "$BOXV" "$RESET" "$C_SBUL" "$RESET" \
      "$C_SHDR" "$SUM_HDR_W" "${keys[i]}" "$C_SVAL" "$v" \
      "$(( inner - 3 - SUM_HDR_W - ${#v} ))" "" "$C_SBOX" "$BOXV" "$RESET"
  done
  printf '  %s%s%s%s%s\n' "$C_SBOX" "$BOXBL" "$fill" "$BOXBR" "$RESET"
  return 0
}

# The summary box's spelling of a 1/"" toggle.
yn_word() { [[ -n $1 ]] && printf 'yes' || printf 'no'; }

# The one-line consequence under the summary box: what the filesystem forced,
# and which of the box's paths it applies to. Nothing is printed when the
# filesystem was fine.
MIT_ORDER="data input output workspace"   # reading order of the sentence

mitigation_line() {  # box
  local box=$1
  local mode=${CFG_MODE[$box]:-} fs cats="" i n got k
  local -a labels=()
  got=" ${MIT_LABELS[$box]:-} "
  # Listed in reading order, not in the order the paths happened to be asked.
  for k in $MIT_ORDER; do
    [[ $got == *" $k "* ]] && labels+=("$k")
  done
  n=${#labels[@]}
  [[ $n -eq 0 ]] && return 0
  [[ -z $mode ]] && mode=$MIT_ALL
  [[ -z $mode ]] && return 0
  fs=${MIT_FS[$box]:-${CFG_FS[$box]:-unknown}}
  # One item stands alone, two are joined with "and", three or more take the
  # comma series ("data, input, & output").
  for (( i = 0; i < n; i = i + 1 )); do
    if [[ $i -eq 0 ]]; then
      cats="$C_MCAT${labels[i]}"
    elif [[ $i -eq $(( n - 1 )) && $n -eq 2 ]]; then
      cats+="$C_TEXT and $C_MCAT${labels[i]}"
    elif [[ $i -eq $(( n - 1 )) ]]; then
      cats+="$C_TEXT, & $C_MCAT${labels[i]}"
    else
      cats+="$C_TEXT, $C_MCAT${labels[i]}"
    fi
  done
  printf '    %s%s%s %s%s detected%s — using %s%s%s for %s%s.%s\n' \
    "$C_ARROW" "$ARROW_M" "$RESET" "$C_SUBJ" "$fs" "$C_TEXT" \
    "$C_MOPT" "$mode" "$C_TEXT" "$cats" "$C_TEXT" "$RESET"
  return 0
}

# ── Build ladder ─────────────────────────────────────────────────────────────
ask_ladder() {
  local letters="Awpc"
  banner "Build & Activation" bold
  section "Records & Startup"
  sub "Please indicate your selection for box preparation:"
  opt_row w "" "Write definition(s) only (ini)" 4 "$(isdef w "$letters")"
  opt_row p "" "Write definition(s) & pull image(s)" 4 "$(isdef p "$letters")"
  opt_row c "" "Write, pull, & create box(es)" 4 "$(isdef c "$letters")"
  opt_row A "" "All of the above, and start enabled server(s)" 4 "$(isdef A "$letters")"
  say ""
  ask_choice "Select box preparation option [w/p/c/A]" "$letters"
  RUNG=$ANS_CH
  return 0
}

# ── Emitters ─────────────────────────────────────────────────────────────────
emit_ini() {  # box → writes <box>-halo.ini (distrobox assemble record)
  local box=$1 f base pair label dest vols flags data
  f=$(ini_file "$box")
  base=$(basename "$f")     # resolved OUTSIDE the redirect (it names the file)
  data=${PATHS["$box:data"]}
  {
    printf '# %s — generated by droste-setup.sh on %s\n' "$base" "$(date +%F)"
    printf '# Create/recreate with:  distrobox assemble create --file %s\n' "$f"
    printf '# Modeled on targets/%s/distrobox.ini (droste-ai-halo repo).\n' "$box"
    printf '# ONE container, two doors: "distrobox enter %s" for an\n' "$(box_ctr "$box")"
    printf '# interactive shell, "podman start %s" to bring the\n' "$(box_ctr "$box")"
    printf '# service up (the init hook reads %s/server.env\n' "$(home_disp "$data")"
    printf '# at every start and launches on the port recorded there).\n'
    # The record of what this installer last answered — read back on the next
    # run as the fallback for server.env (port, box start) and for the systemd
    # user unit (host boot), both of which the user may have changed by hand.
    # The "droste-setup:" key is an on-disk FORMAT, not the script's name: it
    # must keep matching the reader in parse_existing_ini for already-written
    # ini files, so it does NOT carry the script's .sh suffix.
    printf '# droste-setup: port=%s box-start=%s host-boot=%s\n' \
      "${CFG_PORT[$box]}" "$(yn_word "${CFG_BOXSV[$box]:-}")" \
      "$(yn_word "${CFG_HSTSV[$box]:-}")"
    printf '\n'
    printf '[%s]\n' "$(box_ctr "$box")"
    printf 'image=%s%s%s\n' "$IMAGE_PREFIX" "$box" "$IMAGE_SUFFIX"
    printf 'init_hooks="%s"\n' "$INIT_HOOK"
    # additional_flags append to `podman|docker create` (--env is the
    # distrobox docs' own example flag): sys_admin permits the in-box
    # resolver mounts, /dev/fuse enables the fuse-overlayfs fallback,
    # and --env carries the overlay-mitigation mode to the init hook.
    flags="--cap-add sys_admin --device /dev/fuse"
    case "${CFG_MODE[$box]:-}" in
      fuse|copy) flags+=" --env DROSTE_OVERLAY_MODE=${CFG_MODE[$box]}" ;;
    esac
    # Graceful-stop stance: podman still SIGKILLs the served process after this
    # timeout (distrobox-init does not forward SIGTERM to it), so the number is
    # a ceiling, not a promise — see NOTES.md.
    flags+=" --stop-timeout $STOP_TIMEOUT"
    # Supervision, unconditionally: the probe answers HEALTHY for a box that is
    # not serving, so an interactive-only box is not restart-looped by it, and a
    # box whose server.env is turned on later is supervised without a recreate.
    flags+=" --health-cmd $HEALTH_CMD"
    flags+=" --health-interval $HEALTH_INTERVAL"
    flags+=" --health-retries $HEALTH_RETRIES"
    flags+=" --health-start-period ${BOX_HEALTH_START[$box]}"
    flags+=" --health-on-failure=restart"
    printf '# Healthcheck: %s probes the service and\n' "$HEALTH_CMD"
    printf '# podman restarts the container when it fails. The start period\n'
    printf '# (%s) is the grace this box needs to load its model.\n' \
      "${BOX_HEALTH_START[$box]}"
    printf 'additional_flags="%s"\n' "$flags"
    # CRITICAL: distrobox assemble reads only the LAST volume= key, so EVERY
    # bind must live in ONE space-separated volume= value. Accumulate them all
    # here and emit a single line.
    vols="$data:/opt/data"
    for pair in ${BOX_EXTRA_BINDS[$box]}; do
      label=${pair%%:*} dest=${pair#*:}
      vols="$vols ${PATHS["$box:$label"]}:$dest"
    done
    # Shared compute cache (MIOpen/Triton/torch/vLLM kernels) — appended into
    # the same value (remove to keep caches per-box).
    vols="$vols $COMPUTE_CACHE:/opt/caches"
    # A non-default HF cache (outside the auto-bound host home) needs an
    # explicit bind to the in-box expected location — also same value.
    if [[ $HF_CACHE != "$HOME/.cache/huggingface" ]]; then
      vols="$vols $HF_CACHE:$HOME/.cache/huggingface"
    fi
    # Opted-in read-only model collection: the dir was confirmed-or-created at
    # prompt time, so the :ro bind is safe (a bind to a missing dir would be
    # fatal to `distrobox assemble create`). It lands INSIDE the single volume=.
    [[ -n $MODELS_DIR ]] && vols="$vols $MODELS_DIR:/opt/models:ro"
    printf '# Shared compute caches across ALL droste boxes are folded into the\n'
    printf '# single volume= value below (distrobox reads only the LAST volume=).\n'
    printf 'volume="%s"\n' "$vols"
    if [[ ${BOX_HAS_MODELS[$box]} -eq 1 ]]; then
      if [[ -n $MODELS_DIR ]]; then
        printf '# The read-only local model collection (%s -> /opt/models:ro)\n' \
          "$(home_disp "$MODELS_DIR")"
        printf '# is already included in the single volume= value above.\n'
      else
        # Not opted in: a read-only /opt/models bind to a missing dir is fatal to
        # `distrobox assemble create`, so it is not added — enable it by hand.
        printf '# Optional read-only local model collection: to enable, APPEND\n'
        printf '#   %s:/opt/models:ro\n' "$(home_disp "$EMIT_DIR/models")"
        printf '# (space-separated) INSIDE the single volume= value above — do NOT add a\n'
        printf '# second volume= line (distrobox reads only the LAST, dropping the rest).\n'
      fi
    fi
  } > "$f"
  exec_file "$base"
  return 0
}

# The serve config, written into the box's DATA dir — the file P1's
# droste-serve.sh reads at every container start (and droste-healthcheck.sh
# reads for the port). It is deliberately NOT listed in the Executing section:
# it is one line of answers the user already gave, not a definition to review.
#
# NEVER touched for a KEPT box (keep = "change nothing about settings", and this
# file is a settings file the user may well have hand-edited); rewritten from
# the current answers for every box that is (re)configured.
emit_serve_env() {  # box
  local box=$1 f
  f=$(serve_env_file "$box") || return 0
  [[ -n $f ]] || return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null || :
  {
    printf '# server.env — read by droste-init-hook.sh at every container start.\n'
    printf '# Written by droste-setup.sh on %s; safe to edit by hand:\n' "$(date +%F)"
    printf '#   SERVE=1  start the service when the box starts (0 = interactive only)\n'
    printf '#   PORT=    the port the service binds (host networking: no remap)\n'
    printf '# Take a change live with:  %s restart %s\n' \
      "${RUNTIME:-podman}" "$(box_ctr "$box")"
    printf 'SERVE=%s\n' "$([[ -n ${CFG_BOXSV[$box]:-} ]] && printf 1 || printf 0)"
    printf 'PORT=%s\n' "${CFG_PORT[$box]}"
  } > "$f" 2>/dev/null || warn "could not write $f — the box will not know its serve setting"
  return 0
}

# ── Host-boot: a systemd USER unit per box ───────────────────────────────────
# Fire-and-forget: `podman start` returns as soon as the container is up, so the
# unit is a oneshot that stays "active" afterwards (RemainAfterExit) — that is
# what makes `systemctl --user status droste-<box>` a truthful answer and what
# lets the manager stop the box on the way down.
write_host_unit() {  # box → 0 when the unit file is in place
  local box=$1 f bin
  f=$(unit_file "$box")
  bin=${RUNTIME_BIN:-/usr/bin/podman}
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  {
    printf '# %s — generated by droste-setup.sh on %s\n' "$(unit_name "$box")" "$(date +%F)"
    printf '[Unit]\n'
    printf 'Description=droste %s halo box (%s)\n' "$box" "$(box_ctr "$box")"
    printf 'Documentation=file://%s/NOTES.md\n' "$EMIT_DIR"
    printf '\n[Service]\n'
    printf 'Type=oneshot\n'
    printf 'RemainAfterExit=yes\n'
    printf 'ExecStart=%s start %s\n' "$bin" "$(box_ctr "$box")"
    printf 'ExecStop=%s stop %s\n' "$bin" "$(box_ctr "$box")"
    printf '\n[Install]\n'
    printf 'WantedBy=default.target\n'
  } > "$f" 2>/dev/null || return 1
  return 0
}

# Lingering, attempted by the installer itself: polkit's
# org.freedesktop.login1.set-self-linger defaults to allow_active=yes, so a
# local session needs no sudo (verified on Raiju). </dev/null so a pure-SSH
# session fails FAST instead of hanging on an authentication agent; the sudo
# fallback is then printed for the user to run.
enable_linger() {  # log → 0 when the user lingers
  local log=$1
  [[ $LINGER == yes ]] && return 0
  command -v loginctl >/dev/null 2>&1 || return 1
  if loginctl enable-linger </dev/null >>"$log" 2>&1; then
    LINGER=yes
    return 0
  fi
  return 1
}

linger_fallback_note() {
  printf '    %sboot auto-start needs lingering. Run:%s %ssudo loginctl enable-linger %s%s\n' \
    "$C_TEXT" "$RESET" "$C_PATHB" "${USER:-$(id -un)}" "$RESET"
  return 0
}

# ── Executing-section output ─────────────────────────────────────────────────
# Every line the Executing section prints comes from one of these four helpers,
# and NOTHING a tool writes reaches the screen: podman's and distrobox's own
# chatter is captured to a log (see step_log) and only its tail is shown, and
# only on failure. The section is the one place the installer speaks while
# something slow is happening, so it stays a fixed, readable shape.

# Underlined bright-white group header; the blank line above it is part of it.
exec_hdr() { printf '\n  %s%s%s\n' "$C_EXH" "$1" "$RESET"; }

# One emitted file name, italic light grey.
exec_file() { printf '  %s%s%s\n' "$C_FILE" "$1" "$RESET"; }

# Width of the name column in [OK]/[ERROR] status lines: the longest name of
# the WHOLE Executing section plus a three-space gap, clamped so the tag still
# lands inside the terminal (a name longer than that simply pushes the tag
# right). Three, not five: it pulls the image lines back under 60 columns
# (Jei s34), and one width for every group aligns Creating Boxes with Pulling
# Images instead of letting each group find its own column.
STATUS_W=0
status_width() {   # name...
  local n max=0 w avail
  for n in "$@"; do [[ ${#n} -gt $max ]] && max=${#n}; done
  w=$(( max + 3 ))
  avail=$(( $(disp_width) - 2 - 7 ))    # indent + "[ERROR]"
  [[ $w -gt $avail ]] && w=$avail
  [[ $w -lt 1 ]] && w=1
  STATUS_W=$w
  return 0
}

# WHERE THE IN-PROGRESS TEXT SITS. It used to start in the tag column, so a
# frame like "removing old (999s)" ran 15 columns PAST the end of [OK] (Jei,
# live test). It now starts TICK_BACK columns left of the tag, which keeps the
# widest realistic frame inside the tag's own right edge:
#   tag column      = 2 + STATUS_W          ("  " indent + the name column)
#   [OK] ends at      2 + STATUS_W + 4      ([ERROR] is 3 wider)
#   widest frame    = "removing old (999s)" = 19
#   22 back         ⇒ ends 2 + STATUS_W - 3, i.e. 7 short of [OK]'s end.
# Two guards keep that true for every real name and terminal:
#   FLOOR — never left of the name + one space (the pad would stop working and
#           the frame would push RIGHT instead). Of the real names only
#           "droste-finetuning-halo-server..." (32) reaches it, and only by 2
#           columns: that one line ticks 20 back rather than 22.
#   CAP   — never so far right that the frame could pass [OK]'s end anyway (a
#           narrow terminal clamps STATUS_W, which moves the tag left).
# The column is the same for every phase (only the CAP looks at the text), so
# the phase words line up with each other as well as under the tag.
TICK_BACK=22
TICK_PHASE="removing old"    # the widest phase word: it sizes the shared column
tick_col() {   # phase elapsed → column, relative to the two-space indent
  local need col room floor
  need=$(( ${#1} + ${#2} + 4 ))          # "<phase> (<el>s)"
  col=$(( STATUS_W - TICK_BACK ))
  room=$(( STATUS_W + 4 - need ))        # right edge of the [OK] tag
  [[ $col -gt $room ]] && col=$room
  floor=$(( ${#STATUS_NAME} + 1 ))
  [[ $col -lt $floor ]] && col=$floor
  [[ $col -lt 0 ]] && col=0
  printf '%s' "$col"
}

# A STATUS LINE HAS A LIFETIME, not just an ending: it opens the moment the
# work starts (so a slow step can never be mistaken for a hang), is repainted
# while the work runs, and is completed in place by the [OK]/[ERROR] tag.
#
#   status_start <name>          "  <name>...            "   (no newline)
#   run_step <phase> <log> cmd…  "  <name>...   creating (7s)"  ~1/s
#   status_ok/status_err <name>  "  <name>...            [OK]"
#
# In --plain there is no repaint plumbing (CR/EL are empty), so the line is
# closed at each transition instead: one line per phase as it begins, then the
# completion line. Never a per-second frame there — that would spam a log.
STATUS_OPEN=0     # 1 = a partial (unterminated) status line is on screen
STATUS_NAME=""    # what that line names, for the repaints
STATUS_COL=0      # how far that partial line was padded (the ticker column)

# The open line stops at the TICKER column, not the tag column: in --plain
# there is no way back, so whatever prints next (a phase word, or the padding
# up to the tag) has to start from a column that leaves room for it.
status_start() {   # name
  STATUS_NAME=$1
  STATUS_COL=$(tick_col "$TICK_PHASE" "")
  printf '  %s%-*s%s' "$C_TEXT" "$STATUS_COL" "$1" "$RESET"
  STATUS_OPEN=1
  return 0
}

# The head of a completed line: repainted from column 0 when the terminal can
# do that; otherwise the open line is simply padded the rest of the way to the
# tag column (or drawn whole, when nothing opened it).
status_head() {   # name
  local n
  if [[ -n $CR ]]; then
    printf '%s  %s%-*s%s' "$CR" "$C_TEXT" "$STATUS_W" "$1" "$RESET"
  elif [[ $STATUS_OPEN -eq 1 ]]; then
    n=$(( STATUS_W - STATUS_COL )); [[ $n -lt 1 ]] && n=1
    printf '%*s' "$n" ""
  else
    printf '  %s%-*s%s' "$C_TEXT" "$STATUS_W" "$1" "$RESET"
  fi
  STATUS_OPEN=0
  return 0
}

# Both endings close with erase-to-EOL, which is what wipes the widest ticker
# frame (the elapsed count grows a digit) or a progress bar of any width.
status_ok() {   # name
  status_head "$1"
  printf '%s[%s%s%s]%s%s\n' \
    "$C_OKB" "$C_OK" "OK" "$C_OKB" "$RESET" "$EL"
}

# Failure: the tag, then the LAST THREE captured lines (enough to name the
# cause), then where the whole capture lives. Raw tool output is never streamed.
status_err() {   # name log-path
  local name=$1 log=$2 line
  status_head "$name"
  printf '%s[%s%s%s]%s%s\n' \
    "$C_BADB" "$C_ERR" "ERROR" "$C_BADB" "$RESET" "$EL"
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    printf '    %s%s%s\n' "$C_TEXT" "$line" "$RESET"
  done < <(tail -n 3 "$log" 2>/dev/null)
  printf '  %sfull log: %s%s\n' "$C_FILE" "$(home_disp "$log")" "$RESET"
  return 0
}

# ONE slow child, run under a live "<phase> (Ns)" ticker.
#   run_step <phase> <log> <command…>   → the command's exit status
# The child's stdout AND stderr go to <log> exactly as they did when these
# commands ran in the foreground; only the parent paints. Creation has no byte
# stream to measure, so the ticker says what is happening and how long it has
# been happening rather than pretending to know a percentage.
#
# Poll at 4 Hz, repaint at 1 Hz: the repaint rate is what the reader wants, the
# poll rate is how quickly the [OK] lands once the child is done. A step that
# finishes inside the first second never paints a frame at all — the completion
# simply overwrites the line status_start opened.
run_step() {   # phase log command...
  local phase=$1 log=$2 pid rc=0 t0 el shown=-1 col
  shift 2
  if [[ -z $CR ]]; then
    # --plain: announce the phase on its own line, no ticker. Same column as
    # the repainting mode uses, so the two read alike.
    col=$(tick_col "$phase" "")
    if [[ $STATUS_OPEN -eq 1 ]]; then
      # status_start already padded to that column: the phase lands on it.
      printf '%s%s%s\n' "$C_SVC" "$phase" "$RESET"
      STATUS_OPEN=0
    else
      printf '  %s%-*s%s%s%s%s\n' "$C_TEXT" "$col" "$STATUS_NAME" "$RESET" \
        "$C_SVC" "$phase" "$RESET"
    fi
    "$@" >>"$log" 2>&1 || rc=$?
    return $rc
  fi
  "$@" >>"$log" 2>&1 &
  pid=$!
  t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    el=$(( SECONDS - t0 ))
    if [[ $el -gt $shown ]]; then
      shown=$el
      col=$(tick_col "$phase" "$el")
      printf '%s  %s%-*s%s%s%s (%ss)%s' "$CR" "$C_TEXT" "$col" "$STATUS_NAME" \
        "$RESET" "$C_SVC" "$phase" "$el" "$EL"
    fi
    sleep 0.25
  done
  wait "$pid" || rc=$?
  return $rc
}

# Per-step capture file under the resource path (whose stated purpose is
# "(re)creation records, logs, & data"). Falls back to the temp dir if that
# directory cannot be made, so a failed pull still has somewhere to say why.
step_log() {   # step name → path
  local d=$EMIT_DIR/logs
  mkdir -p "$d" 2>/dev/null || d=${TMPDIR:-/tmp}
  printf '%s/%s-%s.log' "$d" "$1" "$2"
}

# ── Image pull: podman REST API + one aggregated progress bar ────────────────
# `podman pull` draws its per-layer bars only on a tty, so ANY capture or filter
# of the CLI destroys exactly the progress that matters on multi-GB ROCm layers
# (and the old `grep -Ev 'skipped: already exists'` filter matched the tty
# wording, which is not what a piped pull emits — so it dropped nothing while
# silencing everything). The API reports byte counts regardless of tty: bring up
# a transient service, POST the Docker-compat /images/create, and aggregate the
# JSON stream into ONE line per image.
PULL_SOCK=""
PULL_SVC_PID=""

pull_service_stop() {
  [[ -n $PULL_SVC_PID ]] && kill "$PULL_SVC_PID" 2>/dev/null
  [[ -n $PULL_SOCK ]] && rm -f "$PULL_SOCK" 2>/dev/null
  PULL_SVC_PID="" PULL_SOCK=""
  return 0
}

# Unique socket per run, in the runtime dir (never /tmp when we can help it).
pull_service_start() {   # log → 0 once the socket is live
  local log=$1 i
  PULL_SOCK=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/droste-pull-$$.sock
  rm -f "$PULL_SOCK" 2>/dev/null || :
  "${RUNTIME:-podman}" system service --time=0 "unix://$PULL_SOCK" >>"$log" 2>&1 &
  PULL_SVC_PID=$!
  trap pull_service_stop EXIT
  for (( i = 0; i < 100; i = i + 1 )); do
    [[ -S $PULL_SOCK ]] && return 0
    # A service that died says so above this line, in its own words.
    if ! kill -0 "$PULL_SVC_PID" 2>/dev/null; then
      printf 'the API service exited before creating %s\n' "$PULL_SOCK" >>"$log"
      pull_service_stop
      return 1
    fi
    sleep 0.1
  done
  printf 'no API socket at %s after 10s\n' "$PULL_SOCK" >>"$log"
  pull_service_stop
  return 1
}

# The aggregator. Reads the /images/create JSON stream on stdin, sums every
# layer's progressDetail, and repaints ONE line; cached ("Already exists")
# layers count as complete and print nothing of their own. It leaves the cursor
# on that line WITHOUT a newline — the caller's status line overwrites it.
_pull_progress_py() {
  cat <<'PY'
import json, sys, time

label, width, fill, empty, plain = sys.argv[1:6]
width = int(width)
quiet = plain == "1"
out = sys.stdout

layers = {}                                    # id -> [current, total]
state = {"seen": False, "last": 0.0, "extract": set()}
dec = json.JSONDecoder()


def sizes(cur, tot):
    for unit, div in (("GB", 1 << 30), ("MB", 1 << 20)):
        if tot >= div:
            return "%.1f/%.1f %s" % (cur / float(div), tot / float(div), unit)
    return "%.0f/%.0f KB" % (cur / 1024.0, tot / 1024.0)


def paint(final=False):
    if quiet:
        return
    now = time.time()
    if not final and now - state["last"] < 0.1:
        return
    state["last"] = now
    cur = sum(v[0] for v in layers.values())
    tot = sum(v[1] for v in layers.values())
    if final:
        pct = 100
    elif tot:
        pct = min(100, int(cur * 100 // tot))
    else:
        pct = 0
    if state["extract"] and (not tot or cur >= tot):
        tail = "  %3d%%  extracting" % pct
    elif tot:
        tail = "  %3d%%  %s" % (pct, sizes(cur, tot))
    else:
        tail = "  %3d%%" % pct           # every layer cached: no bytes to count
    # The tail is padded to a fixed width so the bar cannot change length
    # mid-download (the size text grows by a digit as it climbs).
    tail = tail.ljust(20)
    room = width - 4 - len(label) - len(tail)
    if room >= 8:
        n = min(room, 40)
        done = n * pct // 100
        line = "  %s  %s%s" % (label, fill * done + empty * (n - done), tail)
    else:
        line = "  %s%s" % (label, tail)
    out.write("\r" + line + "\x1b[K")
    out.flush()


def handle(o):
    state["seen"] = True
    if o.get("error") or o.get("errorDetail"):
        msg = o.get("error") or (o.get("errorDetail") or {}).get("message")
        sys.stderr.write("pull API: %s\n" % (msg or "unknown error"))
        sys.exit(1)
    st = o.get("status") or ""
    lid = o.get("id") or ""
    if not lid:
        return
    pd = o.get("progressDetail") or {}
    if st.startswith("Already exists"):
        layers.setdefault(lid, [0, 0])
    elif st.startswith("Downloading"):
        layers[lid] = [int(pd.get("current") or 0), int(pd.get("total") or 0)]
    elif st.startswith("Download complete") or st.startswith("Pull complete"):
        if lid in layers:
            layers[lid][0] = layers[lid][1]
        state["extract"].discard(lid)
    elif st.startswith("Extracting"):
        state["extract"].add(lid)
    paint()


buf = ""
for chunk in sys.stdin:
    buf += chunk
    while True:
        buf = buf.lstrip()
        if not buf:
            break
        try:
            obj, idx = dec.raw_decode(buf)
        except ValueError:
            break
        buf = buf[idx:]
        handle(obj)

if not state["seen"]:
    sys.stderr.write("pull API: no progress stream received\n")
    sys.exit(1)
paint(final=True)
PY
}

pull_image() {   # box → 0 on success (draws the bar; caller draws the status)
  local box=$1 img repo tag log rc=0
  img="${IMAGE_PREFIX}${box}${IMAGE_SUFFIX}"
  repo=${img%:*} tag=${img##*:}
  log=$(step_log pull "$box")
  : > "$log"
  # -N (--no-buffer): without it curl hands the JSON stream over in ~16 KB
  # blocks, so the aggregator below repaints in lurches no matter how often the
  # API reports. It is the whole "the bar only moves every few seconds" fix.
  curl -fsS -N --unix-socket "$PULL_SOCK" -X POST \
       "http://d/v1.40/images/create?fromImage=$repo&tag=$tag" 2>>"$log" \
    | python3 -c "$(_pull_progress_py)" \
        "$img..." "$(disp_width)" "$BAR_F" "$BAR_E" "$PLAIN" 2>>"$log" \
    || rc=$?
  return $rc
}

# ── Execution (the ladder rungs) ─────────────────────────────────────────────
create_box() {  # box
  local box=$1 name log rc=0 src=0
  name=$(box_ctr "$box")
  log=$(step_log create "$name")
  : > "$log"
  status_start "$name..."
  if [[ $HAVE_DISTROBOX -eq 0 ]]; then
    printf 'distrobox is not installed, so %s cannot be created\n' "$name" >>"$log"
    printf 'install it (https://distrobox.it) and re-run droste-setup.sh\n' >>"$log"
    status_err "$name..." "$log"
    return 0
  fi
  # Container replacement belongs to the LADDER, not to K/m/r (Jei s34): if you
  # asked for a box to be created, you get a FRESH one — kept settings included.
  # Only the merged name is touched; pre-merge -server/-box containers are the
  # user's to clean up (Jei: "I'm the only one using 'em"). Tearing down a
  # RUNNING box is the slow case Jei hit on hardware, hence its own phase word.
  run_step "removing old" "$log" distrobox rm -f "$name" || :
  # distrobox narrates its own creation ("Creating '<name>' using image ...",
  # "Distrobox '<name>' successfully created.", "To enter, run:") — three lines
  # per box that say what our one status line already says, so the whole
  # capture goes to the log instead.
  run_step "creating" "$log" \
    distrobox assemble create --file "$(ini_file "$box")" || rc=$?
  if [[ $rc -eq 0 ]]; then
    SESSION_STATE[$box]=STOPPED
    # The [A] rung starts only the boxes whose server is meant to come up with
    # the box (Jei's rev-2 semantics): starting a SERVE=0 box would just be an
    # idle container. `podman start` is what replays the init line, which is
    # what launches the service — there is no separate server container.
    if [[ $RUNG == a && -n "${CFG_BOXSV[$box]:-}" && -n $RUNTIME ]]; then
      src=0
      run_step "starting" "$log" "$RUNTIME" start "$name" || src=$?
      if [[ $src -eq 0 ]]; then SESSION_STATE[$box]=ACTIVE; else rc=1; fi
    fi
  fi
  if [[ $rc -eq 0 ]]; then status_ok "$name..."; else status_err "$name..." "$log"; fi
  return 0
}

# One box's host-boot enablement (or its removal). Returns non-zero when the
# unit could not be put in the state the user asked for.
host_unit_step() {  # box log → 0 ok
  local box=$1 log=$2 unit rc=0
  unit=$(unit_name "$box")
  if [[ -n "${CFG_HSTSV[$box]:-}" ]]; then
    write_host_unit "$box" || { printf 'could not write %s\n' "$(unit_file "$box")" >>"$log"; return 1; }
    systemctl --user daemon-reload >>"$log" 2>&1 || rc=1
    systemctl --user enable "$unit" >>"$log" 2>&1 || rc=1
  else
    # Reconfigured to "no": disable it and take the file away, so a stale unit
    # cannot keep starting a box the user just told us not to start.
    [[ -f $(unit_file "$box") ]] || return 0
    systemctl --user disable "$unit" >>"$log" 2>&1 || rc=1
    systemctl --user daemon-reload >>"$log" 2>&1 || rc=1
    rm -f "$(unit_file "$box")" 2>>"$log" || rc=1
  fi
  return $rc
}

# The Executing group that owns boot auto-start: lingering first (nothing under
# it survives a logout without it), then one status line per unit.
host_boot_units() {  # box...
  local box log rc=0 want=0
  local -a boxes=("$@")
  [[ ${#boxes[@]} -gt 0 ]] || return 0
  for box in "${boxes[@]}"; do
    [[ -n "${CFG_HSTSV[$box]:-}" ]] && want=1
  done
  exec_hdr "Host Boot Services"
  if ! command -v systemctl >/dev/null 2>&1; then
    printf '  %ssystemctl not found — cannot manage boot auto-start.%s\n' "$C_TEXT" "$RESET"
    return 0
  fi
  if [[ $want -eq 1 ]]; then
    log=$(step_log linger user)
    : > "$log"
    status_start "loginctl enable-linger..."
    if enable_linger "$log"; then
      status_ok "loginctl enable-linger..."
    else
      status_err "loginctl enable-linger..." "$log"
      linger_fallback_note
    fi
  fi
  for box in "${boxes[@]}"; do
    log=$(step_log unit "$box")
    : > "$log"
    status_start "$(unit_name "$box")..."
    rc=0
    host_unit_step "$box" "$log" || rc=$?
    if [[ $rc -eq 0 ]]; then
      status_ok "$(unit_name "$box")..."
    else
      status_err "$(unit_name "$box")..." "$log"
    fi
  done
  return 0
}

execute() {
  local box b ladder=() units=() all_names=() svc_log rc=0
  section "Executing"
  # Ladder acts on (re)configured boxes AND kept boxes (kept = pull/create/
  # start from their existing, un-rewritten definitions), in canonical order.
  for b in "${BOXES[@]}"; do
    for box in "${CONFIGURE[@]}" "${KEEP[@]}"; do
      [[ $box == "$b" ]] && { ladder+=("$b"); break; }
    done
  done
  # Emit definitions ONLY for (re)configured boxes — kept boxes are never
  # rewritten (never-clobber). server.env rides along, unlisted (see
  # emit_serve_env): it holds the same answers, in the box's own data dir.
  if [[ ${#CONFIGURE[@]} -gt 0 ]]; then
    exec_hdr "Writing Configuration Files"
    for box in "${CONFIGURE[@]}"; do
      emit_ini "$box"
      emit_serve_env "$box"
    done
  fi
  # Boot auto-start is settled at EVERY rung, not just create: it is an answer
  # the user gave, the dashboard reports it as fact, and systemd is happy to
  # enable a unit whose container does not exist yet (the box is created by a
  # later run, or by hand from the ini). A (re)configured box needs a step when
  # it asked for host boot — or when it has a unit from a previous run and just
  # asked NOT to.
  for box in "${CONFIGURE[@]}"; do
    if [[ -n "${CFG_HSTSV[$box]:-}" || -f $(unit_file "$box") ]]; then
      units+=("$box")
    fi
  done
  # ONE column for the whole section: every status line the run will print is
  # measured before the first of them is drawn.
  if [[ ${#ladder[@]} -gt 0 ]]; then
    for box in "${ladder[@]}"; do
      [[ $RUNG != w ]] && all_names+=("${IMAGE_PREFIX}${box}${IMAGE_SUFFIX}...")
      [[ $RUNG == c || $RUNG == a ]] && all_names+=("$(box_ctr "$box")...")
    done
    for box in ${units[@]+"${units[@]}"}; do
      all_names+=("$(unit_name "$box")...")
    done
    [[ ${#units[@]} -gt 0 ]] && all_names+=("loginctl enable-linger...")
    [[ ${#all_names[@]} -gt 0 ]] && status_width "${all_names[@]}"
  fi
  if [[ $RUNG != w && ${#ladder[@]} -gt 0 ]]; then
    exec_hdr "Pulling Images"
    svc_log=$(step_log pull service)
    : > "$svc_log"
    # The API service is the pull mechanism, not an optimisation: if it will not
    # start, that is an error like any other (same binary, user, and storage as
    # the CLI), reported once — the per-image lines would all say the same thing.
    if pull_service_start "$svc_log"; then
      for box in "${ladder[@]}"; do
        rc=0
        # The line opens BEFORE the request: the registry can take seconds to
        # answer, and until it does the aggregator has nothing to paint.
        status_start "${IMAGE_PREFIX}${box}${IMAGE_SUFFIX}..."
        pull_image "$box" || rc=$?
        if [[ $rc -eq 0 ]]; then
          status_ok "${IMAGE_PREFIX}${box}${IMAGE_SUFFIX}..."
        else
          status_err "${IMAGE_PREFIX}${box}${IMAGE_SUFFIX}..." "$(step_log pull "$box")"
        fi
      done
      pull_service_stop
    else
      status_start "${RUNTIME:-podman} system service..."
      status_err "${RUNTIME:-podman} system service..." "$svc_log"
    fi
  fi
  if [[ ( $RUNG == c || $RUNG == a ) && ${#ladder[@]} -gt 0 ]]; then
    exec_hdr "Creating Boxes"
    for box in "${ladder[@]}"; do
      create_box "$box"
    done
  fi
  host_boot_units ${units[@]+"${units[@]}"}
  return 0
}

# ── NOTES.md ─────────────────────────────────────────────────────────────────
# The whole function writes MARKDOWN: single-quoted printf formats full of
# backticks (code spans) and literal $VARs the reader is meant to see. Not
# expanding them is the point, so SC2016 is silenced for the block rather than
# line by line.
# shellcheck disable=SC2016
write_notes() {
  local f=$EMIT_DIR/NOTES.md box port bs hs data note
  {
    printf '# droste-halo setup notes\n\n'
    printf 'Generated by droste-setup.sh on %s. Re-run droste-setup.sh any time —\n' \
      "$(date +%F)"
    printf 'existing boxes are detected and never clobbered.\n\n'
    printf '## One container, two doors\n\n'
    printf 'Each box is ONE podman container, `droste-<box>-halo`, created by\n'
    printf '`distrobox assemble` from its `<box>-halo.ini`:\n\n'
    printf -- '- **Interactive door** — `distrobox enter droste-<box>-halo`.\n'
    printf '  A shell in your own $HOME, with the box%s toolchain.\n' "'s"
    printf -- '- **Server door** — `podman start droste-<box>-halo`. Starting the\n'
    printf '  container replays its init line, which reads `server.env` from the\n'
    printf '  box%s data dir and launches the service on the port recorded there.\n' "'s"
    printf '\nEntering a stopped box therefore starts it — and, if `SERVE=1`, its\n'
    printf 'service with it. Both doors are the SAME environment: a `pip install`\n'
    printf 'you do interactively is what the served process runs.\n'
    printf '\n## Your installation\n\n'
    printf '| Box | Start w Box | Start w Host | Port | Data dir |\n'
    printf '|---|---|---|---|---|\n'
    for box in "${SELECTED[@]}"; do
      port=$(box_port_disp "$box")
      bs=$(yn_word "$(box_boxsv "$box")")
      hs=$(yn_word "$(box_hstsv "$box")")
      data="${PATHS["$box:data"]:-${EXD_PATH["$box:data"]:-?}}"
      printf '| %s | %s | %s | %s | %s |\n' "$box" "$bs" "$hs" "$port" "$data"
    done
    printf '\nShared HF cache: `%s` — bound into every box; the SINGLE model\n' \
      "$HF_CACHE"
    printf 'store (a model one box downloads is available to all the others).\n'
    if [[ -n $MODELS_DIR ]]; then
      printf 'Local model collection: `%s` — bound read-only at `/opt/models`\n' \
        "$MODELS_DIR"
      printf 'in every box that supports it (comfyui/llama/vllm/ds4). The dir was\n'
      printf 'confirmed-or-created at setup time, so the bind is safe and already\n'
      printf 'present in the single `volume=` value of each ini.\n'
    else
      printf 'Local model collection: not configured (/opt/models unbound).\n'
    fi
    printf 'Shared compute cache: %s — bound at /opt/caches in every\n' \
      "\`$COMPUTE_CACHE\`"
    printf 'box (MIOpen/Triton/torch/vLLM kernels; safe to share — content is\n'
    printf 'keyed by version/arch). ONE caveat: avoid heavy simultaneous\n'
    printf 'first-run MIOpen tuning in two boxes at once; everything else\n'
    printf 'is conflict-free.\n'
    printf '\n## Day-to-day commands\n\n'
    printf '    podman start <name>        # start the box (+ its server)\n'
    printf '    podman stop <name>         # stop it\n'
    printf '    podman logs -f <name>      # follow its log\n'
    printf '    podman ps                  # STATUS shows the healthcheck\n'
    printf '    distrobox enter <name>     # interactive shell in the box\n\n'
    printf 'Names:\n'
    for box in "${SELECTED[@]}"; do
      printf '  %s\n' "$(box_ctr "$box")"
    done
    printf '\n## The serve switch (server.env)\n\n'
    printf 'Every box reads `<data dir>/server.env` at EVERY start:\n\n'
    printf '    SERVE=1        # 0 = interactive only, nothing is launched\n'
    printf '    PORT=8188      # the port the service binds (host networking)\n\n'
    printf 'Edit it and `podman restart <name>` — no recreate needed, and the\n'
    printf 'file survives image updates and box recreation. droste-setup.sh writes\n'
    printf 'it from your answers for every box it (re)configures, and leaves it\n'
    printf 'alone for boxes you asked to KEEP.\n'
    printf '\n## Supervision (podman healthcheck)\n\n'
    printf 'Each box is created with a healthcheck that probes its service from\n'
    printf 'inside (`--health-on-failure=restart`), so a wedged or crashed server\n'
    printf 'restarts the container, which relaunches it. A box with `SERVE=0`\n'
    printf 'always reports healthy — the probe knows it is not meant to serve.\n\n'
    printf 'The START PERIOD is generous on purpose (these services answer\n'
    printf 'nothing while they load multi-GB weights; llama even answers 503):\n\n'
    for box in "${SELECTED[@]}"; do
      printf '    %-12s %s\n' "$box" "${BOX_HEALTH_START[$box]}"
    done
    printf '\nInspect it with `podman inspect --format "{{json .State.Health}}"`.\n'
    printf '\n## Stopping: what actually happens\n\n'
    printf 'The box%s pid 1 is distrobox-init, which does NOT forward SIGTERM to\n' "'s"
    printf 'the served process: on `podman stop`/`restart` the service is killed\n'
    printf 'rather than asked to exit (a `--stop-timeout %s` is set as a ceiling).\n' \
      "$STOP_TIMEOUT"
    printf 'Nothing in these images buffers state that a clean shutdown would\n'
    printf 'flush, but if you want a graceful exit, stop the service inside the\n'
    printf 'box first (or edit `SERVE=0` and restart).\n'
    printf '\n## Per-box quickstart\n'
    for box in "${SELECTED[@]}"; do
      data="${PATHS["$box:data"]:-${EXD_PATH["$box:data"]:-<data-dir>}}"
      port=$(box_port_disp "$box")
      printf '\n### %s — %s\n\n' "$box" "${BOX_PITCH[$box]}"
      case "$box" in
        comfyui)
          printf -- '- Web UI: http://localhost:%s.\n' "$port"
          printf -- '- Models are scanned from the shared HF cache (+ /opt/models)\n'
          printf '  at every start; new downloads appear in the pickers.\n'
          printf -- '- Your work dirs: input `%s`, output `%s`.\n' \
            "${PATHS["$box:input"]:-${EXD_PATH["$box:input"]:-?}}" \
            "${PATHS["$box:output"]:-${EXD_PATH["$box:output"]:-?}}"
          ;;
        llama)
          printf -- '- BEFORE first use: edit `%s/llama.env` and set\n' "$data"
          printf '  `LLAMA_ARG_MODEL` (a GGUF path, or use `-hf org/repo` via\n'
          printf '  `LLAMA_EXTRA_ARGS`). The file is seeded at first start.\n'
          printf -- '- API: http://localhost:%s (llama-server).\n' "$port"
          ;;
        vllm)
          printf -- '- BEFORE first use: edit `%s/vllm_config.yaml` and set\n' "$data"
          printf '  `model:` (HF repo id or /opt/models path). Seeded at first start.\n'
          printf -- '- OpenAI-compatible API: http://localhost:%s/v1.\n' "$port"
          ;;
        ds4)
          printf -- '- BEFORE first use: edit `%s/ds4.env` and set\n' "$data"
          printf '  `DS4_DROSTE_MODEL` (GGUF path). Seeded at first start.\n'
          printf -- '- API: http://localhost:%s (ds4-server).\n' "$port"
          ;;
        finetuning)
          printf -- '- JupyterLab: http://localhost:%s — get the login token with\n' \
            "$port"
          printf '    podman logs %s\n' "$(box_ctr finetuning)"
          printf -- '- Notebooks + trained adapters live in your workspace:\n'
          printf '  `%s`.\n' \
            "${PATHS["$box:workspace"]:-${EXD_PATH["$box:workspace"]:-?}}"
          ;;
      esac
    done
    printf '\n## Recreate one-liners\n\n'
    for box in "${SELECTED[@]}"; do
      if [[ -f $(ini_file "$box") ]]; then
        printf '    distrobox assemble create --file %s\n' "$(ini_file "$box")"
      fi
    done
    printf '\nRecreating replaces the container; your data dir, server.env and\n'
    printf 'the in-box overlays under it are untouched — that is what makes\n'
    printf 'in-box installs (pip packages, custom nodes) survive a recreate.\n'
    printf '\n## Start at host boot\n\n'
    printf 'Boxes you asked to start at host boot get a systemd USER unit:\n\n'
    printf '    systemctl --user status droste-<box>      # is it enabled/active\n'
    printf '    systemctl --user disable droste-<box>     # stop starting at boot\n\n'
    printf 'The unit is a oneshot doing `podman start droste-<box>-halo`. Rootless\n'
    printf 'user services (and podman%s healthcheck timers) need LINGERING, or the\n' "'s"
    printf 'user manager exits at logout and takes both with it:\n\n'
    printf '    loginctl enable-linger %s\n\n' "${USER:-$(id -un)}"
    printf 'droste-setup.sh enables it for you when a box asks for host boot (no\n'
    printf 'sudo needed in a local session); prefix with `sudo` if it refused.\n'
    printf '\n## Shared model store\n\n'
    printf 'Every box binds `%s`. Download once, use everywhere:\n\n' "$HF_CACHE"
    printf '    hf download <org>/<repo>       # or: huggingface-cli download\n\n'
    printf 'ComfyUI re-scans the cache at each start (symlink model tree).\n'
    printf '\n## Installer choices (record)\n\n'
    printf -- '- Date: %s; emit dir: `%s`; runtime: %s%s.\n' \
      "$(date +%F)" "$EMIT_DIR" "${RUNTIME:-none}" \
      "$([[ $ROOTLESS -eq 1 ]] && echo ' (rootless)')"
    for box in "${CONFIGURE[@]}"; do
      note=""
      case "${CFG_MODE[$box]:-}" in
        fuse) note="fs=${CFG_FS[$box]} → DROSTE_OVERLAY_MODE=fuse + /dev/fuse" ;;
        copy) note="fs=${CFG_FS[$box]} → DROSTE_OVERLAY_MODE=copy" ;;
        ignore) note="fs=${CFG_FS[$box]} → IGNORED (box will fail on start!)" ;;
        *) note="fs=${CFG_FS[$box]:-?} (kernel overlayfs OK)" ;;
      esac
      printf -- '- %s: port=%s, box-start=%s, host-boot=%s, data=`%s`, %s.%s\n' \
        "$box" "${CFG_PORT[$box]}" "$(yn_word "${CFG_BOXSV[$box]:-}")" \
        "$(yn_word "${CFG_HSTSV[$box]:-}")" "${PATHS["$box:data"]}" "$note" \
        "$([[ -n ${BOX_CONFIG[$box]} ]] \
           && printf ' Seeded config: %s.' "${BOX_CONFIG[$box]}")"
    done
    printf '\nEscape hatch: `-e ALLOW_EPHEMERAL=1` downgrades missing-critical-\n'
    printf 'bind errors to warnings (NOT recommended — data will not persist).\n'
    printf '\n## Health check\n\n'
    printf 'On the GPU host, the repo'\''s `scaffolding/check-rocm.sh` validates\n'
    printf 'GPU access + per-box smoke across all images (see its --help).\n'
  } > "$f"
  # Jei's "---" is deliberate: a plain rule that says "that part is done",
  # closing the run's chattiest phase before the final report opens below.
  printf '\n%s---%s\n%sWrote %s.%s\n' \
    "$C_TEXT" "$RESET" "$C_FILE" "$(home_disp "$f")" "$RESET"
  return 0
}

# ── Status dashboard ─────────────────────────────────────────────────────────
box_port_disp() {
  local box=$1
  printf '%s' "${CFG_PORT[$box]:-${EXD_PORT[$box]:--}}"
}
# The two toggles, from this run's answers when there are any (configured or
# hydrated-keep boxes both have them) and from detection otherwise.
box_boxsv() {
  local box=$1
  if [[ -n "${CFG_PORT[$box]:-}" ]]; then printf '%s' "${CFG_BOXSV[$box]:-}"
  else printf '%s' "${EXD_BOXSV[$box]:-}"; fi
}
box_hstsv() {
  local box=$1
  if [[ -n "${CFG_PORT[$box]:-}" ]]; then printf '%s' "${CFG_HSTSV[$box]:-}"
  else printf '%s' "${EXD_HSTSV[$box]:-}"; fi
}

box_state() {  # box → ACTIVE|STOPPED|none|UNKNOWN
  local box=$1 state="" asked=0
  if [[ -n $RUNTIME ]]; then
    # Distinguish "asked, nothing there" from "could not ask": with no runtime, or
    # a query that errored, `none` would claim the box does not exist when the
    # truth is we have no way to tell. Only a successful query earns `none`.
    if state=$("$RUNTIME" ps -a --filter "name=^$(box_ctr "$box")\$" \
               --format '{{.State}}' 2>/dev/null | head -n1); then
      asked=1
    else
      state=""
    fi
  fi
  if [[ -z $state ]]; then
    if [[ -n "${SESSION_STATE[$box]:-}" ]]; then
      printf '%s' "${SESSION_STATE[$box]}"
    elif [[ -n "${EX_CTR[$box]:-}" ]]; then
      [[ ${EX_CTR[$box]} == running ]] && printf 'ACTIVE' || printf 'STOPPED'
    elif [[ $asked -eq 1 ]]; then
      printf 'none'
    else
      printf 'UNKNOWN'
    fi
  else
    [[ $state == running ]] && printf 'ACTIVE' || printf 'STOPPED'
  fi
}

# The table geometry:
#
#   Service     On  BoxSv  HstSv  Port  Important Notes
#   col 0       12  16     23     30    36
#
# The host key is HstSv in BOTH tails (Jei): at five characters it leaves the
# header field's two trailing spaces intact, so Port is never crowded — the
# six-character spelling ate one of them and read as a collision.
#
# A pull-and-write run drops the [On] cell (no container exists to report on).
# Its remaining columns are NOT the full layout minus a constant: the glyph
# columns of each layout are hand-tuned (see dash_table) because "centred under
# that header" is an eye judgement about double-width glyphs, not arithmetic.
# Only the Notes column is responsive; everything left of it is fixed so the
# columns line up between runs.
DASH_HOST_KEY="HstSv"

# ── Final-report blocks (shared by the pull-and-write tail and the full one) ─
# NOTHING here breaks a line by hand. The two hard breaks that used to live in
# this section (the Legend's host-boot key and the Shortcuts'
# "(stop to stop)") were transcription artifacts of a 60-column mockup, and they
# broke every terminal wide enough not to need it — the rows below all fit 80.
#
# dash_legend / dash_table — ONE code path each, for both tails. A
# pull-and-write run has no [On] cell (no container exists whose state it could
# report); that is a single optional segment in each, plus the layout's own
# column table. The CODE is shared; only the numbers differ.
dash_legend() {   # with-on(0|1)
  local on=$1 hl=$DASH_HOST_KEY onkey="" plain
  hdr "Legend"
  [[ $on -eq 1 ]] && onkey="[$C_SUBJ""On$C_TEXT] Running?  "
  # The keys ride ONE line when the drawn width can hold them, and stack onto a
  # second when it cannot — the layout Jei's phone-narrow mockup showed. The
  # measurement is of the PLAIN text: escape bytes occupy no columns.
  plain="Server  "
  [[ $on -eq 1 ]] && plain+="[On] Running?  "
  plain+="[BoxSv] Start with Box  [$hl] Start at Host Boot"
  if [[ ${#plain} -gt $(disp_width) ]]; then
    printf '%sServer  %s[%s%s%s] Start with Box%s\n' \
      "$C_TEXT" "$onkey" "$C_SUBJ" "BoxSv" "$C_TEXT" "$RESET"
    printf '%s        [%s%s%s] Start at Host Boot%s\n' \
      "$C_TEXT" "$C_SUBJ" "$hl" "$C_TEXT" "$RESET"
  else
    printf '%sServer  %s[%s%s%s] Start with Box  [%s%s%s] Start at Host Boot%s\n' \
      "$C_TEXT" "$onkey" "$C_SUBJ" "BoxSv" "$C_TEXT" "$C_SUBJ" "$hl" "$C_TEXT" "$RESET"
  fi
  # The values ride their own column table (below): tokens on one set of
  # columns, words on another.
  if [[ $on -eq 1 ]]; then
    dash_values "8 25 49" "13 31 55"
  else
    dash_values "10 34 60" "16 40 65"
  fi
  return 0
}

# The Legend's value row. ONE builder, a column table per layout — hand-tuned
# from Jei's drawings, because where a double-width glyph "looks right" under a
# word is an eye judgement. Padding to ABSOLUTE columns is what lets the same
# table serve both cell widths: the 3-column [Y] of --plain eats one column of
# the gap that follows it, so every WORD still lands where the emoji put it.
dash_values() {   # "tok tok tok" "word word word"
  local -a vtok=() vlab=() vg=("$GS_YES" "$GS_NO" "$GS_NA")
  local -a vw=("yes" "no" "NA / unknown")
  local i n row dw=5
  read -r -a vtok <<<"$1"
  read -r -a vlab <<<"$2"
  row=$C_TEXT"Value"
  for (( i = 0; i < 3; i = i + 1 )); do
    n=$(( vtok[i] - dw )); [[ $n -lt 0 ]] && n=0
    row+=$(printf '%*s' "$n" "")$GB_L$C_GLYPH${vg[i]}$C_TEXT$GB_R
    dw=$(( vtok[i] + ${#GB_L} + W_STATE + ${#GB_R} ))
    n=$(( vlab[i] - dw )); [[ $n -lt 0 ]] && n=0
    row+=$(printf '%*s' "$n" "")${vw[i]}
    dw=$(( vlab[i] + ${#vw[i]} ))
  done
  printf '%s%s\n' "$row" "$RESET"
  return 0
}

dash_table() {   # with-on(0|1)
  local on=$1 hl=$DASH_HOST_KEY box st stg g note data row port budget head
  local -a gcol=() glyph=()
  local pcol ncol i n dw
  # HAND-TUNED GLYPH COLUMNS, one set per layout (Jei): a centering FORMULA
  # cannot be right here — the glyphs are double-width, the ASCII fallback is
  # not, and "looks centred under that header" is an eye judgement, not an
  # arithmetic one. These are the columns from his two drawings; the row builder
  # below pads to them absolutely, so both cell widths land in the same place.
  if [[ $on -eq 1 ]]; then
    # ...and per MODE for the middle column: [N] is a column wider than the
    # glyph, and at 18 it reads as crowding BoxSv's right edge.
    if [[ $PLAIN -eq 1 ]]; then gcol=(12 17 24); else gcol=(12 18 24); fi
    pcol=30; ncol=36
  else
    gcol=(13 20);    pcol=26; ncol=32
  fi
  budget=$(( $(disp_width) - ncol ))
  # Underline the WORDS only — the column padding stays plain.
  head=$(pad_cell_u "Service" 7 12)
  [[ $on -eq 1 ]] && head+=$(pad_cell_u "On" 2 4)
  head+=$(pad_cell_u "BoxSv" 5 7)$(pad_cell_u "$hl" ${#hl} 7)$(pad_cell_u "Port" 4 6)
  printf '%s%s%s%s\n' "$head" "$C_HDR" "Important Notes" "$RESET"
  for box in "${SELECTED[@]}"; do
    glyph=()
    if [[ $on -eq 1 ]]; then
      st=$(box_state "$box")
      case "$st" in
        ACTIVE)  stg=$GS_YES ;;
        STOPPED) stg=$GS_NO ;;
        # `none` and UNKNOWN both render ⚫: "not there" and "could not ask" look
        # the same to the reader, and box_state keeps the distinction internally.
        *)       stg=$GS_NA ;;
      esac
      glyph+=("$stg")
    fi
    [[ -n "$(box_boxsv "$box")" ]] && g=$GS_YES || g=$GS_NO
    glyph+=("$g")
    [[ -n "$(box_hstsv "$box")" ]] && g=$GS_YES || g=$GS_NO
    glyph+=("$g")
    # Pad to each column ABSOLUTELY, tracking the display width written so far —
    # which is the only way one set of columns can serve a 2-column glyph and a
    # 3-column [Y] alike.
    row=$C_SVC$(pad_cell "$box" ${#box} 12)$C_GLYPH
    dw=12
    for (( i = 0; i < ${#gcol[@]}; i = i + 1 )); do
      n=$(( gcol[i] - dw )); [[ $n -lt 0 ]] && n=0
      row+=$(printf '%*s' "$n" "")${glyph[i]}
      dw=$(( gcol[i] + W_STATE ))
    done
    port=$(box_port_disp "$box")
    n=$(( pcol - dw )); [[ $n -lt 0 ]] && n=0
    row+=$(printf '%*s' "$n" "")$C_PORT$port
    dw=$(( pcol + ${#port} ))
    n=$(( ncol - dw )); [[ $n -lt 0 ]] && n=0
    row+=$(printf '%*s' "$n" "")
    data="${PATHS["$box:data"]:-${EXD_PATH["$box:data"]:-}}"
    note=${BOX_NOTE[$box]//@DATA@/$(home_disp "${data:-~/droste/$box/data}")}
    [[ -n $note ]] && row+=$C_TEXT$(fit_note "$note" "$budget")
    printf '%s%s\n' "$row" "$RESET"
  done
  return 0
}

# dash_shortcuts — the two doors. Label in body text; the command is decorated
# executable / verb / target, with the <box> you substitute picked out in blue.
# ONE container per box, so both doors take the SAME name.
dash_shortcuts() {
  hdr "Shortcuts"
  # "·<label:26><command>" plus the aside is 71 columns; when the drawn width
  # cannot hold that, the ASIDE (not the command — that is copy-paste payload)
  # moves under it, indented to the command column.
  if [[ 71 -gt $(disp_width) ]]; then
    printf '%s%s%-25s%s%s%s%s%s%s%s%s%s%s%s\n' "$C_TEXT" "$BULLET" \
      "Start/stop (background):" "$C_EXE" "podman " "$C_CMD" "start " \
      "$C_TGT" "droste-" "$C_PH" "<box>" "$C_TGT" "-halo" "$RESET"
    printf '%s%*s(%s%s%s%s%s)%s\n' "$C_TEXT" 26 "" \
      "$C_STOPW" "stop" "$C_STOPT" " to stop" "$C_TEXT" "$RESET"
  else
    printf '%s%s%-25s%s%s%s%s%s%s%s%s%s%s%s %s(%s%s%s%s%s)%s\n' "$C_TEXT" "$BULLET" \
      "Start/stop (background):" "$C_EXE" "podman " "$C_CMD" "start " \
      "$C_TGT" "droste-" "$C_PH" "<box>" "$C_TGT" "-halo" "$RESET" \
      "$C_TEXT" "$C_STOPW" "stop" "$C_STOPT" " to stop" "$C_TEXT" "$RESET"
  fi
  printf '%s%s%-25s%s%s%s%s%s%s%s%s%s%s%s\n' "$C_TEXT" "$BULLET" \
    "Enter (interactive):" "$C_EXE" "distrobox " "$C_CMD" "enter " \
    "$C_TGT" "droste-" "$C_PH" "<box>" "$C_TGT" "-halo" "$RESET"
  return 0
}

# The footnote every reporting tail ends on, above the pointer.
dash_footnote() {
  # The command at the end of the line is payload, so it wears the bold bright
  # blue of every other copy-me fragment rather than the footnote's italic.
  printf '%s%s%s%s%s%s\n' "$C_STAR" \
    "*ComfyUI models scanned at start; to add more run: " \
    "$RESET" "$C_PATHB" "hf download <shared cache>" "$RESET"
  return 0
}

# The one-liner that rebuilds a box from what this run wrote. TITLED BY THE
# CALLER: after a pull-and-write run the containers do not exist yet, so the
# command CREATES ("Create / Recreate"); in the full report it is the recovery
# move for containers that already exist ("Recreate"). Same block either way.
dash_recreate() {   # title
  printf '%s%s%s\n' "$C_SUB" "$1 (files in $(home_disp "$EMIT_DIR"))" "$RESET"
  printf '%s%s%-12s%s%s%s%s%s%s%s%s%s%s%s\n' "$C_TEXT" "$BULLET" "distrobox:" \
    "$C_EXE" "distrobox " "$C_CMD" "assemble create " \
    "$C_TGT" "--file " "$C_PH" "<box>" "$C_TGT" "-halo.ini" "$RESET"
  return 0
}

# The final pointer, the one line every run ends on.
dash_pointer() {
  printf '%s%s%s%s%s\n' "$C_ARROW" "$ARROW_G" "$C_TEXT" \
    "Definitions + full guide: $(home_disp "$EMIT_DIR") (ini, NOTES.md)" \
    "$RESET"
  say ""
  return 0
}

dashboard() {
  # WRITE-ONLY RUNS GET THE POINTER AND NOTHING ELSE (Jei, live test). Every
  # block below — Legend, the status table, Shortcuts, Recreate, the ComfyUI
  # footnote — reports on RUNTIME state: containers that exist, run, and serve.
  # Rung w created none of that, so all of it would be noise or, worse, a table
  # of dashes. The closing rule and "Wrote NOTES.md." are write_notes's, and
  # NOTES.md itself is still written in full — it is what the pointer points at.
  if [[ $RUNG == w ]]; then
    dash_pointer
    return 0
  fi
  # A PULL-AND-WRITE RUN gets an ADAPTED report (Jei's rev 2): images and
  # definitions exist, containers do not — so the [On] column goes (there is no
  # container whose state it could report) and the create one-liner comes BEFORE
  # the Shortcuts, because you must create a box before you can start it. The
  # BoxSv/HostSv glyphs are the settings this run just wrote.
  if [[ $RUNG == p ]]; then
    say ""
    dash_legend 0
    say ""
    dash_table 0
    say ""
    dash_recreate "Create / Recreate"
    say ""
    dash_shortcuts
    say ""
    dash_footnote
    dash_pointer
    return 0
  fi
  say ""
  dash_legend 1
  say ""
  dash_table 1
  say ""
  dash_shortcuts
  say ""
  # Here the containers DO exist, so the block keeps its original title.
  dash_recreate "Recreate"
  say ""
  dash_footnote
  dash_pointer
  return 0
}

# ── Main flow ────────────────────────────────────────────────────────────────
main() {
  init_input
  logo_header
  banner "Droste Installer for Halo Architectures"
  preflight
  quit_notice

  section "Box Selection & Setup" intro
  sub "Box configuration, settings, logs, & other resources" intro
  # A typo here fans out into every emitted file — ask_path_as confirms before
  # creating (and re-asks if the user declines or the create fails).
  ask_path_as "Identify a path for droste resource storage" "$HOME/droste"
  EMIT_DIR=$ANS_PATH
  DEFAULT_ROOT=$EMIT_DIR
  # The resource path is what makes the old definition files findable, so this
  # is the first moment they can be parsed at all.
  detect_existing
  detected_block
  select_boxes

  existing_settings
  # Which files may seed a default is a K/m/r question, so the seeding runs
  # here — after Box Options, before the first question it feeds.
  seed_globals

  if [[ ${#CONFIGURE[@]} -gt 0 || ${#KEEP[@]} -gt 0 ]]; then
    local box
    if [[ ${#CONFIGURE[@]} -gt 0 ]]; then
      general_setup
      # Every writable path chosen so far is known now, so the filesystem
      # question can be asked once, for the most primary of them.
      global_mitigation
      for box in "${CONFIGURE[@]}"; do
        configure_box "$box"
      done
    fi
    # Kept boxes: reuse their recorded config so the ladder can pull/create/
    # start them (e.g. a prior "write only" run) without rewriting anything.
    for box in "${KEEP[@]}"; do hydrate_keep "$box"; done
    if [[ ${#CONFIGURE[@]} -eq 0 ]]; then
      say ""
      printf '%sAll selected boxes kept as-is — definitions unchanged.%s\n' "$C_TEXT" "$RESET"
      printf '%sYou can still pull images / create / start them below.%s\n' "$C_TEXT" "$RESET"
    fi
    ask_ladder
    execute
    write_notes
    # (The per-box "To enter, run:" lines lived here; they duplicated the
    # Shortcuts block in the dashboard below, so they were dropped.)
  else
    say ""
    printf '%sNo boxes selected.%s\n' "$C_TEXT" "$RESET"
  fi

  dashboard
  return 0
}

main
