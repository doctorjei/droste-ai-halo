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
#                                     start: STARTUP_ENABLED=1/0 + PORT=<host port>)
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
  [data]="Program Data" [input]="Input" [output]="Output" [workspace]="Workspace"
)

# A bind whose prompt is written OUT, instead of composed as "Path for <Box>
# <bind title>". The program-cache dir is the case: what the answer places is a
# class of files (everything the installer may throw away), not a thing the box
# owns a name for, so the prompt says what lives there — Jei's s38 wording, one
# per box. Any label without an entry here keeps the composed shape.
declare -A BIND_PROMPT=(
  [pcache]="Please indicate the path for the program-specific caches"
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
  [comfyui]="comfyui.env"
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
# The image ref AS SHOWN to the reader: the same ref without its tag. The tag
# is hardcoded above — every pull this installer makes is :latest — so on
# screen it is seven columns that tell nobody anything, and those seven columns
# are the difference between the pull bar's header fitting its line and not.
# The PULL and the ini keep the tag: one has to name a tag, the other is the
# reference distrobox resolves.
img_disp() {   # box → <prefix><box>-halo
  printf '%s%s%s' "$IMAGE_PREFIX" "$1" "${IMAGE_SUFFIX%:*}"
}
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
# The probe also requires the box's OWN service to be the thing that is up (the
# state record droste-serve.sh writes at every start): under host networking a
# port these boxes did not open can answer the probe, and a box that refused to
# start a second listener on someone else's port used to report HEALTHY.
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
records (<box>-halo.ini + server.env) plus a NOTES.md, and can pull
images, create boxes, and start servers.

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
    -*) printf 'droste-setup.sh: unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    *) ARG_BOXES+=("$arg") ;;
  esac
done

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
  if [[ -n "${DROSTE_SETUP_INPUT:-}" ]]; then
    [[ -r "$DROSTE_SETUP_INPUT" ]] || die "cannot read DROSTE_SETUP_INPUT=$DROSTE_SETUP_INPUT"
    exec {ASK_FD}<"$DROSTE_SETUP_INPUT"
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
  printf '\n  %sExiting droste-setup.sh %s no further changes made.%s\n\n' \
    "$C_TEXT" "$EMD" "$RESET"
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
      subnote "Port $ANS is already assigned to $other $EMD pick another."
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
# EVERY PATH IN HERE IS HELD AS THE PERSON WHO CHOSE IT WROTE IT (s39): typed,
# read back out of their ini, or — for a placement the installer derived — in
# the spelling of the root it hangs off. Absolute or ~-rooted, never expanded;
# fs_path resolves at the filesystem boundary and the result is never kept.
declare -A PATHS             # "box:label" → host path, as spelled
declare -A EX_INI EX_CTR     # detection (1/"" ; EX_CTR = container state)
declare -A EXD_PATH          # "box:label" → host path from the old ini, as spelled
declare -A EXD_PORT EXD_BOXSV EXD_HSTSV EXD_MODE   # parsed defaults
declare -A SESSION_STATE     # box → ACTIVE|STOPPED (what this run did)
SELECTED=()                  # chosen boxes, canonical order
CONFIGURE=()                 # SELECTED minus keeps (definitions (re)generated)
KEEP=()                      # kept boxes (untouched files; ladder still offered)
HF_CACHE=""
# The box user's home AS THE CONTAINER SEES IT. distrobox mounts the real home
# out of /etc/passwd, which is not necessarily what $HOME is spelled as: a login
# through an aliased or symlinked home (HOME=/srv, passwd=/home/gopher) leaves
# the two different. Anything that names a path INSIDE the box has to use this
# one — $HOME there produced a container-side destination that does not exist,
# which silently unsatisfied the CRITICAL hf-cache bind and re-downloaded
# gigabytes into the container layer.
USER_HOME=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)
[[ -n $USER_HOME ]] || USER_HOME=$HOME
COMPUTE_CACHE=""             # shared MIOpen/Triton/torch/vLLM kernel cache
MODELS_DIR=""                # "" = not configured
EMIT_DIR=""
RUNG="w"                     # w|p|c|a

RUNTIME="" RUNTIME_BIN="" ROOTLESS=0 HAVE_DISTROBOX=0
LINGER=""                    # yes|no|"" (unknown) — user-manager lingering
PF_ME="" PF_UID=""           # this user's name + uid (subordinate-id lookups)
PF_STOP=0                    # 1 = preflight found something it must block on

# WHOSE SESSION IS THIS? `sudo -iu droste` / `su - droste` gives a shell that
# looks right and works for everything the installer does — until
# distrobox-assemble, which hard-refuses ("Running distrobox-assemble via
# SUDO/DOAS is not supported"). On a first run that refusal lands AFTER tens of
# GB of image have been pulled, so the check belongs here, at the top — and it
# is the one preflight row that stops the run.
pf_session() {
  local via="" who=""
  if [[ -n "${SUDO_USER:-}" ]]; then via=SUDO_USER who=$SUDO_USER
  elif [[ -n "${DOAS_USER:-}" ]]; then via=DOAS_USER who=$DOAS_USER
  fi
  if [[ -z $via ]]; then
    pf_ok "session belongs to $PF_ME (not sudo/su-derived)"
    return 0
  fi
  # $who is who reached for sudo; $PF_ME is who the boxes would belong to, and
  # therefore who has to be logged in for distrobox to accept the run.
  pf_bad "sudo/su-derived shell ($via=$who) $EMD distrobox will refuse it"
  pf_hint "and it refuses AFTER the pulls, so this run stops here instead"
  pf_hint "systemd: $(emph "machinectl shell $PF_ME@") (pkg systemd-container)"
  pf_hint "or $(emph "ssh $PF_ME@localhost") $EMD anything that is a real login"
  PF_STOP=1
  return 0
}

# ── Subordinate id ranges (the lchown EINVAL lesson) ─────────────────────────
# Rootless podman maps container uids/gids through the ranges /etc/subuid and
# /etc/subgid grant this user, and it caches that map in its storage the FIRST
# time it runs. Ranges added afterwards never reach a storage that is already
# initialised: the pull then dies mid-download with "lchown …: invalid
# argument" (an unmapped gid), GBs in. So BOTH halves are checked, before the
# build ladder can pull anything — the grant on paper, and the map podman
# actually holds.
SUBID_MIN=65536
subid_count() {   # subuid|subgid → largest count granted to this user (0=none)
  local db=$1 out="" n best=0
  # getent knows the databases on hosts with libsubid NSS; everywhere else the
  # file IS the database. Entries may be keyed by name or by uid.
  out=$(getent "$db" "$PF_ME" 2>/dev/null) || out=""
  if [[ -z $out && -r /etc/$db ]]; then
    out=$(grep -E "^($PF_ME|$PF_UID):" "/etc/$db" 2>/dev/null) || out=""
  fi
  while IFS=: read -r _ _ n; do   # <name>:<first id>:<count>, count is ours
    [[ $n =~ ^[0-9]+$ ]] || continue
    [[ $n -gt $best ]] && best=$n
  done <<<"$out"
  printf '%s' "$best"
}

idmap_rows() {   # uid_map|gid_map → rows podman really maps (0 = no probe)
  local out
  out=$("$RUNTIME_BIN" unshare cat "/proc/self/$1" 2>/dev/null) \
    || { printf 0; return 0; }
  # One row = the user's own id and nothing else, which is exactly the state a
  # storage initialised before the grant is stuck in.
  awk 'NF {c = c + 1} END {print c + 0}' <<<"$out"
}

pf_idmap() {
  local u g ru rg
  # Rootful podman (and docker) map container ids directly and grant no
  # subordinate ranges; `podman unshare` refuses to run there at all.
  [[ $RUNTIME == podman && $ROOTLESS -eq 1 ]] || return 0
  u=$(subid_count subuid)
  g=$(subid_count subgid)
  if [[ $u -lt $SUBID_MIN || $g -lt $SUBID_MIN ]]; then
    if [[ $u -eq 0 || $g -eq 0 ]]; then
      pf_bad "no subuid/subgid range for $PF_ME $EMD rootless pulls cannot map ids"
    else
      pf_bad "subuid/subgid range for $PF_ME is short ($u/$g < $SUBID_MIN ids)"
    fi
    pf_hint "grant one: $(emph "sudo usermod --add-subuids 100000-165535 \\")"
    pf_hint "$(emph "                        --add-subgids 100000-165535 $PF_ME")"
    pf_hint "then $(emph 'podman system migrate') $EMD podman caches the old map"
    # Returning HERE, before the unshare probe, is the point: `podman unshare`
    # initialises the storage it is asked about, and a storage first
    # initialised without the grant is exactly the stale map above.
    return 0
  fi
  ru=$(idmap_rows uid_map)
  rg=$(idmap_rows gid_map)
  # 0 rows is not a short map, it is no answer at all (podman unshare could not
  # run — no newuidmap, a locked-down host, a broken runtime dir). Say so
  # instead of diagnosing a map that was never read.
  if [[ $ru -eq 0 || $rg -eq 0 ]]; then
    # TWO rows, because the probe answers two different questions and only one
    # of them came back: the grant on paper IS good (✅), the map podman holds
    # simply went unread (🔶 — maybe fine, maybe the lchown death). Saying that
    # in one row made the good half look like part of the problem, and the two
    # hint lines under it explained a failure that has not happened yet; the
    # fix now rides in the caution row itself.
    pf_ok "subuid/subgid granted ($u ids)"
    pf_note "$RUNTIME id mapping unverified; if pull fails, try \"$RUNTIME system migrate\""
    return 0
  fi
  if [[ $ru -lt 2 || $rg -lt 2 ]]; then
    pf_bad "podman maps only your own id ($ru/$rg rows) $EMD pulls die mid-layer"
    pf_hint "the ranges above were granted after podman first ran, so its"
    pf_hint "storage never saw them: $(emph 'podman system migrate'), then re-run"
    return 0
  fi
  pf_ok "subuid/subgid mapping live ($u ids; $ru/$rg map rows)"
  return 0
}

# ── Preflight (warns; one hard stop) ─────────────────────────────────────────
preflight() {
  section "Preflight" intro
  say ""
  PF_ME=$(id -un)
  PF_UID=$(id -u)
  # First row, because it is the only one that ends the run — a reader who has
  # to act on it should not have to find it halfway down the report.
  pf_session
  if command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
    RUNTIME_BIN=$(command -v podman)
    [[ ${EUID:-$(id -u)} -ne 0 ]] && ROOTLESS=1
    pf_ok "podman found ($([[ $ROOTLESS -eq 1 ]] && echo rootless || echo rootful))"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME=docker
    RUNTIME_BIN=$(command -v docker)
    pf_ok "docker found (podman not present)"
    pf_hint "docker satisfies distrobox's dependency, so no podman comes in;"
    pf_hint "the image pulls need it: $(emph 'sudo apt install podman') (apt distros)"
  else
    pf_bad "neither podman nor docker found $EMD definitions will still be written"
    pf_hint "apt distros: $(emph 'sudo apt install podman') $EMD else your package manager"
  fi
  # Ordered after the runtime row on purpose: it has nothing to say until it
  # knows there is a rootless podman to ask (it returns silently otherwise).
  pf_idmap
  if [[ -e /dev/kfd && -e /dev/dri ]]; then
    pf_ok "GPU devices present: /dev/kfd /dev/dri"
  else
    # No reassuring tail: on THIS installer's hosts the GPU is the point, and a
    # 🚨 that ends in "fine on a non-GPU host" reads as its own dismissal.
    pf_bad "GPU devices missing (/dev/kfd, /dev/dri)"
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
    # 🔶, not 🚨: fuse-overlayfs is one of three mitigation options, so losing
    # it only blocks the run on a filesystem that turns out to need it.
    pf_note "/dev/fuse missing $EMD fuse-overlayfs fallback unavailable"
  fi
  # The pull path is curl (POST to the podman REST API) piped into python3
  # (which aggregates the per-layer byte counts into one bar). Both are hard
  # dependencies of an image pull; neither is needed to write definitions.
  if command -v python3 >/dev/null 2>&1; then
    pf_ok "python3 found (image-pull progress)"
  else
    pf_bad "python3 not found $EMD image pulls will fail (definitions still written)"
  fi
  if command -v curl >/dev/null 2>&1; then
    pf_ok "curl found (image-pull transport)"
  else
    pf_bad "curl not found $EMD image pulls will fail (definitions still written)"
  fi
  # Lingering: a rootless user manager exits at logout unless the user lingers,
  # which would take BOTH the boot auto-start units and podman's own healthcheck
  # timers down with it. Reported here; offered for real (bare `loginctl
  # enable-linger`, no sudo — verified on hardware) only if a box actually asks
  # to start at host boot. See enable_linger().
  probe_linger
  case "$LINGER" in
    yes) pf_ok "user lingering enabled (boot auto-start + healthcheck timers)" ;;
    no)  pf_note "user lingering off $EMD needed to start boxes at host boot (offered later)" ;;
    # Unknown is 🔶: nothing is wrong yet, the installer just could not look —
    # and the boot auto-start offer later on works it out for itself.
    *)   pf_note "cannot read user lingering state (loginctl missing?)" ;;
  esac
  command -v distrobox >/dev/null 2>&1 && HAVE_DISTROBOX=1
  if [[ $HAVE_DISTROBOX -eq 0 ]]; then
    # The blocker and its fix in ONE row: the hint under it said the same thing
    # at a second indent, and this is the row a first-time reader stops at.
    pf_bad "distrobox missing; needed to create boxes. Try \`sudo apt install distrobox\`"
  fi
  # The whole report is printed first, THEN the run ends: a session that has to
  # be replaced is worth reporting alongside everything else the new one will
  # find. This is the one thing preflight blocks on (see pf_session).
  if [[ $PF_STOP -eq 1 ]]; then
    say ""
    die "log in as $PF_ME itself, then re-run (see the $MK_BAD row above)"
  fi
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
  # /opt/program-cache is the PER-BOX cache root (s38 taxonomy) and /opt/caches
  # the SHARED compute one — one letter apart on the container side, and two
  # different host roots. An ini written before s38 has no /opt/program-cache
  # bind at all; that is not an error, it just means nothing seeds `pcache`.
  case "$dest" in
    /opt/data) printf 'data'; return 0 ;;
    /opt/program-cache) printf 'pcache'; return 0 ;;
    /opt/models) printf 'models'; return 0 ;;
    /opt/caches) printf 'caches'; return 0 ;;
    */.cache/huggingface) printf 'hf'; return 0 ;;
  esac
  for pair in ${BOX_EXTRA_BINDS[$box]}; do
    if [[ ${pair#*:} == "$dest" ]]; then printf '%s' "${pair%%:*}"; return 0; fi
  done
  printf ''
}

# Read back what the last run wrote. NO MIGRATION (Jei s38 Q4): an ini from
# before the storage taxonomy records the OLD shapes — the data dir at
# `<rc>/<box>/data`, a workspace beside it, the shared caches at `<rc>/caches`,
# and no /opt/program-cache bind at all. Every one of those is read as what it
# says, and the parts the old layout has nothing to say about (the box's
# program-cache dir) simply stay unseeded, so they offer their factory default.
# A path that does not fit the new <base>/<box> shape makes its family answer
# "no common base" (family_base), which routes it to the per-box question — the
# user is asked where it goes now rather than being moved without being told.
#
# TWO LINES CARRY THE PATHS, AND THEY ARE NOT PEERS (s39). `volume=` is what
# distrobox and podman act on, so its sources are always resolved absolutes —
# podman 5.4.2 binds a source only when it starts with / or ./, and anything
# else silently becomes a NAMED VOLUME with that string for a name, so a ~ or a
# $HOME on that line is not a bind at all. The SPELLING the user wrote is
# therefore recorded beside it, in the `# droste-setup: spelled="..."` comment,
# in the same "<src>:<dest>" shape so the two lines read against each other by
# dest.
#
# PRECEDENCE, RULED (Jei s39): volume= WINS. It is authoritative for the value,
# always; the comment only ever contributes a spelling, and only when it names
# the same directory (same_dir, so a symlinked or aliased home still matches).
# When they disagree, the comment is describing some other directory — a
# hand-edited volume= line, most likely — and there is nothing left for it to
# spell, so the volume= string is taken verbatim.
parse_existing_ini() {  # box
  local box=$1 f line vols entry src dest label
  local -A vsrc=() spelled=()
  f=$(fs_path "$(ini_file "$box")")
  [[ -f $f ]] || return 0
  while IFS= read -r line; do
    if [[ $line =~ ^volume=\"(.*)\"$ ]]; then
      vols=${BASH_REMATCH[1]}
      for entry in $vols; do
        src=${entry%%:*}
        dest=${entry#*:}; dest=${dest%%:*}
        label=$(dest_to_label "$box" "$dest")
        # First entry per label wins, exactly as before. `if`, not `[[ … ]] &&`:
        # a false test as the last command of a loop body is the status of the
        # whole loop, and this script runs under `set -e`.
        if [[ -n $label && -z "${vsrc[$label]:-}" ]]; then vsrc[$label]=$src; fi
      done
    elif [[ $line =~ ^#[[:space:]]*droste-setup:[[:space:]]*spelled=\"(.*)\"$ ]]; then
      # The spelling record. Collected, not applied: the two lines may arrive in
      # either order in a file someone has edited, so they are reconciled once
      # the whole ini has been read.
      vols=${BASH_REMATCH[1]}
      for entry in $vols; do
        src=${entry%%:*}
        dest=${entry#*:}; dest=${dest%%:*}
        label=$(dest_to_label "$box" "$dest")
        if [[ -n $label && -z "${spelled[$label]:-}" ]]; then spelled[$label]=$src; fi
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
  # Reconcile: the value comes from volume=, the spelling from the comment when
  # it still names that same directory. abs_path gives whichever won the same
  # lexical tidy a typed answer gets — and leaves a ~ alone.
  for label in "${!vsrc[@]}"; do
    src=${vsrc[$label]}
    if [[ -n "${spelled[$label]:-}" ]] && same_dir "${spelled[$label]}" "$src"; then
      src=${spelled[$label]}
    fi
    EXD_PATH["$box:$label"]=$(abs_path "$src")
  done
  return 0
}

# The LIVE serve state of a box: server.env (which the user may have edited with
# an editor — that is the whole point of the file) wins over the ini's record of
# what droste-setup.sh last wrote. Parsed the same defensive way P1's serve library
# parses it: shell-sourceable KEY=VALUE, anything unusable simply ignored.
parse_serve_env() {  # box
  local box=$1 f line k v
  f=$(serve_env_file "$box") || return 0
  [[ -n $f ]] || return 0
  f=$(fs_path "$f")      # a data dir the user spelled with ~ is still a dir
  [[ -f $f && -r $f ]] || return 0
  while IFS= read -r line; do
    line=${line%%#*}
    [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$ ]] || continue
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
    case "$k" in
      # STARTUP_ENABLED is the key since s45; SERVE is its predecessor and is still
      # read, because live boxes have it. Order matters: the loop takes the LAST
      # assignment it sees, so a file carrying both ends up with whatever is written
      # lower — which is why emit_serve_env writes ONLY the new key and drops the old
      # one on the next modify run, rather than leaving two keys to disagree.
      STARTUP_ENABLED|SERVE)
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
    [[ -f $(fs_path "$(ini_file "$box")") ]] && EX_INI[$box]=1
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
        subnote "Unrecognized:$bad $EMD use the names or numbers above."
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
  # The program-cache root gets the same treatment as the data one: it is not a
  # BOX_EXTRA_BIND (emit_ini writes its bind on its own), so the loop below
  # would never reach it, and a kept box that cannot name its cache dir cannot
  # be described in NOTES/the dashboard. An ini from before s38 records none,
  # and the box keeps the factory path.
  [[ -n "${EXD_PATH["$box:pcache"]:-}" ]] && PATHS["$box:pcache"]=${EXD_PATH["$box:pcache"]}
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
SEED_PCACHE_Q=Y SEED_PCACHE_BASE=""  # per-box program caches at a common base
SEED_DATA_Q=Y SEED_DATA_BASE=""      # persistent data at a common base
SEED_HF="" SEED_COMPUTE="" SEED_MODELS=""   # SEED_MODELS "" = None (no bind)
# A family that fell back to per-box questions, and the recorded path that
# settled it: "<box>: <path>". Empty = no fallback (or nothing recorded to
# fall back FROM). Printed above the storage questions, because a default that
# came out of a fallback should say so — a silent flip to N with a factory
# example reads exactly like a broken read-back, which is how it was reported.
SEED_NOBASE_DATA="" SEED_NOBASE_PCACHE=""
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

# What base does ONE recorded path imply, given the shape its family uses?
# "-" when the path is not in that shape at all.
#
# The program cache root puts the box directly under the base (<base>/<box> IS
# the cache dir); every data-family bind is a leaf beside its siblings
# (<base>/<box>/<program|input|output|workspace>).
#
# READ TOLERANTLY, WRITE STRICTLY: a data path recorded as <base>/<box> is the
# pre-s41 layout, from before the data dir became a `program` sibling of the
# others. It still names a base, and saying otherwise would report "these do not
# share a common base" about a set of paths that plainly do. The path is not
# rewritten for it — an old box keeps what its ini says until its owner moves
# it (Jei: "I can manually fix my boxes") — but it is understood.
shape_base() {  # box leaf path → base | "-"
  local box=$1 leaf=$2 p=$3 d
  if [[ $leaf == pcache ]]; then
    if [[ $p == */"$box" ]]; then printf '%s' "${p%/"$box"}"; else printf '-'; fi
    return 0
  fi
  d=$(leaf_dir "$leaf")
  if [[ $p == */"$box"/"$d" ]]; then printf '%s' "${p%/"$box"/"$d"}"; return 0; fi
  if [[ $leaf == data && $p == */"$box" ]]; then printf '%s' "${p%/"$box"}"; return 0; fi
  printf '-'
  return 0
}

# The common base of a family of recorded paths, or "" when they do not share
# the family's shape (or disagree about the base).
family_base() {   # leaf...
  local leaf box p base first="" seen=0
  for box in ${SEED_SRC[@]+"${SEED_SRC[@]}"}; do
    for leaf in "$@"; do
      p=${EXD_PATH["$box:$leaf"]:-}
      [[ -n $p ]] || continue
      base=$(shape_base "$box" "$leaf" "$p")
      if [[ $seen -eq 0 ]]; then first=$base seen=1
      elif [[ $base != "$first" ]]; then printf '-'; return 0
      fi
    done
  done
  [[ $seen -eq 0 ]] && return 0     # nothing recorded: caller keeps its factory
  printf '%s' "$first"
  return 0
}

# The label as the note says it out loud. "pcache" is this script's word for
# them, not the reader's.
leaf_word() {  # label → display word
  case "$1" in
    pcache) printf 'program cache' ;;
    data)   printf 'program data' ;;
    *)      printf '%s' "$1" ;;
  esac
}

# The DIRECTORY a bind takes under the box's own dir. The data bind is spelled
# `program` there — short for "program data", which is what its prompt has
# always called it ("Path for ComfyUI program data").
#
# ⭐ RULED (Jei, s41): THE NESTING WAS AN OVERSIGHT. The box's data dir used to
# BE <base>/<box>, with input/output living INSIDE it; the three are siblings
# now, under a box directory that is not itself a bind:
#
#     <data base>/<box>/program   → /opt/data
#     <data base>/<box>/input     → /opt/ComfyUI/input
#     <data base>/<box>/output    → /opt/ComfyUI/output
#
# Host side only — no container path changes. NO MIGRATION: existing boxes keep
# the paths their ini records (Jei: "I can manually fix my boxes"), and only new
# placements take the new shape.
leaf_dir() {  # label → directory name
  case "$1" in
    data) printf 'program' ;;
    *)    printf '%s' "$1" ;;
  esac
}

# What EXPLAINS a "-" from family_base, in terms the reader can act on. TWO
# different things produce that "-", and they do not have the same answer:
#
#   a MALFORMED path — a shape this layout does not use. One entry names it,
#   and it explains itself.
#
#   a DISAGREEMENT — every path well-shaped, the bases simply differ. This was
#   Jei's own case, and the old code fell through to "print the first recorded
#   entry", which reads as a COUNTER-EXAMPLE to the claim it is supporting: one
#   well-formed path, offered as evidence that the paths are not well-formed.
#   Both sides are named instead (Jei, s40: "comfyui data: … vs comfyui input:
#   …") — the disagreement is a relationship, so it takes two paths to show it.
#
# One line per entry, "<box> <leaf>: <path>"; nobase_note renders them. A
# separate walk from family_base on purpose — that one runs in a command
# substitution, so it cannot hand anything back out of band.
family_example() {   # leaf... → 0, 1 or 2 lines ("" when nothing is recorded)
  local leaf box p base first="" firstbase=""
  for box in ${SEED_SRC[@]+"${SEED_SRC[@]}"}; do
    for leaf in "$@"; do
      p=${EXD_PATH["$box:$leaf"]:-}
      [[ -n $p ]] || continue
      base=$(shape_base "$box" "$leaf" "$p")
      # It is quoting the user's own file back at them ("why am I being asked
      # per box?"), and $p IS what their file says.
      if [[ $base == "-" ]]; then
        printf '%s %s: %s' "$box" "$(leaf_word "$leaf")" "$p"
        return 0
      fi
      if [[ -z $first ]]; then
        first="$box $(leaf_word "$leaf"): $p" firstbase=$base
        continue
      fi
      if [[ $base != "$firstbase" ]]; then
        printf '%s\n%s %s: %s' "$first" "$box" "$(leaf_word "$leaf")" "$p"
        return 0
      fi
    done
  done
  printf '%s' "$first"
  return 0
}

# The base MOST of the recorded paths agree on — what to offer when a family has
# no single base but the files still say plainly where most of them live. Jei's
# standard is that a prompt default MATCHES THE FILE, and any recorded base
# matches a file; the factory path this replaces matched nothing on the disk.
# ⚠️ THE TIE-BREAK IS MINE, NOT RULED: on a dead heat (two boxes, two bases)
# the FIRST recorded base wins, because box order is stable and an arbitrary
# answer that is stable beats one that moves between runs. Either way the
# outliers meet the move question, which is where they get settled.
family_dominant() {  # leaf... → base ("" when nothing is well-shaped)
  local leaf box p base best="" bestn=0 n
  local -a order=()
  local -A count=()
  for box in ${SEED_SRC[@]+"${SEED_SRC[@]}"}; do
    for leaf in "$@"; do
      p=${EXD_PATH["$box:$leaf"]:-}
      [[ -n $p ]] || continue
      base=$(shape_base "$box" "$leaf" "$p")
      [[ $base == "-" ]] && continue
      if [[ -z ${count["$base"]:-} ]]; then order+=("$base"); fi
      count["$base"]=$(( ${count["$base"]:-0} + 1 ))
    done
  done
  for base in ${order[@]+"${order[@]}"}; do
    n=${count["$base"]}
    if [[ $n -gt $bestn ]]; then best=$base bestn=$n; fi
  done
  printf '%s' "$best"
  return 0
}

seed_globals() {
  local box base yes=0 no=0
  seed_sources
  # Factory values first: with no seed source (all-recreate, all-new, all-keep)
  # these are exactly what every question below offers.
  SEED_PORTS=Y
  SEED_SERVE=n SEED_HOST=n
  SEED_PCACHE_Q=Y SEED_DATA_Q=Y
  # A FACTORY DEFAULT IS SPELLED THE WAY THE INSTALLER WOULD WRITE IT: ~, not
  # an expansion of it. Nobody authored this path, so there is no other
  # spelling owed to anyone — and the moment it is offered and accepted, ~ is
  # what the user chose, which is what every later line shows. (The other
  # factory paths hang off the resource path and inherit ITS spelling, so a
  # typed /srv/droste never grows a ~ anywhere below it.)
  # shellcheck disable=SC2088  # a LITERAL ~, resolved by fs_path at use
  SEED_HF="~/.cache/huggingface"
  # The compute cache is SHARED by every box (kernels are content-keyed), so it
  # sits beside the two per-box roots rather than inside either of them.
  SEED_COMPUTE=$EMIT_DIR/compute-caches
  # No model collection until a path is typed (s38): the prompt's default is
  # the word "None", not a directory the installer would go and create.
  SEED_MODELS=""
  # The two host roots, both derived from the resource path.
  SEED_DATA_BASE=$EMIT_DIR/data
  SEED_PCACHE_BASE=$EMIT_DIR/caches
  [[ ${#SEED_SRC[@]} -eq 0 ]] && return 0
  # Each seed is the recorded path AS RECORDED — the prompt below offers that
  # string, and an empty answer hands the same string back to abs_path, so a
  # box that is left alone keeps the spelling it was set up with.
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_PATH["$box:hf"]:-}" ]] && { SEED_HF=${EXD_PATH["$box:hf"]}; break; }
  done
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_PATH["$box:caches"]:-}" ]] && { SEED_COMPUTE=${EXD_PATH["$box:caches"]}; break; }
  done
  # A recorded /opt/models bind IS the answer: it comes back as the prompt's
  # default, so an empty answer keeps the share exactly where it was.
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_PATH["$box:models"]:-}" ]] && { SEED_MODELS=${EXD_PATH["$box:models"]}; break; }
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
  # The two roots, each read back from the paths its family actually records:
  # one shared base → Y with that base offered at the base prompt; no agreement
  # (or a shape the layout does not use) → N, and the boxes are asked one by
  # one. Persistent data counts its nested leaves too, since they are the same
  # family: an input dir somewhere else means the base is NOT common.
  #
  # NO AGREEMENT IS NOT NO INFORMATION (G4, Jei s40): the question still defaults
  # to N and the boxes are still asked one by one, but the base it OFFERS comes
  # from the files rather than from the factory. On his run the data question
  # offered ~/resources/droste/data — a path invented on the spot — while his
  # inis put the data base at /srv/appdata/droste, and his ruling was that the
  # default has to MATCH THE FILE (he refused a "(recorded)" marker: the value
  # itself has to be right). Saying yes here now lands the family where most of
  # it already is, and the outliers meet the move question in their own section.
  base=$(family_base data input output workspace)
  if [[ -n $base ]]; then
    if [[ $base == "-" ]]; then
      SEED_DATA_Q=N
      SEED_NOBASE_DATA=$(family_example data input output workspace)
      # `if`, not `[[ … ]] &&`: a false test as the last command of a branch is
      # the status of the whole compound, and this script runs under `set -e`.
      base=$(family_dominant data input output workspace)
      if [[ -n $base ]]; then SEED_DATA_BASE=$base; fi
    else
      SEED_DATA_BASE=$base
    fi
  fi
  base=$(family_base pcache)
  if [[ -n $base ]]; then
    if [[ $base == "-" ]]; then
      SEED_PCACHE_Q=N
      SEED_NOBASE_PCACHE=$(family_example pcache)
      base=$(family_dominant pcache)
      if [[ -n $base ]]; then SEED_PCACHE_BASE=$base; fi
    else
      SEED_PCACHE_BASE=$base
    fi
  fi
  return 0
}

# Why a family is about to be asked box by box. A fallback that says nothing
# looks exactly like a failed read-back: the question flips to N and offers a
# FACTORY example, while the user knows perfectly well where their files are.
# Naming what was found turns a silent degrade into a statement.
# One entry keeps the drawn shape (a malformed path explains itself in a
# parenthetical); a DISAGREEMENT takes two paths to show, and two paths do not
# fit in one — they are listed under the sentence instead, one per line, where a
# long path can wrap without breaking the line it is quoted inside.
#
# The sentence itself is written for the place it appears: this note fires
# during GENERAL SETUP, and a bare "comfyui: …" under a global question read as
# a stray box section (Jei: "this is not a comfyui section"). Naming the BIND on
# each line — "comfyui data", "comfyui input" — makes them quotations from the
# ini rather than a heading.
nobase_note() {   # "what" "<box> <leaf>: <path>[\n<box> <leaf>: <path>]"
  local line n=0
  [[ -n $2 ]] || return 0
  while IFS= read -r line; do n=$((n + 1)); done <<<"$2"
  if [[ $n -le 1 ]]; then
    printf '\n  %sExisting %s do not share a common base%s\n' "$C_QTXT" "$1" "$RESET"
    printf '  %s(%s) - asking per box.%s\n' "$C_QTXT" "$2" "$RESET"
    return 0
  fi
  printf '\n  %sExisting %s do not share a common base - asking per box:%s\n' \
    "$C_QTXT" "$1" "$RESET"
  while IFS= read -r line; do
    printf '    %s%s%s\n' "$C_QTXT" "$line" "$RESET"
  done <<<"$2"
  return 0
}

# ── General Setup ────────────────────────────────────────────────────────────
# Everything that can be settled ONCE for the whole install: the two networking
# questions that would otherwise repeat per box (ports, and when a box's server
# comes up), then the two HOST ROOTS (program caches, persistent data) and the
# paths every box shares — the compute cache, the HF cache, the model share.
general_setup() {
  local pcache_common=0 data_common=0
  section "General Setup"
  subhdr "Networking"
  # One answer settles every per-box port question (the table above just showed
  # the defaults, so this is the moment they can be accepted wholesale).
  ask_yn "Use default ports for all services" "$SEED_PORTS"
  [[ $ANS_YN -eq 1 ]] && PORTS_DEFAULT=1
  # Does a box's SERVICE come up when its container starts?
  # (server.env STARTUP_ENABLED — this asks about BOX START only, never about
  # whether a server should be up right now; that is the box's own .IS_ACTIVE.)
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
  # ── Storage Paths: the two elections, then one block per family ────────────
  # Jei's s41 layout. The two yes/no questions stand together under "Storage
  # Paths" — PERSISTENT DATA FIRST, since it is the half people care about and
  # the half the box sections then talk about — and everything each answer
  # implies is asked under its own subheader, beside the shared paths that
  # belong to the same family. The old single run of prompts put the model share
  # between two caches and the base prompts three questions away from the
  # question that decided them.
  #
  # Each election names the BASE, not the templated leaf (Jei, live test): the
  # per-box shape is the installer's business, and spelling it out here read as
  # though the literal string were the answer. Where the family lands is said
  # once, in the italic line under the subheader.
  subhdr "Storage Paths"
  nobase_note "data dirs" "$SEED_NOBASE_DATA"
  ask_yn "Store persistent data at common base path (e.g., $SEED_DATA_BASE)" \
    "$SEED_DATA_Q"
  data_common=$ANS_YN
  nobase_note "program cache dirs" "$SEED_NOBASE_PCACHE"
  ask_yn "Store program caches at common base path (e.g., $SEED_PCACHE_BASE)" \
    "$SEED_PCACHE_Q"
  pcache_common=$ANS_YN

  subhdr "Host Data Paths"
  # A base prompt renders ONLY for a family the user agreed to place at a common
  # base (Jei s38); declining routes that family to the per-box path question in
  # the box's own section instead.
  if [[ $data_common -eq 1 ]]; then
    prose "*Data will be stored at <base>/<box>." "$C_QTXT"
    ask_path_as "Persistent data base path" "$SEED_DATA_BASE"
    DATA_ROOT=$ANS_PATH
    DATA_AUTO=1
  fi
  # The optional read-only model share — a path-or-None prompt, so the bind and
  # its location are one answer instead of a toggle plus a follow-up — and the
  # HF cache, which is a MODEL STORE and never wiped, whatever its name says.
  ask_path_or_none "Path to bind as read-only share /opt/models" "$SEED_MODELS"
  MODELS_DIR=$ANS_OPT_PATH
  ask_path_as "HuggingFace models (\"cache\", never wiped)" "$SEED_HF"
  HF_CACHE=$ANS_PATH

  subhdr "Host Cache Paths"
  if [[ $pcache_common -eq 1 ]]; then
    prose "*Caches will be stored at <base>/<box>." "$C_QTXT"
    ask_path_as "Program caches base path" "$SEED_PCACHE_BASE"
    PCACHE_ROOT=$ANS_PATH
    PCACHE_AUTO=1
  fi
  # Shared by every box (kernels are content-keyed), which is why it sits here
  # rather than inside either per-box root.
  ask_path_as "Compute caches (MIOpen/Triton/torch)" "$SEED_COMPUTE"
  COMPUTE_CACHE=$ANS_PATH
  # THE STALE-CACHE QUESTION, install-wide and last in its own block: it is
  # about the caches the answers above just placed, and it is asked ONLY when
  # there is something to clear. One YES settles every box; a NO hands the
  # decision to the boxes that have something, in their own sections. Default
  # YES — a stale cache is the box's most common cause of "it starts but
  # misbehaves", and nothing in one is authored.
  if stale_any; then
    ask_yn "Stale caches often cause malfunctions. Clear all old / stale caches" Y
    CLEAR_STALE_ALL=$ANS_YN
  fi
  # Close the section the way a per-box section and the Data Mapping one close,
  # so whatever follows (a rule, a banner) keeps the same two-line gap.
  say ""
  return 0
}

# ── Filesystem probe + overlay mitigation (the ecryptfs lesson) ──────────────
FSTYPE=""
probe_fstype() {  # dir → FSTYPE
  local d
  d=$(fs_path "$1")     # findmnt takes a path, not a spelling
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
# The colour is a parameter because two voices use this same block: body text
# for the Data Mapping explainer, and the quieter question-text grey for a note
# that stands immediately above a prompt (nobase_note's voice).
prose() {   # text [colour]
  local w line col=${2:-$C_TEXT}
  w=$(( $(disp_width) - 2 ))
  while IFS= read -r line; do
    printf '  %s%s%s\n' "$col" "$line" "$RESET"
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
  prose "The filesystem for $dir is incompatible with droste's default tool, Linux's overlayfs. Note: if ignored, filesystem must be changed before any containers can load."
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

# The paths that exist before any box section, most primary first. "Already
# answered for" is same_dir, not ==: a root typed as ~/droste and a resource
# path typed as /home/you/droste are one directory and one question.
mitigation_slot_path() {  # slot → path ("" when that slot is not in play)
  case "$1" in
    rc)      printf '%s' "$EMIT_DIR" ;;
    data)    [[ -n $DATA_ROOT ]] && ! same_dir "$DATA_ROOT" "$EMIT_DIR" \
               && printf '%s' "$DATA_ROOT" ;;
    # The program-cache root is where the venv upper lands, so it has to accept
    # an overlay upper in its own right (P0 choice C) — probed unless it is one
    # of the paths already answered for.
    pcache)  [[ -n $PCACHE_ROOT ]] && ! same_dir "$PCACHE_ROOT" "$EMIT_DIR" \
               && ! same_dir "$PCACHE_ROOT" "$(data_root)" \
               && printf '%s' "$PCACHE_ROOT" ;;
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
      # A root that merely tracked the resource path keeps tracking it.
      [[ $DATA_ROOT == "$EMIT_DIR/data" ]] && DATA_ROOT=""
      [[ $PCACHE_ROOT == "$EMIT_DIR/caches" ]] && PCACHE_ROOT=""
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
    data)
      ask_path_as "Persistent data base path" "$(data_root)"
      DATA_ROOT=$ANS_PATH ;;
    pcache)
      ask_path_as "Program cache base path" "$(pcache_root)"
      PCACHE_ROOT=$ANS_PATH ;;
    compute)
      ask_path_as "Compute caches (MIOpen/Triton/torch)" "$COMPUTE_CACHE"
      COMPUTE_CACHE=$ANS_PATH ;;
    hf)
      ask_path_as "HuggingFace models (\"cache\" - never wiped)" "$HF_CACHE"
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
    for slot in rc data pcache compute hf; do
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

# ── Where the two host roots live ────────────────────────────────────────────
# Both are settled up front in General Setup; the old "would you like this
# pattern applied to everything?" follow-up (PATTERN_ROOT) is retired with it.
DEFAULT_ROOT=""  # emit dir (default ~/droste)

# Base path for the PERSISTENT DATA family (the box's /opt/data, with
# input/output/workspace nested inside it) and for the PROGRAM CACHE family
# (venv, tmp, slots, kv-disk — everything the installer may wipe). The compute
# and HuggingFace caches are deliberately in neither: they are shared by every
# box, keyed by content, and were asked separately.
DATA_ROOT=""     # "" = <resource path>/data
DATA_AUTO=0      # 1 = every box's data dir is <base>/<box>, never asked
PCACHE_ROOT=""   # "" = <resource path>/caches
PCACHE_AUTO=0    # 1 = every box's program-cache dir is <base>/<box>, never asked
PORTS_DEFAULT=0  # 1 = every box takes the default host port, never asked
SERVE_MODE=n     # y|n|c — serve at box start, install-wide (c = ask per box)
HOST_MODE=n      # y|n|c — start at host boot, install-wide (c = ask per box)
CLEAR_STALE_ALL=0  # 1 = stale program caches are cleared for every box, never asked

data_root()   { printf '%s' "${DATA_ROOT:-$DEFAULT_ROOT/data}"; }
pcache_root() { printf '%s' "${PCACHE_ROOT:-$DEFAULT_ROOT/caches}"; }

# 1 when this label needs no question (General Setup already placed it).
# input/output/workspace nest INSIDE the box's data dir (Jei s38 K), so they
# ride on the data answer and are never asked on their own.
auto_label() {  # label
  if [[ $1 == pcache ]]; then [[ $PCACHE_AUTO -eq 1 ]]; else [[ $DATA_AUTO -eq 1 ]]; fi
}

# Where General Setup's roots PUT this label. Deliberately ignores a modify
# box's recorded path: the recorded value's job is to SEED the General Setup
# questions (family_base), not to override the answer given there. Letting it
# do both is what silently discarded a freshly typed base — the user was asked
# where the family goes, answered, and the box stayed where it was.
path_derived() {  # box label → derived path
  local box=$1 label=$2 root
  if [[ $label == pcache ]]; then
    printf '%s/%s' "$(pcache_root)" "$box"
  elif [[ $label == data ]]; then
    printf '%s/%s/%s' "$(data_root)" "$box" "$(leaf_dir data)"
  else
    # Every data-family bind hangs off THIS BOX'S DIRECTORY, as a SIBLING of the
    # others (s41: the old nesting was an oversight). That directory is the
    # PARENT of the program dir once one has been settled this run — so a
    # program path typed somewhere unexpected still takes input and output along
    # with it, which is what the old code did back when they lived inside it.
    if [[ -n "${PATHS["$box:data"]:-}" ]]; then
      root=${PATHS["$box:data"]%/*}
    else
      root=$(data_root)/$box
    fi
    printf '%s/%s' "$root" "$label"
  fi
}

# The DEFAULT a per-box prompt offers: a modify box's recorded path, else the
# derived placement. Only ever a prompt default — an auto-placed family takes
# path_derived instead, so an answer always beats a memory.
#
# Both branches hand back a spelling somebody chose: the recorded branch the
# user's own, the derived one the resource path's (path_derived hangs the box
# off a root that was itself typed or accepted). Nothing here needs a display
# conversion, and nothing here may be handed to the filesystem without fs_path.
path_default() {  # box label → default path (existing value > family base)
  local box=$1 label=$2
  if [[ ${ACTION[$box]} == modify && -n "${EXD_PATH["$box:$label"]:-}" ]]; then
    printf '%s' "${EXD_PATH["$box:$label"]}"
    return 0
  fi
  path_derived "$box" "$label"
}

# Which labels of a box ended up on an overlay-hostile filesystem, and the
# filesystem that triggered it (both feed the mitigation line under the box).
declare -A MIT_LABELS MIT_FS

# Settle ONE bind path of a box: pick it (automated, pattern-filled, or asked),
# make sure it exists, and answer its filesystem question. Sets PATHS[box:label]
# — plus CFG_FS/CFG_MODE when the label is the data dir, since /opt/data is the
# bind the in-box overlay is actually built on.
# $3 forces the PROMPT even for an auto-placed family. Its one caller is
# relocate_box's [c]hange, which is by ruling "the ordinary single-path settle
# route" and not a bespoke re-ask — so it re-enters this function rather than
# growing a second asker beside it.
set_bind_path() {  # box label [force-prompt]
  local box=$1 label=$2 def rc force=${3:-0}
  while :; do
    def=$(path_default "$box" "$label")
    if [[ $force -eq 0 ]] && auto_label "$label"; then
      # General Setup placed this family, and the answer given THERE wins — a
      # recorded path seeded that question, it does not get to overrule it.
      # (path_derived, not $def: $def is the per-box PROMPT default, which is
      # the recorded value on a modify box and would pin the box in place.)
      ANS_PATH=$(path_derived "$box" "$label")
      # Not created here when the move pass is going to offer to fill it: the
      # move creates what it needs, and a declined one leaves nothing behind.
      # Nor while a [c]hange is re-deriving the box's other binds: that path may
      # be abandoned by the very next answer, and relocate_box makes what is
      # left standing once the rounds are over.
      if [[ $RELOC_NO_CREATE -eq 0 ]] && ! relocatable "$box" "$label" "$ANS_PATH"; then
        ensure_dir "$ANS_PATH" || :
      fi
    else
      # No per-bind header: the prompt itself names the box + bind family —
      # unless the family writes its own prompt (BIND_PROMPT), which is how the
      # program-cache question gets its own wording without a second asker.
      #
      # ask_path_as is unrolled here for ONE reason: a path the move pass is
      # about to fill must not be confirmed into existence first. "Create
      # <path>?" exists so nothing is made silently — but this one is not
      # silent, it is named in the move question three lines further on, and
      # creating it before that question is asked leaves an empty directory
      # behind for a path the box does not use when the answer is no.
      while :; do
        ask_path_as_raw \
          "${BIND_PROMPT[$label]:-Path for ${BOX_NAME[$box]} ${BIND_TITLE[$label],,}}" "$def"
        relocatable "$box" "$label" "$ANS_PATH" && break
        ensure_dir "$ANS_PATH" && break
      done
    fi
    PATHS["$box:$label"]=$ANS_PATH
    # Modify with the SAME path keeps the mitigation already recorded for it
    # (re-prompts default to current values); a changed path is re-decided.
    # "The SAME path" is a question about DIRECTORIES, so it is asked with
    # same_dir: answering ~/appdata/comfyui where the ini said
    # /home/you/appdata/comfyui has not moved anything and must not re-open the
    # filesystem question.
    if [[ $label == data && ${ACTION[$box]} == modify && -n "${EXD_MODE[$box]:-}" ]] \
       && same_dir "$ANS_PATH" "${EXD_PATH["$box:data"]:-}"; then
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
    # ONE overlay mode per box (P0 choice C). The venv upper lives on the
    # PROGRAM-CACHE root now, so that root has to accept an overlay upper in its
    # own right: a hostile one sets the box's mode when the data dir did not
    # (the data dir, which carries comfyui's custom_nodes upper, still wins when
    # both objected — the two answers are the same menu answer anyway).
    #
    # It contributes no CATEGORY to the mitigation line: that sentence names the
    # binds the user was asked about by name ("using fuse for data, input, &
    # output"), and both s37/s38 mocks keep it to the data family, cache root
    # asked or not. Hence no MIT_LABELS/MIT_FS entry here — those two feed the
    # sentence and nothing else.
    if [[ $label == pcache ]]; then
      # `if`, not `[[ … ]] &&`: a false test as the last command of a branch is
      # the status of the whole compound, and this script runs under `set -e`.
      if [[ -z ${CFG_MODE[$box]:-} ]]; then CFG_MODE[$box]=$MIT_MODE; fi
    else
      MIT_LABELS[$box]="${MIT_LABELS[$box]:-} $label"
      MIT_FS[$box]=$FSTYPE
    fi
  elif [[ $label == data ]]; then
    CFG_MODE[$box]=""
  fi
  # A program cache that just moved leaves a directory behind. Asked HERE, not
  # in the box's move pass: caches are never offered a move (they regenerate),
  # so the only question they raise is what to do with the old directory — and
  # it is asked about the path this answer settled on, typed or derived alike.
  if [[ $label == pcache ]]; then relocate_pcache "$box" "$ANS_PATH"; fi
  return 0
}

# ── Stale program caches ─────────────────────────────────────────────────────
# A box's program-cache dir holds nothing but disposables: the venv upper and
# its work dir, tmp, slots, kv-disk, the seeded extra_model_paths.yaml, the
# serve pid. Nothing in it is authored and nothing in it is data — the taxonomy
# classifies BY LOCATION, which is exactly what makes this test cheap and
# honest: anything in there at all is a previous generation's leftovers, and an
# old stack layered under a new image is the failure that never names itself.
#
# SCOPE, ruled (Jei s38 D): the NEW layout only. An old-layout data/<box>/venv
# is not tested for — "not worth the complexity" — and is covered by the docs
# line naming the old paths safe to delete by hand. Compute caches are never
# tested and never cleared: they are content-keyed and shared by every box.
stale_pcache() { dir_has_content "$1"; }

# Is there anything in this directory at all? Dotfiles count — `.work` is the
# overlay bookkeeping and is exactly the kind of leftover the cache question is
# about, and a data dir holding nothing but a `.gitkeep` is still a data dir
# with something in it. A missing directory is not "empty": there is nothing
# there to clear and nothing there to move.
dir_has_content() {  # dir → 0 when it exists and holds anything at all
  local d=$1 p
  [[ -n $d ]] || return 1
  d=$(fs_path "$d")
  [[ -d $d ]] || return 1
  for p in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    [[ -e $p || -L $p ]] && return 0
  done
  return 1
}

# Does ANY box this run is about to configure have one? Asked at the path each
# box would take by default, since this runs before the per-box path questions;
# a box that is being KEPT is frozen and is not asked about here or anywhere.
stale_any() {
  local box
  for box in ${CONFIGURE[@]+"${CONFIGURE[@]}"}; do
    stale_pcache "$(path_default "$box" pcache)" && return 0
  done
  return 1
}

# A directory is cleared ONLY if it is this box's caches and nothing else. The
# answer to a question about caches is not consent to empty whatever else is at
# that path, and the one way the two can meet is a typed path: the prompt takes
# any directory, including the one the box keeps its DATA in. Everything this
# run has placed somewhere is checked by name — the two roots, the resource
# dir, the three shared paths, and every other bind of every box (another box's
# cache dir is not excluded: clearing a shared cache dir is what both of its
# answers asked for). $HOME and / are refused outright.
#
# EVERY COMPARISON HERE IS same_dir, NOT ==: two spellings of one directory are
# one directory, and a guard that only recognises its own spelling of a path is
# a guard that can be walked around by writing ~ instead of /home/you.
pcache_wipe_safe() {  # dir → 0 when nothing else in this install is that dir
  local dir=$1 key
  case "$(fs_path "$dir")" in /|"$HOME") return 1 ;; esac
  same_dir "$dir" "$EMIT_DIR" && return 1
  same_dir "$dir" "$(data_root)" && return 1
  same_dir "$dir" "$(pcache_root)" && return 1
  [[ -n $COMPUTE_CACHE ]] && same_dir "$dir" "$COMPUTE_CACHE" && return 1
  [[ -n $HF_CACHE ]] && same_dir "$dir" "$HF_CACHE" && return 1
  [[ -n $MODELS_DIR ]] && same_dir "$dir" "$MODELS_DIR" && return 1
  for key in "${!PATHS[@]}"; do
    [[ ${key##*:} == pcache ]] && continue
    same_dir "${PATHS[$key]}" "$dir" && return 1
  done
  return 0
}

# The test both halves of the consent share: this box has something stale, and
# clearing it would clear only caches. A path that fails the second half is
# reported once and then left out of the offer entirely — asking about it would
# be asking about the wrong directory.
stale_clearable() {  # box → 0 when the box has stale caches this may clear
  local box=$1
  local dir=${PATHS["$box:pcache"]:-}
  stale_pcache "$dir" || return 1
  pcache_wipe_safe "$dir" && return 0
  warn "$dir holds more than ${BOX_NAME[$box]}'s caches $EMD left alone"
  return 1
}

# Empty ONE box's program-cache dir: its CONTENTS, never the directory itself,
# and never a byte outside it — not the box's data, not the shared compute
# caches, not the HF cache. Silent on success (the summary box follows it
# immediately in the mock); the two ways it does NOT happen are reported.
#
# A RUNNING box is left alone: the venv upper is mounted under this dir,
# emptying it out from under the mount repairs nothing, and the box has to be
# restarted for any fix to take anyway.
clear_pcache() {  # box
  local box=$1
  local dir=${PATHS["$box:pcache"]:-} p real
  stale_clearable "$box" || return 0
  if [[ $(box_state "$box") == ACTIVE ]]; then
    subnote "$(box_ctr "$box") is running $EMD stop it, then re-run to clear its caches."
    return 0
  fi
  real=$(fs_path "$dir")
  for p in "$real"/* "$real"/.[!.]* "$real"/..?*; do
    [[ -e $p || -L $p ]] || continue
    rm -rf "$p" && continue
    warn "could not clear $dir $EMD empty it by hand, then re-run"
    return 0
  done
  return 0
}

# The per-box half of the consent. It is asked ONLY when the install-wide
# question did not already settle it AND this box actually has something stale
# at the path it just settled on — which is why it can fire even when the
# install-wide question never appeared: a path typed here may hold leftovers
# the default path did not. Nothing is ever cleared without one of the two
# answers, and the wipe happens the moment consent is given (s36 precedent),
# while the path it applies to is the one on screen.
stale_cache_offer() {  # box
  local box=$1
  stale_clearable "$box" || return 0
  if [[ $CLEAR_STALE_ALL -eq 0 ]]; then
    ask_yn_caution "Stale caches cause unpredictable behavior." "Clear stale caches" Y
    [[ $ANS_YN -eq 1 ]] || return 0
  fi
  clear_pcache "$box"
  return 0
}

# ── Moving existing data to a chosen base ────────────────────────────────────
# THE DEFECT THIS CLOSES (Jei, s40 Loaf run): answering YES to "store persistent
# data at a common base path" re-pointed every box's ini at <base>/<box> and
# LEFT THE BYTES WHERE THEY WERE, so the box came up bound to an empty
# directory, with nothing said. "Don't do what is being done and (somehow)
# ignore what the user says." — Jei. That the ANSWER WINS is s39's F8 fix; this
# is what happens to the data once it does.
#
# THE MOVER IS `mv` ITSELF, AND ITS BEHAVIOUR AND ITS ERRORS ARE OURS (Jei,
# s41): "mv copies across boundaries and removes the old. We should do the same,
# unless we know in advance that it will fail." coreutils already does
# rename(2), falls back to copy+unlink on EXDEV, preserves mode and timestamps,
# and leaves the SOURCE INTACT when a copy dies partway. So nothing here
# hand-rolls copy-verify-delete, and nothing here paraphrases what mv says: a
# refusal is printed in mv's own words.
#
# ⚠️ -T IS MANDATORY on every call: plain `mv src dst` onto an EXISTING
# directory moves src INSIDE it, which would silently produce <base>/<box>/<box>
# and then read as the user's own mistake.
#
# MEASURED (coreutils 9.7), because the whole flow is shaped by it:
#   dst missing            rename
#   dst an EMPTY dir       rename (mv rmdir's it first) — same across devices
#   dst a NON-EMPTY dir    REFUSED, both same-device ("cannot overwrite 'x':
#                          Directory not empty") and cross-device ("inter-device
#                          move failed: …; unable to remove target: …")
#   file onto file         overwritten, silently
#   dir onto file, or      REFUSED ("cannot overwrite non-directory 'x' with
#   file onto dir          directory 'y'", and its mirror)
#   dst a SYMLINK to a dir REFUSED — it is not a directory to mv
# The third line is why a non-empty destination has to be ASKED about rather
# than handed to mv, and the fourth is why "merge" means what it means below.

# KB → the shortest string that still says which order of magnitude it is.
hsize() {  # kb → "18K" | "4.2M" | "1.4G"
  local kb=$1 u=0 v=$1 t div=1
  local -a units=(K M G T P)
  [[ $kb =~ ^[0-9]+$ ]] || { printf '?'; return 0; }
  while [[ $v -ge 1024 && $u -lt 4 ]]; do
    v=$((v / 1024)); div=$((div * 1024)); u=$((u + 1))
  done
  if [[ $u -eq 0 ]]; then printf '%s%s' "$v" "${units[0]}"; return 0; fi
  # One decimal, taken at the chosen scale rather than from the truncated value
  # (1.4G, not 1G, when the difference is the point of printing it) and ROUNDED
  # rather than cut: these numbers are read side by side in the won't-fit
  # sentence, and 1.0G of free space against a 1.1G requirement is a sentence
  # the reader would have to be told twice.
  t=$(( (kb * 10 + div / 2) / div ))
  printf '%s.%s%s' "$((t / 10))" "$((t % 10))" "${units[$u]}"
}

dir_kb() {  # dir → size in KB (0 when it cannot be measured)
  local out kb
  out=$(du -sk -- "$(fs_path "$1")" 2>/dev/null) || out=""
  kb=${out%%[!0-9]*}
  [[ -n $kb ]] || kb=0
  printf '%s' "$kb"
}

# The closest ancestor that EXISTS — what a question about a not-yet-created
# destination is really asking about (which filesystem, and how much room).
nearest_existing() {  # resolved path → resolved path
  local d=$1
  while [[ ! -e $d && $d != / ]]; do d=$(dirname -- "$d"); done
  printf '%s' "$d"
}

avail_kb() {  # dir → KB free where it lives ("" when it cannot be measured)
  local d out fs blocks used avail
  d=$(nearest_existing "$(fs_path "$1")")
  # -P: POSIX output, one line per filesystem. Without it a long device name
  # wraps onto a second line and the field this reads is not there.
  out=$(df -Pk -- "$d" 2>/dev/null | tail -n1) || return 1
  read -r fs blocks used avail _ <<<"$out" || return 1
  : "$fs $blocks $used"
  [[ $avail =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$avail"
  return 0
}

# Would this be a rename or a copy? st_dev is what rename(2) itself compares, so
# this answers the same question the kernel will. UNKNOWABLE COUNTS AS CROSSING:
# a failed probe leads to the honest question ("this has to be copied") instead
# of a silent assumption that it will be instant.
same_device() {  # a b → 0 when both live on one filesystem
  local x y
  x=$(stat -c %d -- "$(nearest_existing "$(fs_path "$1")")" 2>/dev/null) || return 1
  y=$(stat -c %d -- "$(nearest_existing "$(fs_path "$2")")" 2>/dev/null) || return 1
  [[ $x == "$y" ]]
}

MV_ERR=""
run_mv() {  # src dst → 0 on success; MV_ERR = mv's own message
  local src dst
  src=$(fs_path "$1") dst=$(fs_path "$2")
  MV_ERR=""
  if MV_ERR=$(mv -T -- "$src" "$dst" 2>&1); then return 0; fi
  return 1
}

# mv's own words, indented under the answer that provoked them. NOT rephrased
# and NOT prefixed with WARNING: the error the user gets is the error the tool
# gives, which is the whole of the ruling.
mv_said() {
  local line
  [[ -n $MV_ERR ]] || return 0
  while IFS= read -r line; do
    printf '  %s `-> %s%s%s\n' "$C_ARROW" "$C_TEXT" "$line" "$RESET"
  done <<<"$MV_ERR"
  printf '\n'
  return 0
}

# MERGE is per-entry `mv -T`, because that is the only merge mv has. A file
# landing on a file is overwritten silently; a directory landing on a NON-EMPTY
# directory is REFUSED and stays where it is, named. That refusal is the
# behaviour, not a gap in it (Jei, s41: same behaviours and errors as mv) — the
# alternative, recursing into the collision and unioning it, is a thing mv will
# not do and is indistinguishable from "remove data at new path" for the files
# inside.
MERGE_MOVED=0
MERGE_KEPT=0
merge_into() {  # src dst → 0 when every entry landed
  local src=$1 dst=$2 p name real
  MERGE_MOVED=0 MERGE_KEPT=0
  real=$(fs_path "$src")
  for p in "$real"/* "$real"/.[!.]* "$real"/..?*; do
    [[ -e $p || -L $p ]] || continue
    name=${p##*/}
    if run_mv "$p" "$dst/$name"; then
      MERGE_MOVED=$((MERGE_MOVED + 1))
    else
      mv_said
      MERGE_KEPT=$((MERGE_KEPT + 1))
    fi
  done
  [[ $MERGE_KEPT -eq 0 ]] || return 1
  # mv removes a source directory once it has emptied it; a per-entry merge has
  # to take that last step itself, and only when nothing was left behind.
  rmdir -- "$real" 2>/dev/null || :
  return 0
}

# Where the family this bind belongs to was placed — the base for a root, the
# box's own data dir for a leaf that nests inside it. It is the second half of
# the sentence the move question opens with, so it names the place the user just
# chose, not the one this bind is being compared against.
family_place() {  # box label → path
  case "$2" in
    data)   data_root ;;
    pcache) pcache_root ;;
    *)      printf '%s' "${PATHS["$1:data"]:-$(data_root)/$1}" ;;
  esac
}

# The one question a re-pointed PROGRAM CACHE raises. True caches are moved
# nowhere and asked about nowhere — they regenerate, and re-pointing one costs
# the user nothing (Jei) — but the directory it VACATED is still on the disk,
# so: ask before deleting it, and if a running box blocks that, say so. This is
# the s38 consent-gated clear aimed at the old path, not a parallel flow: the
# same safety test decides whether the offer may be made at all.
#
# ⚠️ The HF cache is NOT one of these (Jei: "I'm not counting huggingface
# here") — it is the model store, and it takes the ordinary data move offer.
old_pcache_offer() {  # box old-dir
  local box=$1 old=$2 real
  dir_has_content "$old" || return 0
  if ! pcache_wipe_safe "$old"; then
    warn "$old holds more than ${BOX_NAME[$box]}'s caches $EMD left alone"
    return 0
  fi
  if [[ $(box_state "$box") == ACTIVE ]]; then
    subnote "$(box_ctr "$box") is running $EMD stop it, then re-run to remove $old."
    return 0
  fi
  say ""
  prose "${BOX_NAME[$box]}'s program caches are now at $(family_place "$box" pcache)/$box $EMD $old was left behind, and holds $(hsize "$(dir_kb "$old")") of caches." "$C_QTXT"
  ask_yn "Delete the old program cache dir" Y
  [[ $ANS_YN -eq 1 ]] || return 0
  real=$(fs_path "$old")
  rm -rf -- "$real" || warn "could not delete $old $EMD remove it by hand"
  return 0
}

# Is one directory inside another? Both sides are resolved, because this decides
# what a sentence CLAIMS about the disk, not how anything is spelled.
dir_within() {  # inner outer → 0 when inner is at or below outer
  local a b
  a=$(realpath -m -- "$(fs_path "$1")" 2>/dev/null) || return 1
  b=$(realpath -m -- "$(fs_path "$2")" 2>/dev/null) || return 1
  [[ $a == "$b" || $a == "$b"/* ]]
}

# A program cache that moved: no offer, no question about the DATA (it
# regenerates), only the one about the directory it vacated.
#
# ⭐ NO ACTION TEST (Jei s42, and the same reasoning as `relocatable`'s). s42
# dropped that gate from `relocatable` and `relocate_box` so a recreate gets the
# data questions; this function kept a private copy of it, which left a RECREATE
# box that re-points its program cache silently orphaning the old cache dir —
# offered the data move, but never the clear. The record is what earns the
# question, not which of K/m/r was chosen, and `EXD_PATH` is the record: a fresh
# create has none (line below returns), a keep box re-settles on the same
# directory (same_dir returns), so dropping the test reaches recreate and
# nothing else.
#
# ⚠️ The program cache's EXEMPTION is untouched: it is still silently
# re-pointed, still asked no move question and no [U]se/[c]hange question. The
# only thing this reaches is the s38 consent-gated clear, aimed at the VACATED
# directory, and old_pcache_offer still owns both of its safety rules —
# pcache_wipe_safe (never a directory another bind of this install also uses)
# and the running-box refusal.
relocate_pcache() {  # box new
  local box=$1 new=$2 old
  old=${EXD_PATH["$box:pcache"]:-}
  [[ -n $old ]] || return 0
  same_dir "$old" "$new" && return 0
  old_pcache_offer "$box" "$old"
  return 0
}

# ── Relocating a box's data (Jei's s41 flow) ─────────────────────────────────
# ONE PASS PER BOX, after every one of its paths is settled — not one question
# per bind as they are asked. That order is what his two examples show and it is
# the only order that works for both of them: when a common base places the
# family the paths are known before anything is asked, but when the base is
# DECLINED the new paths are the answers to the per-box prompts, so the moves
# cannot be discussed until those prompts are done.
#
# The shape of the pass:
#   1. what is being asked about, disclosed as a block (two forms, below)
#   2. one move question per bind, with two levels of "do this for all"
#   3. one collision block for the destinations that are not empty, with the
#      four courses of action and its own two levels of "apply this to all"
#   4. the moves themselves
#
# THE RULE BEHIND EVERY OUTCOME: the box is pointed where its data actually IS.
# Declined, refused, failed, or "keep old path as-is" all leave PATHS holding
# the recorded path; "use the data already at the new path" is the one answer
# that takes the new path without moving a byte.
#
# ⭐ TWO INDEPENDENT QUESTIONS (Jei s42). They were welded together until s42,
# both behind one `ACTION == modify` gate:
#
#   A  a recorded path holds content and the box will now read elsewhere
#      → "move it?"   Needs a RECORD, so: recreate and modify, never a fresh
#      create.
#   B  the path the box will now READ holds content
#      → "what should happen to what is there?"   Needs only a DESTINATION, so
#      it applies to a fresh create exactly as much as to a modify.
#
# B has two forms, chosen by whether data is landing on that destination:
#
#   form 1  [M]erge / [r]emove / [u]se / [k]eep — a move was accepted onto it.
#   form 2  [U]se / [c]hange                    — nothing is moving onto it: a
#           fresh create, or a path whose move was declined.
#
# ⭐ The disclosure above the question and the two batch questions below it are
# THE SAME in both forms, and Jei notes that is not an accident — only the
# middle changes. Declining a move therefore stops meaning "keep the old path"
# unconditionally: it means "do not carry the files over", and then an empty
# destination keeps the recorded path (the s41 invariant) while a destination
# with content earns form 2.
MOVE_ALL_BOXES=""     # y|n      — "Do this for all boxes" (the move question)
COLL_ALL_BOXES=""     # m|r|u|k  — "Apply this decision to all boxes" (form 1)
USE_ALL_BOXES=""      # u|c      — "Apply this decision to all boxes" (form 2)

# Set while relocate_box re-settles the binds a [c]hange unsettled: an
# AUTO-PLACED path is derived without a question, so creating it there would
# leave an empty directory behind every time the user changes their mind again.
# The paths that survive the last round are created by relocate_box itself, once
# nothing more can move. (Same reason set_bind_path already skips a destination
# the move pass is going to fill.)
RELOC_NO_CREATE=0

# Is this bind one the move pass is going to ask about? Both callers need the
# same answer: relocate_box, to build its list, and set_bind_path, which must
# NOT create the destination for one of them — the move makes what it needs,
# and a declined move would otherwise leave an empty directory behind at a path
# the box does not even use.
#
# ⭐ NO ACTION TEST (Jei s42, ruling 3). The question this answers is "is there
# recorded data somewhere other than where the box will now read?", and that is
# a question about a RECORD, not about which of K/m/r was chosen: a RECREATE box
# has the same ini behind it and the same bytes on the disk, so it earns the
# same question. `EXD_PATH` is the record, and detect_existing fills it for
# every box before any of that is asked — a fresh create simply has none, which
# is why ruling 2 ("A never applies to a fresh create") needs no test of its own.
# The one gate that stays is path_default's: THAT test is the recreate/modify
# divergence, and it is the whole of it.
relocatable() {  # box label new → 0 when the move pass will handle it
  local box=$1 label=$2 new=$3 old
  [[ $label != pcache ]] || return 1
  old=${EXD_PATH["$box:$label"]:-}
  [[ -n $old ]] || return 1
  same_dir "$old" "$new" && return 1
  dir_has_content "$old" || return 1
  # The pre-s41 case (new path inside the old one) counts as OWNED even though
  # it cannot be moved: the pass reports it and puts the bind back on its
  # recorded path, so the destination must not be created here either.
  return 0
}

box_labels() {  # box → its data-family labels, in bind order
  local box=$1 pair
  printf 'data'
  for pair in ${BOX_EXTRA_BINDS[$box]}; do printf ' %s' "${pair%%:*}"; done
  return 0
}

# A disclosure header: bold bright white, underlined, and NO leading blank line
# — it opens a block that sits directly under the subheader above it.
disc_hdr() { printf '  %s%s%s\n' "$C_HDR" "$1" "$RESET"; }

# The "<Box> Paths" subheader, printed by whichever of the two asks first: the
# path prompts when the family was not placed, this pass when it was. Called
# more than once per box on purpose — only the first call draws anything.
paths_hdr() {  # box
  if [[ ${PATHS_HDR:-0} -eq 0 ]]; then
    subhdr "${BOX_NAME[$1]} Paths"
    PATHS_HDR=1
  else
    say ""
  fi
  return 0
}
disc_row() { printf '  %s[%s%s%s]%s\n' "$C_TBRK" "$C_DETN" "$1" "$C_TBRK" "$RESET"; }

leaf_list() {  # label... → "program, output, input"
  local out="" l
  for l in "$@"; do
    if [[ -n $out ]]; then out+=", "; fi
    out+=$(leaf_dir "$l")
  done
  printf '%s' "$out"
  return 0
}

# Do these paths all live in ONE directory? A block that can name their shared
# parent says it once and then lists bind names; otherwise every line has to
# carry its own path. Both disclosures below take this fork, which is why the
# two forms exist at all — Jei drew both.
common_parent() {  # path... → the shared parent, or ""
  local p first="" d
  for p in "$@"; do
    d=${p%/*}
    [[ -n $d ]] || d=/
    if [[ -z $first ]]; then first=$d; continue; fi
    same_dir "$d" "$first" || return 0
  done
  printf '%s' "$first"
  return 0
}

# Put a bind back on the path its ini records — and, for the data dir, back on
# the filesystem answer that path already earned, since the probe that ran
# while it was pointed somewhere else was answering a different question.
revert_path() {  # box label old
  local box=$1 label=$2 old=$3
  PATHS["$box:$label"]=$old
  [[ $label == data ]] || return 0
  probe_fstype "$old"
  CFG_FS[$box]=$FSTYPE
  if [[ -n "${EXD_MODE[$box]:-}" ]] && overlay_hostile_fs "$FSTYPE"; then
    CFG_MODE[$box]=${EXD_MODE[$box]}
  fi
  return 0
}

# One accepted move, carried out. Returns 1 when the data did not (all) get
# there, which is the caller's signal to leave the box on its old path.
move_one() {  # box label old new mode(plain|m|r) → 0 = the box may take new
  local box=$1 label=$2 old=$3 new=$4 mode=$5
  local kb avail dstreal
  : "$box $label"
  # CROSSING A DEVICE: tell them, name both sides, ask (Jei). Priced BEFORE the
  # destructive step below, so a shortfall can never be discovered once the old
  # content is already gone.
  if ! same_device "$old" "$new"; then
    kb=$(dir_kb "$old")
    avail=$(avail_kb "$new") || avail=""
    # "remove data at new path" frees what it deletes, so the room that answer
    # really has is the free space PLUS the content it is about to remove.
    # Refusing on the pre-delete figure would decline a move that fits.
    if [[ -n $avail && $mode == r ]]; then
      avail=$(( avail + $(dir_kb "$new") ))
    fi
    if [[ -n $avail && $avail -lt $kb ]]; then
      prose "$new is on another filesystem with $(hsize "$avail") free, and $old holds $(hsize "$kb") $EMD left where it is." "$C_QTXT"
      say ""
      return 1
    fi
    prose "$old and $new are on different filesystems, so $(hsize "$kb") has to be copied across rather than renamed." "$C_QTXT"
    ask_yn "Copy it across" Y
    [[ $ANS_YN -eq 1 ]] || return 1
  fi
  dstreal=$(fs_path "$new")
  # The parent has to exist for a rename to land in it; creating it is implied
  # by the move that was just accepted, and by nothing else.
  mkdir -p -- "${dstreal%/*}" 2>/dev/null || :
  case "$mode" in
    m)
      merge_into "$old" "$new" || :
      # Nothing moved at all → the data is still where it was, and so is the
      # box. Anything moved → the box follows it, and whatever mv refused is
      # named along with the directory it is still in.
      [[ $MERGE_MOVED -eq 0 ]] && return 1
      [[ $MERGE_KEPT -eq 0 ]] || subnote "the rest is still in $old"
      return 0 ;;
    r)
      # The only destructive branch. $HOME and / are refused outright, the same
      # two the cache wipe refuses, and for the same reason.
      case "$dstreal" in
        /|"$HOME") subnote "refusing to remove the data at $new"; return 1 ;;
      esac
      if ! rm -rf -- "$dstreal"; then
        warn "could not empty $new $EMD left where it is"
        return 1
      fi ;;
  esac
  # An empty (or vacated) destination takes ONE whole-directory move.
  if ! run_mv "$old" "$new"; then
    mv_said
    return 1
  fi
  return 0
}

# ⭐ RE-ENTERABLE, not a straight-line pass (Jei s42). [c]hange drops a path
# back into the ordinary settle route, and path_derived hangs every other bind
# of the box off the parent of its program dir — so changing that one path
# UNSETTLES the rest, and they have to come back round for the same questions.
# Hence rounds: a round asks about the labels in scope, and a [c]hange puts what
# it unsettled into the next round's scope. Nothing accumulates per round (the
# re-derived paths are not created until the rounds are over — RELOC_NO_CREATE),
# and nothing MOVES until they are either, because a move executed in round 1
# could be aimed at a destination round 2 walks away from.
relocate_box() {  # box
  local box=$1 label old new i n parent ans first word askall ask_use in_scope in_chg
  local ask_coll carried_dec dec_i leaf
  local box_ans="" box_coll="" box_use=""   # this box's batched answers
  local -a labels=() olds=() news=() moving=() coll=() dec=()
  local -a scope=() nextscope=() chg=() b2=() bpaths=() mkq=()
  local -A COLL_AT=()   # index → 1 for the binds whose destination has files
  # Carried ACROSS rounds, keyed by label: the move answer and the two paths it
  # is about (M_*), form 1's course of action (M_DEC), form 2's [U]se (B_NEW),
  # and which labels the user has already changed once (CHANGED — a batched
  # [c]hange must never auto-answer a path it already changed, or "apply to all"
  # becomes a loop with no way out of it).
  local -A A_MOVE=() M_OLD=() M_NEW=() M_DEC=() B_NEW=() CHANGED=()
  local ask_moves=1
  for label in $(box_labels "$box"); do scope+=("$label"); done

 while [[ ${#scope[@]} -gt 0 ]]; do
  labels=() olds=() news=() moving=() coll=() dec=() b2=() nextscope=() COLL_AT=()
  # Which binds have their files somewhere other than where the box will now
  # read them from? Spelling never decides this: ~/appdata/comfyui and
  # /home/you/appdata/comfyui are one directory.
  for label in "${scope[@]}"; do
    old=${EXD_PATH["$box:$label"]:-}
    new=${PATHS["$box:$label"]:-}
    [[ -n $old && -n $new ]] || continue
    # THE PRE-s41 LAYOUT WALKS INTO THIS: a box whose data dir IS <base>/<box>
    # derives <base>/<box>/program, which is INSIDE it — and `mv` refuses to
    # move a directory into its own subdirectory (measured: "cannot move 'x' to
    # a subdirectory of itself"). Reported BEFORE any question, because the only
    # answer a question here could earn is an error message. What it actually
    # needs is a per-entry move that steps around the box's other binds, and
    # Jei ruled that out of scope: "I can manually fix my boxes."
    relocatable "$box" "$label" "$new" || continue
    if dir_within "$new" "$old"; then
      subnote "$new is inside $old $EMD left as it is (move it by hand to split them)."
      revert_path "$box" "$label" "$old"
      continue
    fi
    labels+=("$label") olds+=("$old") news+=("$new")
  done
  n=${#labels[@]}
  # A RUNNING box is refused with the reason — "same as cache" (Jei) — once, for
  # the whole box. Its data is under a live mount, and every fix needs the box
  # restarted anyway. Asked only when there is something to move: question B
  # moves no bytes, so a running box is no reason to withhold it.
  if [[ $n -gt 0 ]] && [[ $(box_state "$box") == ACTIVE ]]; then
    subnote "$(box_ctr "$box") is running $EMD stop it, then re-run to move its data."
    for (( i = 0; i < n; i = i + 1 )); do revert_path "$box" "${labels[i]}" "${olds[i]}"; done
    return 0
  fi

  # ── 1. Where those files are now ──────────────────────────────────────────
  # A box whose answer was settled by an earlier "Do this for all boxes" is
  # asked NOTHING here, and everything that block exists for goes with the
  # question: disclosing where the files are and explaining that a move is
  # needed are both setups for a decision this box does not get to make (Jei:
  # "if we are skipping because it's already answered, we really shouldn't be
  # showing any of that; it all becomes irrelevant"). What survives is a
  # RECEIPT — one line per bind, naming what moved and where — printed after
  # the questions that would have been asked, further down.
  # box_ans joins MOVE_ALL_BOXES here for the same reason and by the same rule:
  # in a LATER round (a [c]hange re-settled something) the box-wide batch has
  # already answered for whatever came back round, so the disclosure and the
  # sentence above it are setups for a question that will not be asked. It is
  # always empty on the first round, where this reads exactly as it always did.
  ask_moves=1
  [[ -z $MOVE_ALL_BOXES && -z $box_ans ]] || ask_moves=0
  if [[ $n -gt 0 && $ask_moves -eq 1 ]]; then
    paths_hdr "$box"
    parent=$(common_parent "${olds[@]}")
    if [[ -n $parent ]]; then
      disc_hdr "Current data file paths in $parent:"
      disc_row "$(leaf_list "${labels[@]}")"
    else
      disc_hdr "Current data file paths:"
      for (( i = 0; i < n; i = i + 1 )); do
        disc_row "$box $(leaf_word "${labels[i]}"): ${olds[i]}"
      done
    fi
    say ""
    prose "To use current, active data with new path(s), that data will need to be moved." "$C_QTXT"
  fi

  # ── 2. The move questions ─────────────────────────────────────────────────
  # The two batch questions are offered ONCE, straight after the first answer,
  # and they carry THAT answer — yes or no alike (Jei: "even a 'no' above
  # propagates"). "all boxes" is only reached when the box-wide one was taken.
  for (( i = 0; i < n; i = i + 1 )); do
    if [[ -n $box_ans ]]; then moving+=("$box_ans"); continue; fi
    if [[ -n $MOVE_ALL_BOXES ]]; then moving+=("$MOVE_ALL_BOXES"); continue; fi
    ask_yn "Move $(leaf_word "${labels[i]}") to new path (${news[i]})" Y
    ans=$ANS_YN
    moving+=("$ans")
    [[ $i -eq 0 ]] || continue
    if [[ $n -gt 1 ]]; then
      # A box with ONE data path has nothing to apply this to, so it is not
      # asked — the all-boxes question below is offered on its own instead.
      ask_yn "Do this for $(emphc "$C_EMPTH" "all data paths") for $box" Y
      [[ $ANS_YN -eq 1 ]] || continue
      box_ans=$ans
    fi
    # Jei marked "all boxes" up ONCE, on the collision batch, and this line
    # carries the identical phrase for the identical purpose — so it gets the
    # identical shade rather than a second, unnamed one.
    ask_yn "Do this for $(emphc "$C_EMBOX" "all boxes")" Y
    [[ $ANS_YN -eq 1 ]] && MOVE_ALL_BOXES=$ans
  done
  # Carried out of the round, because nothing is moved until every round is
  # over: a [c]hange in the block below can re-derive a destination this round
  # already asked about, and a move already made cannot be re-aimed.
  for (( i = 0; i < n; i = i + 1 )); do
    A_MOVE[${labels[i]}]=${moving[i]}
    M_OLD[${labels[i]}]=${olds[i]}
    M_NEW[${labels[i]}]=${news[i]}
  done

  # ── 3. FORM 1: destinations that are not empty, WITH data landing on them ──
  # The `moving` scope is the whole difference between the two forms — it is
  # what earns the four-way menu, because there are two sets of files to
  # reconcile. Everything it excludes is form 2's, below: a path with content
  # and nothing coming to meet it.
  #
  # Found HERE, ABOVE the receipt rather than down in the block it feeds: a
  # course of action that is ALREADY DECIDED changes what the receipt has to
  # say, and [u]se and [k]eep reverse the move outright.
  for (( i = 0; i < n; i = i + 1 )); do
    [[ ${moving[i]} -eq 1 ]] || continue
    if dir_has_content "${news[i]}"; then coll+=("$i"); COLL_AT[$i]=1; fi
  done
  # ⭐ THE BLOCK IS DRAWN IF, AND ONLY IF, A PROMPT WILL FOLLOW IT. Everything
  # in it — the disclosure, the Options list, the warning — exists to set up a
  # question, so when an earlier batch has already answered for every entry
  # there is nothing to set up and "it all becomes irrelevant" (Jei s41, ruling
  # on the move block; the collision batch could not carry a box yet when he
  # said it). Drawn anyway it is byte-identical to a live menu that then asks
  # nothing at all — the defect shipped in `f06118f`. Two cases, one code path:
  # a box carried by the MOVE batch is NOT decided here and must still be asked
  # (verified before this change: it always was), while a box carried by the
  # COLLISION batch is decided and gets the receipt below instead.
  ask_coll=1
  carried_dec=""
  if [[ ${#coll[@]} -gt 0 && ( -n $box_coll || -n $COLL_ALL_BOXES ) ]]; then
    ask_coll=0
    carried_dec=${box_coll:-$COLL_ALL_BOXES}
  fi

  # ── 3b. The receipt for whatever this box was not asked (Jei's line) ──────
  # One line per bind, naming the decision that was made for it:
  #   ask_moves 0 → the move answer came from an earlier box — what is moving
  #   ask_coll  0 → the course of action did too — what happens where it lands
  # A bind can be owed both, and a DECIDED course of action subsumes the move
  # line rather than following it: each of the four sentences below names the
  # old path itself, so printing "will be moved to <new>" above it would say
  # the same thing twice — and for [u]se / [k]eep it would be false outright,
  # since both reverse the move.
  #
  # ⭐ WORDING RULED BY JEI (s43), and the three things he cut are the point:
  #   no box name   — "there's a giant banner a few lines up" (the box header
  #                   is on screen, and paths_hdr repeats it directly above)
  #   no new path   — it is named in the summary box a few lines below, and in
  #                   the question itself for the box that was actually asked
  #   the leaf, not the display word — `program`, `output`, `input`, the same
  #                   tokens leaf_list uses in the disclosure this refers back
  #                   to. So it is leaf_dir here, NOT leaf_word ("program data"
  #                   would read "program data path").
  if [[ $ask_moves -eq 0 || $ask_coll -eq 0 ]]; then
    first=1
    for (( i = 0; i < n; i = i + 1 )); do
      [[ ${moving[i]} -eq 1 ]] || continue
      dec_i=${COLL_AT[$i]:+$carried_dec}
      # Nothing owed: the move question was asked and this destination is empty.
      [[ $ask_moves -eq 0 || -n $dec_i ]] || continue
      # The header once, above the first line — not between every pair of them.
      if [[ $first -eq 1 ]]; then first=0; paths_hdr "$box"; fi
      leaf=$(leaf_dir "${labels[i]}")
      # ⚠️ ask_choice hands back the LOWERCASE letter, "Mruk" default included:
      # the four decisions are m/r/u/k here, not M/r/u/k as the menu spells them.
      case "$dec_i" in
        m) prose "Merging current $leaf path [${olds[i]}] into new path." "$C_QTXT"
           continue ;;
        r) prose "Replacing new path with current $leaf path [${olds[i]}]." "$C_QTXT"
           continue ;;
        # ⚠️ [u]se is the ONE decision the move pass also reports on, with a
        # `-> <old> is left where it is` outcome line a few lines below. Naming
        # the path here too said it twice, so this clause stays generic and the
        # outcome line does the naming (Jei, s43).
        u) prose "Using data at new path for $leaf; leaving old path as-is." "$C_QTXT"
           continue ;;
        k) prose "Continuing to use current $leaf path [${olds[i]}] as-is." "$C_QTXT"
           continue ;;
      esac
      # Only the move was carried; the collision (if any) is still asked below.
      # This is the line Jei ruled in s41 and it is deliberately untouched.
      if [[ $ask_moves -eq 0 ]]; then
        word=$(leaf_word "${labels[i]}")
        prose "${word^} for $box will be moved to ${news[i]}." "$C_QTXT"
      fi
    done
  fi

  if [[ ${#coll[@]} -gt 0 ]]; then
   if [[ $ask_coll -eq 1 ]]; then
    local -a cpaths=() clabels=()
    for i in "${coll[@]}"; do cpaths+=("${news[i]}") clabels+=("${labels[i]}"); done
    say ""
    parent=$(common_parent "${cpaths[@]}")
    # "new BASE path" is only the right words for the directory the family was
    # actually placed at. Two typed paths can share a parent by accident —
    # /srv/input and /srv/output share /srv — and calling that a base path would
    # name something the user never chose (Jei's second example lists those two
    # separately). So the shared form is used only for the box's own directory.
    if [[ -n $parent ]] && same_dir "$parent" "$(data_root)/$box"; then
      disc_hdr "There are existing files at new base path $parent:"
      disc_row "$(leaf_list "${clabels[@]}")"
    else
      disc_hdr "There are existing files at new path(s):"
      for i in "${coll[@]}"; do
        disc_row "$box $(leaf_word "${labels[i]}"): ${news[i]}"
      done
    fi
    say ""
    # ⚠️ What is there may belong to ANOTHER BOX — asked about, never vetoed:
    # "that's the user's call" (Jei). The disclosure above IS the guard.
    disc_hdr "Options"
    opt_row M "erge existing, active data into new path (replace when overlapping)" "" 0 "$(isdef M Mruk)"
    opt_row r "emove data at new path, then move existing, active data to new path" "" 0 "$(isdef r Mruk)"
    opt_row u "se the data already at the new path (stop using existing data)" "" 0 "$(isdef u Mruk)"
    opt_row k "eep old path as-is" "" 0 "$(isdef k Mruk)"
    # Only when a base was elected is there a shared base to forgo (Jei).
    if [[ $DATA_AUTO -eq 1 ]]; then
      prose "*Warning: If you choose to keep the old path, this forgoes the shared base path." "$C_WARNI"
    fi
    say ""
   fi
    first=1
    for i in "${coll[@]}"; do
      if [[ -n $box_coll ]]; then dec[i]=$box_coll; continue; fi
      if [[ -n $COLL_ALL_BOXES ]]; then dec[i]=$COLL_ALL_BOXES; continue; fi
      ask_choice "Select a course of action for the $(emphc "$C_EMLBL" "$(leaf_word "${labels[i]}") path") [M/r/u/k]" "Mruk"
      dec[i]=$ANS_CH
      [[ $first -eq 1 ]] || continue
      first=0
      if [[ ${#coll[@]} -gt 1 ]]; then
        ask_yn "Apply this decision to all overlapping new $box paths" Y
        [[ $ANS_YN -eq 1 ]] || continue
        box_coll=${dec[i]}
      fi
      ask_yn "Apply this decision to $(emphc "$C_EMBOX" "all boxes")" Y
      [[ $ANS_YN -eq 1 ]] && COLL_ALL_BOXES=${dec[i]}
    done
    for i in "${coll[@]}"; do M_DEC[${labels[i]}]=${dec[i]}; done
  fi

  # ── 4. FORM 2: a path the box will now read that already holds data, with
  #       nothing moving onto it ────────────────────────────────────────────
  # Every settled path of the box is in view here, not just the ones a move was
  # accepted for — that scope is exactly what s41 got wrong. Three tests, in the
  # order they cost:
  #   · a move is landing on it → form 1 asked already (or the destination was
  #     empty, and there was nothing to ask)
  #   · the box already reads it → nothing is "new" about this path, and a keep
  #     box (whose PATHS are seeded straight from EXD_PATH) never gets past here
  #   · it has content → otherwise there is nothing to decide about
  for label in "${scope[@]}"; do
    new=${PATHS["$box:$label"]:-}
    [[ -n $new ]] || continue
    if [[ ${A_MOVE[$label]:-0} -eq 1 ]]; then continue; fi
    old=${EXD_PATH["$box:$label"]:-}
    if [[ -n $old ]] && same_dir "$old" "$new"; then continue; fi
    dir_has_content "$new" || continue
    b2+=("$label")
  done
  if [[ ${#b2[@]} -gt 0 ]]; then
    bpaths=()
    for label in "${b2[@]}"; do bpaths+=("${PATHS["$box:$label"]}"); done
    # ❓ OPEN IN THE PLAN, decided here the way a carried MOVE already goes and
    # FLAGGED FOR JEI: a box whose answer an earlier "all boxes" already gave is
    # asked nothing, so the block that sets that question up "all becomes
    # irrelevant" (his s41 words) and a one-line receipt per bind stands in for
    # it. A carried [c]hange prints none, exactly as a carried "no" to the move
    # question prints none — the path prompt that follows says it itself.
    # FORM 1 NOW AGREES: it draws its block on the same rule, below the same
    # kind of receipt.
    #
    # ⭐ THE RULE, stated as a property rather than as a list of cases: draw the
    # block if and only if a prompt will follow it. An entry is prompted when
    # the user CHANGED it once already (a batched answer must never re-answer
    # that, or a carried [c]hange loops with no way out) or when neither batch
    # holds an answer yet. `box_use` counts towards that and the earlier
    # USE_ALL_BOXES-only test missed it — a box-wide batch settled in an
    # earlier round could draw the block and then ask nothing, which is exactly
    # form 1's defect wearing form 2's clothes.
    ask_use=0
    for label in "${b2[@]}"; do
      if [[ -n ${CHANGED[$label]:-} ]]; then ask_use=1; continue; fi
      [[ -n $box_use || -n $USE_ALL_BOXES ]] || ask_use=1
    done
    if [[ $ask_use -eq 0 && ${box_use:-$USE_ALL_BOXES} == u ]]; then
      first=1
      for label in "${b2[@]}"; do
        if [[ $first -eq 1 ]]; then first=0; paths_hdr "$box"; fi
        # Form 1's [u]se sentence MINUS its trailing clause. Same decision, but
        # nothing is moving onto this destination, so there is no "current"
        # path being left behind to name — on a fresh create there is no old
        # path at all. ⚠️ NOT ruled: Jei's s43 wording was given for form 1.
        # The two forms are meant to read alike, so this follows it; the clause
        # is the one part that cannot be true here.
        leaf=$(leaf_dir "$label")
        prose "Using data at new path for $leaf." "$C_QTXT"
      done
    fi
    if [[ $ask_use -eq 1 ]]; then
      # ⭐ THE TOP AND THE BOTTOM ARE FORM 1'S, VERBATIM (Jei: "that is not an
      # accident"). Same two disclosure shapes on the same base-vs-parent test,
      # same Options header, same "Select a course of action for the <label>
      # path" line, same two batch questions. Only the menu between is new.
      paths_hdr "$box"
      parent=$(common_parent "${bpaths[@]}")
      if [[ -n $parent ]] && same_dir "$parent" "$(data_root)/$box"; then
        disc_hdr "There are existing files at new base path $parent:"
        disc_row "$(leaf_list "${b2[@]}")"
      else
        disc_hdr "There are existing files at new path(s):"
        for label in "${b2[@]}"; do
          disc_row "$box $(leaf_word "$label"): ${PATHS["$box:$label"]}"
        done
      fi
      say ""
      disc_hdr "Options"
      opt_row U "se this path anyway (data will be used / changed by the box)" "" 0 "$(isdef U Uc)"
      opt_row c "hange to a different path" "" 0 "$(isdef c Uc)"
      # Same rule as form 1's warning — only an ELECTED base can be forgone —
      # and only the clause naming the option that would forgo it differs.
      if [[ $DATA_AUTO -eq 1 ]]; then
        prose "*Warning: If you change to another path, this forgoes the shared base path." "$C_WARNI"
      fi
      say ""
    fi
    first=1
    for label in "${b2[@]}"; do
      ans=""
      # A batched answer never auto-answers a path THIS USER ALREADY CHANGED:
      # a carried [c]hange would otherwise re-ask that path for ever, with no
      # prompt left that could say "stop, use it".
      if [[ -z ${CHANGED[$label]:-} ]]; then
        if [[ -n $box_use ]]; then
          ans=$box_use
        elif [[ -n $USE_ALL_BOXES ]]; then
          ans=$USE_ALL_BOXES
        fi
      fi
      if [[ -z $ans ]]; then
        ask_choice "Select a course of action for the $(emphc "$C_EMLBL" "$(leaf_word "$label") path") [U/c]" "Uc"
        ans=$ANS_CH
        # ⚠️ NOT RULED BY JEI — ours (s42), flagged in the report for him.
        # "Change to a different path" cannot be applied to a SET: every path
        # needs its own new answer, and every box needs its own again. So
        # neither batch question is offered after a [c]hange. `first` is not
        # spent either — the offer moves to the first answer that CAN be
        # batched, rather than being lost because a [c]hange came first.
        if [[ $first -eq 1 && $ans != c ]]; then
          first=0
          askall=1
          if [[ ${#b2[@]} -gt 1 ]]; then
            ask_yn "Apply this decision to all overlapping new $box paths" Y
            if [[ $ANS_YN -eq 1 ]]; then box_use=$ans; else askall=0; fi
          fi
          if [[ $askall -eq 1 ]]; then
            ask_yn "Apply this decision to $(emphc "$C_EMBOX" "all boxes")" Y
            if [[ $ANS_YN -eq 1 ]]; then USE_ALL_BOXES=$ans; fi
          fi
        fi
      fi
      if [[ $ans == c ]]; then
        CHANGED[$label]=1
        nextscope+=("$label")
      else
        B_NEW[$label]=1
      fi
    done
  fi

  # ── 5. What a [c]hange unsettled ──────────────────────────────────────────
  # ⭐ "Paths", PLURAL, is load-bearing (Jei): path_derived hangs every other
  # bind of the box off the parent of its settled program dir, so changing the
  # program path re-derives input/output/workspace — they are unsettled too, and
  # every answer already given about them is about a path that no longer exists
  # as an answer. So they go back in scope with their state dropped.
  chg=(${nextscope[@]+"${nextscope[@]}"})   # the ones the user changed HIMSELF
  if [[ ${#nextscope[@]} -gt 0 ]]; then
    for word in "${chg[@]}"; do
      if [[ $word == data ]]; then
        nextscope=()
        for label in $(box_labels "$box"); do nextscope+=("$label"); done
        break
      fi
    done
    for label in "${nextscope[@]}"; do
      unset "A_MOVE[$label]" "M_OLD[$label]" "M_NEW[$label]" \
            "M_DEC[$label]" "B_NEW[$label]"
    done
    # Back through the ORDINARY settle route, in bind order — the changed path
    # forced to its prompt, the ones it dragged with it taking whatever that
    # route gives them (a re-derivation when the family was placed, a prompt of
    # their own when it was not). Nothing is created for a re-derived path yet:
    # the next round may walk away from it.
    for label in $(box_labels "$box"); do
      in_scope=0 in_chg=0
      for word in "${nextscope[@]}"; do
        if [[ $word == "$label" ]]; then in_scope=1; fi
      done
      [[ $in_scope -eq 1 ]] || continue
      for word in "${chg[@]}"; do
        if [[ $word == "$label" ]]; then in_chg=1; fi
      done
      if [[ $in_chg -eq 1 ]]; then
        set_bind_path "$box" "$label" 1
      else
        RELOC_NO_CREATE=1
        set_bind_path "$box" "$label"
        RELOC_NO_CREATE=0
        mkq+=("$label")
      fi
    done
  fi
  scope=(${nextscope[@]+"${nextscope[@]}"})
 done

  # ── 6. The moves ──────────────────────────────────────────────────────────
  # Deferred to here so that every path is final: a destination re-derived by a
  # [c]hange in a later round would otherwise be moved onto before it was known.
  for label in $(box_labels "$box"); do
    [[ -n ${M_OLD[$label]:-} ]] || continue
    old=${M_OLD[$label]} new=${M_NEW[$label]}
    if [[ ${A_MOVE[$label]:-0} -ne 1 ]]; then
      # ⭐ A DECLINED MOVE IS NO LONGER "keep the old path" UNCONDITIONALLY
      # (Jei s42): it means the files are not carried over. An empty destination
      # then keeps the recorded path, the s41 invariant; a [U]se from form 2
      # points the box at the new path and reads what is already there — and the
      # directory left behind is NAMED, for the same reason the `u` branch names
      # it below.
      if [[ -n ${B_NEW[$label]:-} ]]; then
        subnote "$old is left where it is $EMD nothing was moved."
      else
        revert_path "$box" "$label" "$old"
      fi
      continue
    fi
    case "${M_DEC[$label]:-plain}" in
      # Nothing moves. The box reads the directory that is already there — and
      # the directory it came from is NAMED, because a bind quietly pointed away
      # from a full data dir is the whole bug this feature exists to fix.
      u) subnote "$old is left where it is $EMD nothing was moved." ;;
      k) revert_path "$box" "$label" "$old" ;;
      *) move_one "$box" "$label" "$old" "$new" "${M_DEC[$label]:-plain}" \
           || revert_path "$box" "$label" "$old" ;;
    esac
  done
  # The directories a [c]hange re-derived and this pass held back: made only now
  # that no further answer can abandon them, and only where nothing else (a
  # move, or the path having been there all along) has already made them.
  for label in ${mkq[@]+"${mkq[@]}"}; do
    new=${PATHS["$box:$label"]:-}
    [[ -n $new ]] || continue
    [[ -d $(fs_path "$new") ]] && continue
    ensure_dir "$new" || :
  done
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
  # The "<Box> Paths" subheader belongs to whichever of the two asks first: the
  # path prompts when the family was NOT placed, the move questions when it was
  # (a box can have nothing to ask about its paths and still have files to move).
  PATHS_HDR=0
  # The banner is drawn before the box is asked anything, so it asks the
  # DEFAULTS what its summary box is going to need and widens to match (choice
  # L) — the two stack, and the pair is read as one object.
  banner "${BOX_BANNER[$box]}" bold "$(predict_card_inner "$box")"
  bw=$BANNER_W

  # Which of this box's questions are still open? The data dir is skipped when
  # General Setup placed the family (and its input/output/workspace leaves are
  # never asked at all — they nest inside it); the port when the defaults were
  # accepted wholesale; the two start questions unless their install-wide answer
  # was "case-by-case" (and, for host boot, unless this box serves).
  #
  # The PROGRAM-CACHE question is deliberately NOT in this list: it joins a
  # section that already exists and never opens one of its own (Jei s38 J), so
  # a box whose only open question is its cache path shows the question bare
  # under its banner, with the summary box flush beneath it — the s38 mock.
  # set_bind_path/auto_label decide whether it is asked at all.
  local -a todo=()
  local want_port=0 want_sv=0
  [[ $DATA_AUTO -eq 0 ]] && todo+=(data)
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
    PATHS_HDR=1
  fi
  set_bind_path "$box" data
  for pair in ${BOX_EXTRA_BINDS[$box]}; do
    label=${pair%%:*} dest=${pair#*:}
    : "$dest"          # the container side is the emitters' business, not ours
    set_bind_path "$box" "$label"
  done
  # LAST, and after the data dir on purpose: every leaf default reads the data
  # path that was just settled, and the cache question is the one the stale
  # offer below depends on (it asks about the dir this answer names).
  set_bind_path "$box" pcache
  # EVERY path of this box is settled now, which is the only moment the move
  # questions can be asked as one block: when the base was declined, the new
  # paths ARE the answers to the prompts above (Jei's second example).
  relocate_box "$box"
  stale_cache_offer "$box"

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

# The width that summary box is GOING to want, worked out from the defaults
# before the box is asked anything (choice L) — the banner takes it as its floor
# so the two stack flush. Same arithmetic as summary_box's own widest-row pass,
# on the values path_default() would offer: a run that accepts them (or never
# asks) matches exactly, and a path typed LONGER than its default still widens
# the card past the banner, which is what an overlong value has always done.
# The Server rows are included for completeness; a port never sets the width.
predict_card_inner() {  # box → inner width, capped at the screen
  local box=$1 pair label v w inner=0 avail
  local -a vals=()
  # Measured in the spelling that will be PRINTED — which is the spelling that
  # will be OFFERED, since the card and the prompt show the one stored string.
  # A ~ is four columns narrower than the home it stands for, so measuring an
  # expansion would have mis-sized the card the moment either could differ.
  vals+=("$(path_default "$box" data)")
  for pair in ${BOX_EXTRA_BINDS[$box]}; do
    label=${pair%%:*}
    vals+=("$(path_default "$box" "$label")")
  done
  vals+=("${EXD_PORT[$box]:-${BOX_HOST_PORT[$box]}}")
  for v in "${vals[@]}"; do
    w=$(( 4 + SUM_HDR_W + ${#v} ))
    [[ $w -gt $inner ]] && inner=$w
  done
  avail=$(( $(disp_width) - 4 ))
  [[ $inner -gt $avail ]] && inner=$avail
  printf '%s' "$inner"
}

summary_box() {  # box banner-width
  local box=$1 bw=$2 inner avail pair label
  local -a keys=() vals=() kind=()
  keys+=("Paths") vals+=("") kind+=(g)
  # Verbatim: kept from the ini, typed at the prompt or derived from the
  # resource path, PATHS holds the spelling that was chosen for it.
  keys+=("${BIND_ROW[data]}:") vals+=("${PATHS["$box:data"]}") kind+=(v)
  for pair in ${BOX_EXTRA_BINDS[$box]}; do
    label=${pair%%:*}
    keys+=("${BIND_ROW[$label]}:") vals+=("${PATHS["$box:$label"]}") kind+=(v)
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
  printf '    %s%s%s %s%s detected%s %s using %s%s%s for %s%s.%s\n' \
    "$C_ARROW" "$ARROW_M" "$RESET" "$C_SUBJ" "$fs" "$C_TEXT" "$EMD" \
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
  local box=$1 f base pair label dest vols spell flags data
  f=$(ini_file "$box")
  base=$(basename "$f")     # resolved OUTSIDE the redirect (it names the file)
  data=${PATHS["$box:data"]}
  {
    printf '# %s — generated by droste-setup.sh on %s\n' "$base" "$(date +%F)"
    printf '# Create/recreate with:  distrobox assemble create --file %s\n' "$f"
    printf '# Modeled on targets/%s/distrobox.ini (droste-ai-halo repo).\n' "$box"
    printf '# ONE container, two doors: "distrobox enter %s" for an\n' "$(box_ctr "$box")"
    printf '# interactive shell, "podman start %s" to bring the\n' "$(box_ctr "$box")"
    printf '# service up (the init hook reads %s/server.env\n' "$data"
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
    #
    # TWO LINES ARE BUILT AT ONCE (s39): $vols carries the RESOLVED sources
    # podman binds, $spell the SAME binds in the spelling their owner wrote.
    # Every write re-resolves from the spelling rather than copying forward the
    # last expansion, which is what makes "move home, re-run" land the binds in
    # the new one — podman bakes the source absolutely at create time, so a run
    # is the only moment a ~ can be re-read.
    vols="$(fs_path "$data"):/opt/data"
    spell="$data:/opt/data"
    # The box's PROGRAM CACHE root, right behind its data dir: the venv overlay
    # upper lives here, so without this bind the environment a `pip install`
    # writes lands in the container layer and dies with the next recreate. It is
    # not a BOX_EXTRA_BIND (nobody is asked about it as a work dir), so the bind
    # is written here, by name, for every box.
    vols="$vols $(fs_path "${PATHS["$box:pcache"]}"):/opt/program-cache"
    spell="$spell ${PATHS["$box:pcache"]}:/opt/program-cache"
    for pair in ${BOX_EXTRA_BINDS[$box]}; do
      label=${pair%%:*} dest=${pair#*:}
      vols="$vols $(fs_path "${PATHS["$box:$label"]}"):$dest"
      spell="$spell ${PATHS["$box:$label"]}:$dest"
    done
    # Shared compute cache (MIOpen/Triton/torch/vLLM kernels) — appended into
    # the same value (remove to keep caches per-box).
    vols="$vols $(fs_path "$COMPUTE_CACHE"):/opt/caches"
    spell="$spell $COMPUTE_CACHE:/opt/caches"
    # A non-default HF cache (outside the auto-bound host home) needs an
    # explicit bind to the in-box expected location — also same value.
    # BOTH sides are compared PHYSICALLY: an aliased home makes
    # /srv/.cache/huggingface and /home/me/.cache/huggingface the same
    # directory spelled two ways, and binding a directory over itself under a
    # name the box does not have is worse than not binding it at all.
    if ! same_dir "$HF_CACHE" "$USER_HOME/.cache/huggingface"; then
      vols="$vols $(fs_path "$HF_CACHE"):$USER_HOME/.cache/huggingface"
      spell="$spell $HF_CACHE:$USER_HOME/.cache/huggingface"
    fi
    # Opted-in read-only model collection: the dir was confirmed-or-created at
    # prompt time, so the :ro bind is safe (a bind to a missing dir would be
    # fatal to `distrobox assemble create`). It lands INSIDE the single volume=.
    if [[ -n $MODELS_DIR ]]; then
      vols="$vols $(fs_path "$MODELS_DIR"):/opt/models:ro"
      spell="$spell $MODELS_DIR:/opt/models:ro"
    fi
    printf '# /opt/data = this box%s PERSISTENT state (your work, the seeded\n' "'s"
    printf '# configs, server.env) — never wiped. /opt/program-cache = its PROGRAM\n'
    printf '# CACHE (venv upper, scratch, per-box caches) — the installer offers to\n'
    printf '# empty it when it finds an older generation there.\n'
    printf '# Shared compute caches across ALL droste boxes are folded into the\n'
    printf '# single volume= value below (distrobox reads only the LAST volume=).\n'
    printf 'volume="%s"\n' "$vols"
    # The spelling record, read back by parse_existing_ini. It is a COMMENT on
    # purpose: podman 5.4.2 binds a source only when it starts with / or ./ —
    # anything else (a ~, a $HOME) becomes a NAMED VOLUME called that, and
    # distrobox 2.x does no expansion of its own at all (1.x expanded only as a
    # side effect of `eval`-ing the assembled command). So the line distrobox
    # acts on stays absolute, and the line that remembers what the user wrote
    # sits beside it. volume= WINS if they ever disagree (Jei s39).
    #
    # The reader of the ini meets that line too, so the file explains it:
    # an undocumented machine-looking comment is exactly the kind of thing a
    # hand-editor either maintains needlessly or deletes.
    printf '# The sources above are spelled out in full because that is what podman\n'
    printf '# binds: a source that does not begin with / or ./ is taken as the NAME\n'
    printf '# of a named volume, so a ~ there would quietly stop being a bind. The\n'
    printf '# line below records the same binds in the spelling you gave them —\n'
    printf '# droste-setup.sh reads it back to show you your own paths on the next\n'
    printf '# run, and rewrites it from your answers every time, so there is nothing\n'
    printf '# to maintain by hand. Change a bind in volume= and it takes effect:\n'
    printf '# volume= WINS when the two disagree, and the record below simply stops\n'
    printf '# naming that directory.\n'
    printf '# droste-setup: spelled="%s"\n' "$spell"
    if [[ ${BOX_HAS_MODELS[$box]} -eq 1 ]]; then
      if [[ -n $MODELS_DIR ]]; then
        printf '# The read-only local model collection (%s -> /opt/models:ro)\n' \
          "$MODELS_DIR"
        printf '# is already included in the single volume= value above.\n'
      else
        # Not opted in: the share has no default location (the prompt's default
        # is the word "None"), and a read-only /opt/models bind to a missing dir
        # is fatal to `distrobox assemble create` — so nothing is added here.
        # Re-run droste-setup.sh and give it a path, or add the bind by hand:
        printf '# Optional read-only local model collection (none configured — the\n'
        printf '# installer asks for a path, and None means no bind). To enable, name\n'
        printf '# YOUR collection and APPEND\n'
        # ABSOLUTE on purpose: this line is copied INTO volume=, where podman
        # 5.4.2 takes a source that does not start with / or ./ as the NAME of a
        # named volume — a ~ here would silently stop being a bind mount.
        printf '#   %s:/opt/models:ro\n' "$HOME/models"
        printf '# (space-separated) INSIDE the single volume= value above — do NOT add a\n'
        printf '# second volume= line (distrobox reads only the LAST, dropping the rest).\n'
      fi
    fi
  } > "$(fs_path "$f")"
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
#
# The rewrite carries NOTHING over: the two keys it writes are the two it asked
# about, and any other key a user put in the file by hand is a key the box's
# serve library ignores (it reads STARTUP_ENABLED/SERVE and PORT and nothing
# else), so there is nothing here worth preserving across a run that was told to
# reconfigure.
#
# ⭐ THIS IS THE WRITE HALF OF THE s45 KEY MIGRATION: read tolerantly, write the new
# form. The old key was `SERVE`, which meant "start at box start" AND "is supposed to
# be serving" at the same time; it is now `STARTUP_ENABLED` and means only the first.
# A rewritten file carries the new key ALONE — dropping `SERVE` is safe precisely
# because the box's library still reads it as a fallback.
# 🚨 THAT FALLBACK IS WHAT MAKES THIS SAFE, AND IT MUST NOT BE REMOVED IN THE SAME
# RELEASE. A box the user KEEPS is never rewritten (keep = "change nothing about
# settings"), so live boxes go on carrying `SERVE=1` until some later modify run
# touches them — and if the library stopped reading it, every one of those boxes would
# silently stop serving with nothing saying why.
emit_serve_env() {  # box
  local box=$1 f
  f=$(serve_env_file "$box") || return 0
  [[ -n $f ]] || return 0
  f=$(fs_path "$f")      # the box's data dir, as the kernel needs it spelled
  mkdir -p "$(dirname "$f")" 2>/dev/null || :
  {
    printf '# server.env — read by droste-init-hook.sh at every container start.\n'
    printf '# Written by droste-setup.sh on %s; safe to edit by hand:\n' "$(date +%F)"
    printf '#   STARTUP_ENABLED=1  start this box'"'"'s server when the BOX starts\n'
    printf '#                      (0 = interactive only, nothing is launched)\n'
    printf '#   PORT=              the port the server binds (host networking: no remap)\n'
    printf '#\n'
    printf '# To start or stop the server WITHOUT changing this file, run inside the box:\n'
    printf '#   server_start · server_stop · server_restart · server_status\n'
    printf '# A stop that way lasts until the box restarts. THIS file is the permanent\n'
    printf '# setting, and it survives recreating the box.\n'
    printf '# Take a change here live with:  %s restart %s\n' \
      "${RUNTIME:-podman}" "$(box_ctr "$box")"
    printf 'STARTUP_ENABLED=%s\n' "$([[ -n ${CFG_BOXSV[$box]:-} ]] && printf 1 || printf 0)"
    printf 'PORT=%s\n' "${CFG_PORT[$box]}"
  } > "$f" 2>/dev/null || warn "could not write $f $EMD the box will not know its serve setting"
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
    printf 'Documentation=file://%s/NOTES.md\n' "$(fs_path "$EMIT_DIR")"
    printf '\n[Service]\n'
    printf 'Type=oneshot\n'
    printf 'RemainAfterExit=yes\n'
    printf 'ExecStart=%s start %s\n' "$bin" "$(box_ctr "$box")"
    # ⭐ GRACEFUL STOP (s45). Ask the SERVER to exit before stopping the CONTAINER.
    # Why this is the fix and not a nicety: the container's pid 1 is distrobox-init,
    # which does NOT forward SIGTERM to the service we backgrounded — so `podman stop`
    # never reaches the server, and it dies at the `--stop-timeout` ceiling every time.
    # server_stop runs INSIDE the box, owns the process by launch record, sends TERM and
    # waits. That verb is what made this fixable; before it there was nothing to call.
    # `-` prefix = failure is not fatal: a box that is already down, has no server, or
    # predates the verbs must never block its own shutdown. `podman stop` still follows
    # and still has its timeout, so this can only ever make the stop cleaner.
    printf 'ExecStop=-%s exec %s server_stop\n' "$bin" "$(box_ctr "$box")"
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
# In --ascii there is no repaint plumbing (CR/EL are empty), so the line is
# closed at each transition instead: one line per phase as it begins, then the
# completion line. Never a per-second frame there — that would spam a log.
STATUS_OPEN=0     # 1 = a partial (unterminated) status line is on screen
STATUS_NAME=""    # what that line names, for the repaints
STATUS_COL=0      # how far that partial line was padded (the ticker column)

# The open line stops at the TICKER column, not the tag column: in --ascii
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
  printf '  %sfull log: %s%s\n' "$C_FILE" "$(emit_spelled "$log")" "$RESET"
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
    # --ascii: announce the phase on its own line, no ticker. Same column as
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
# The log is the installer's OWN artifact and is opened by a dozen writers, so
# this hands back a RESOLVED path — the one place a stored spelling is
# deliberately left behind. emit_spelled puts the user's spelling of the
# resource path back on the front for the one line that shows one.
step_log() {   # step name → path
  local d
  d=$(fs_path "$EMIT_DIR")/logs
  mkdir -p "$d" 2>/dev/null || d=${TMPDIR:-/tmp}
  printf '%s/%s-%s.log' "$d" "$1" "$2"
}

emit_spelled() {   # resolved path under the resource dir → the user's spelling
  local p=$1 real
  real=$(fs_path "$EMIT_DIR")
  if [[ $p == "$real"/* ]]; then printf '%s/%s' "$EMIT_DIR" "${p#"$real"/}"
  else printf '%s' "$p"; fi
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

# Where the denominator comes from. A layer exists to the aggregator only once
# its first "Downloading" event arrives, and podman pulls about six of them at a
# time, so a total summed from what has been announced so far climbs every time
# another layer starts — the percentage sags backwards while the bytes go
# forwards. The stream never says how big the image is; the registry does. Ask
# it first and the total is known before the first byte lands.
#
# This runs on stdlib urllib alone: preflight promises bash, curl and python3
# and nothing else, so no skopeo, no jq, no second HTTP client. Every failure is
# deliberately silent — empty output means "no manifest", which the aggregator
# reads as "keep estimating" rather than as a reason to fail a pull that would
# otherwise have worked. The whole errand is on an 8s budget for the same
# reason: a registry that is slow to answer must not delay the download.
_pull_manifest_py() {
  cat <<'PY'
import json, platform, re, sys, time
import urllib.error, urllib.parse, urllib.request

# Both index kinds first, so a multi-arch repo hands back the list rather than
# whichever image the registry guesses we want, then both single-manifest kinds.
ACCEPT = ", ".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))
# uname's spelling of a machine is not the registry's spelling of a platform.
ARCH = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64",
        "arm64": "arm64", "armv7l": "arm", "ppc64le": "ppc64le",
        "s390x": "s390x", "riscv64": "riscv64"}

deadline = time.time() + 8.0


def budget():
    """Seconds left of the errand, or an exception once there are none."""
    left = deadline - time.time()
    if left <= 0.0:
        raise RuntimeError("timed out")
    return left


def split(repo):
    """registry host + repository name, by the same rule the runtimes use: a
    first component with a dot, a port or the name localhost is a host, and
    anything else is a Docker Hub shorthand. Ours is always ghcr.io; the Hub
    cases are here only so this cannot mislead someone who repoints it."""
    head, _, rest = repo.partition("/")
    if rest and ("." in head or ":" in head or head == "localhost"):
        # docker.io is the name of the Hub, not of the registry that serves it.
        return ("registry-1.docker.io" if head == "docker.io" else head), rest
    return "registry-1.docker.io", repo if "/" in repo else "library/" + repo


def fetch(url, token):
    req = urllib.request.Request(url, headers={
        "Accept": ACCEPT, "User-Agent": "droste-setup"})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    return urllib.request.urlopen(req, timeout=budget())


def bearer(host, name, challenge):
    """Anonymous pull token, from the realm the 401 itself named. Public repos
    (ours included) still require this handshake — the answer is just always
    yes — so an unauthenticated GET is expected to be refused exactly once."""
    parts = dict(re.findall(r'([A-Za-z_]+)="([^"]*)"', challenge))
    realm = parts.get("realm") or "https://%s/token" % host
    query = {"scope": parts.get("scope") or "repository:%s:pull" % name}
    if parts.get("service"):
        query["service"] = parts["service"]
    url = realm + "?" + urllib.parse.urlencode(query)
    with urllib.request.urlopen(url, timeout=budget()) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    return body.get("token") or body.get("access_token") or ""


def manifest(host, name, ref, token):
    """One manifest by tag or by digest, acquiring a token if asked to."""
    url = "https://%s/v2/%s/manifests/%s" % (
        host, name, urllib.parse.quote(ref, safe=":@"))
    try:
        with fetch(url, token) as resp:
            return json.loads(resp.read().decode("utf-8")), token
    except urllib.error.HTTPError as exc:
        if exc.code != 401 or token:
            raise
        token = bearer(host, name, exc.headers.get("WWW-Authenticate") or "")
    with fetch(url, token) as resp:
        return json.loads(resp.read().decode("utf-8")), token


try:
    host, name = split(sys.argv[1])
    doc, token = manifest(host, name, sys.argv[2], "")
    if doc.get("manifests"):
        # An index: pick the entry for the machine doing the pulling. Signature
        # and attestation entries live here too, and are filtered out by the
        # same os/architecture test that finds the image.
        want = ARCH.get(platform.machine().lower(), platform.machine().lower())
        pick = ""
        for child in doc["manifests"]:
            plat = child.get("platform") or {}
            if plat.get("os") == "linux" and plat.get("architecture") == want:
                pick = child.get("digest") or ""
                break
        if not pick:
            raise RuntimeError("no linux/%s entry in the index" % want)
        doc, token = manifest(host, name, pick, token)
    blobs = {}
    for blob in (doc.get("layers") or []) + [doc.get("config") or {}]:
        # The config blob is in here on purpose: it is a blob like any other and
        # podman may well report progress for it, and an id the aggregator
        # cannot match is what sends the whole pull back to estimating.
        if blob.get("digest") and isinstance(blob.get("size"), int):
            blobs[blob["digest"]] = blob["size"]
    if not blobs:
        raise RuntimeError("manifest carries no blob sizes")
    sys.stdout.write(json.dumps(blobs))
except Exception as exc:                       # never the reason a pull fails
    sys.stderr.write("pull manifest: %s\n" % exc)
sys.exit(0)
PY
}

# The aggregator. Reads the /images/create JSON stream on stdin, sums every
# layer's progressDetail, and repaints ONE line; cached ("Already exists")
# layers count as complete and print nothing of their own. It leaves the cursor
# on that line WITHOUT a newline — the caller's status line overwrites it.
#
# The blob map from _pull_manifest_py arrives as a seventh argument and decides
# which of two modes it runs in: with one, the total is fixed for the life of
# the pull and the percentage only ever climbs; without one (or after the map
# turns out not to describe this stream), it falls back to the running sum and
# says so by printing the total with a "~".
#
# In --ascii there is no cursor to move, so the same two modes are drawn
# APPEND-ONLY instead (Jei's s39 spec): a header line, then either one "#" per
# percent across two 50-mark rows, or — when the manifest came back empty — one
# dot per elapsed minute, each row closing with its own (elapsed, bytes). That
# block stands in for the caller's status line, so it reports back the column it
# stopped on and the caller pads from there to the [OK] tag.
_pull_progress_py() {
  cat <<'PY'
import json, sys, threading, time

label, width, fill, empty, plain = sys.argv[1:6]
width = int(width)
ascii_mode = plain == "1"
out = sys.stdout

raw = sys.argv[6] if len(sys.argv) > 6 else ""
# The --ascii block is a drawing of its own (Jei's s39 spec) and REPLACES the
# status line the caller would otherwise have opened, so it needs three things
# the repainting bar does not: the image ref in FULL (it gets a line to itself,
# so there is no reason to shorten it), the name-column width that fixes where
# the [OK] tag ends, and a file to report the column it stopped on — which is
# what lets status_ok/status_err pad from there to the tag.
alabel = sys.argv[7] if len(sys.argv) > 7 else label
statw = int(sys.argv[8]) if len(sys.argv) > 8 else 53
colfile = sys.argv[9] if len(sys.argv) > 9 else ""
known = {}                                     # blob digest (bare hex) -> size
try:
    for digest, size in (json.loads(raw) if raw.strip() else {}).items():
        known[digest.split(":")[-1].lower()] = int(size)
except (AttributeError, TypeError, ValueError):
    known = {}                                 # unreadable map is simply no map
fixed_total = sum(known.values())

layers = {}                                    # id -> [current, total]
state = {"seen": False, "last": 0.0, "extract": set(),
         "fixed": bool(known), "map": {}}
dec = json.JSONDecoder()


def degrade():
    """Stop trusting the manifest, for the rest of this pull.

    A single id the map cannot account for means the map does not describe this
    stream, and half-mapped arithmetic is worse than none. Every layer already
    carries its own current/total, so the running sum simply resumes from what
    has been collected — nothing is lost and nothing is counted twice."""
    state["fixed"] = False


def mapped(lid):
    """The size of the blob a stream id names, or None if that is not certain.

    The stream shortens digests to a prefix, so the match is by prefix; a
    prefix that hits two blobs, or none, counts as no match rather than as
    licence to charge bytes to the wrong layer."""
    if lid not in state["map"]:
        key = lid.lower().split(":")[-1]
        hit = [h for h in known if h.startswith(key)]
        state["map"][lid] = known[hit[0]] if len(hit) == 1 else None
    return state["map"][lid]


def sizes(cur, tot, guess):
    mark = "~" if guess else ""
    for unit, div in (("GB", 1 << 30), ("MB", 1 << 20)):
        if tot >= div:
            return "%.1f/%s%.1f %s" % (
                cur / float(div), mark, tot / float(div), unit)
    return "%.0f/%s%.0f KB" % (cur / 1024.0, mark, tot / 1024.0)


# ── The --ascii drawing: APPEND-ONLY ────────────────────────────────────────
# No CR, no erase-line, nothing outside {0x20-7E, LF}: this is the form that
# survives a pipe, a log file and a dumb terminal, which is why it exists at
# all (the repainting bar below simply had nothing to repaint with there, and
# was switched off). Terminal mode is untouched.
#
# CAP is the right edge of the [OK] tag — the same column every other status
# line in this section ends on (2 indent + name column + 4), which is 59 for a
# full run. A bar row's own content stops five short of that, leaving " [OK]"
# for the caller to print. The block itself is drawn flush left: it is a
# full-width drawing, like a rule, whose closing tag lands in the tag column.
CAP = 2 + statw + 4
ANN = CAP - 5                                  # right edge of a row's content
ROW_MARKS = 50                                 # 100 marks (one per percent), 2 rows

# col = the column the open line has reached; row = marks/dots on it.
A = {"col": 0, "row": 0, "marks": 0, "dots": 0, "closed": False,
     "t0": time.time(), "done": False}
lock = threading.Lock()                        # the minute clock writes too


def fmt_size(n):
    """3 significant characters, then the unit: "6.6 GiB" / " 66 MiB" / "999 B"."""
    for unit, div in (("TiB", 1 << 40), ("GiB", 1 << 30),
                      ("MiB", 1 << 20), ("KiB", 1 << 10)):
        if n >= div:
            v = n / float(div)
            return "%s %s" % ("%.1f" % v if v < 10 else "%3d" % int(v), unit)
    return "%3d B" % int(n)


def fmt_time(m, level=0):
    """Elapsed minutes. level is the compression rung: the full form, the same
    thing without a day field (36h 07m), then bare minutes (2167m)."""
    if level >= 2:
        return "%dm" % m
    day, rem = divmod(m, 1440)
    if level == 0 and day:
        return "%dd %dh %02dm" % (day, rem // 60, rem % 60)
    if m >= 60:
        return "%dh %02dm" % (m // 60, m % 60)
    return "%dm" % m


def reserve_w(m):
    """Room to keep for the NEXT order of magnitude, so the annotation does not
    have to move once it grows: 36m -> 1h 11m -> 10h 46m -> 1d 12h 07m."""
    w = len(fmt_time(m))
    return {2: 3, 3: 6, 6: 7, 7: 10}.get(w, w + 1)


def dot_cap(m):
    """Dots a row may hold: its one-character prefix, then whatever is left
    before the widest annotation this row could still have to print."""
    return ANN - 1 - (4 + reserve_w(m) + 7)


def cur_bytes():
    return sum(v[0] for v in layers.values())


def write(s):
    out.write(s)
    A["col"] += len(s)


def newrow():
    out.write("\n ")                           # every row after the first
    A["col"] = 1
    A["row"] = 0


def annot(final):
    """(elapsed, bytes) while running; SQUARE brackets on the final row. It is
    right-aligned to ANN, and degrades in Jei's order when it will not fit:
    first the gap before it is eaten, then the time field is compressed. If
    even that is too wide it prints anyway and wraps — we got super unlucky."""
    room = ANN - A["col"]
    lb, rb = ("[", "]") if final else ("(", ")")
    for level in (0, 1, 2):
        text = "%s%s, %s%s" % (lb, fmt_time(A["dots"], level),
                               fmt_size(cur_bytes()), rb)
        if len(text) <= room:
            break
    pad = room - len(text)
    write(" " * (pad if pad > 0 else 0) + text)


def ascii_open():
    """The header, printed before the first byte: the ref, then the size the
    manifest prefetch found — or the fact that it did not — right-aligned to
    CAP. Then the bar opens, so a registry that never answers still shows that
    something was asked."""
    tag = "(%s)" % fmt_size(fixed_total) if fixed_total else "(Size: ???)"
    # The cap governs, so the gap is what gives: the longest ref this installer
    # pulls (finetuning) leaves exactly none of it, and "latest...(4.6 GiB)" at
    # 59 is the same trade the annotation rows make one rung down the ladder.
    pad = CAP - len(alabel) - len(tag)
    out.write("%s%s%s\n[" % (alabel, " " * (pad if pad > 0 else 0), tag))
    A["col"] = 1
    out.flush()


def ascii_marks(pct):
    """Size known: one mark per percent, 50 to a row. The manifest's total is
    the denominator for the whole pull — a mid-flight degrade() cannot be
    honoured by ink already on the page, and the prefetched size is the true
    one anyway; only the mapping of stream ids to blobs was ever in doubt."""
    while A["marks"] < pct:
        if A["row"] >= ROW_MARKS:
            newrow()
        write(fill)
        A["marks"] += 1
        A["row"] += 1
    if A["marks"] >= 100 and not A["closed"]:
        write("]")
        A["closed"] = True


def ascii_dots(upto):
    """Size unknown: one dot per elapsed minute. A row closes with its own
    cumulative annotation the moment another dot would not leave room for it."""
    while A["dots"] < upto:
        if A["row"] >= dot_cap(A["dots"]):
            annot(False)
            newrow()
        write(".")
        A["dots"] += 1
        A["row"] += 1


def paint_ascii(final=False):
    with lock:
        if A["done"]:
            return
        if fixed_total:
            ascii_marks(100 if final
                        else min(100, int(cur_bytes() * 100 // fixed_total)))
        else:
            ascii_dots(int((time.time() - A["t0"]) // 60))
            if final:
                annot(True)
        A["done"] = final
        out.flush()


def ascii_clock():
    """Estimating mode polls on its own: a pull that has gone quiet is exactly
    the moment the reader most needs to see the minutes still ticking."""
    while True:
        time.sleep(2)
        with lock:
            if A["done"]:
                return
            ascii_dots(int((time.time() - A["t0"]) // 60))
            out.flush()


def ascii_report():
    """Where the block stopped, for the caller's [OK]/[ERROR] tag."""
    with lock:
        A["done"] = True
        out.flush()
        if colfile:
            try:
                with open(colfile, "w") as fh:
                    fh.write("%d\n" % A["col"])
            except OSError:                     # never the reason a pull fails
                pass


def paint(final=False):
    if ascii_mode:
        paint_ascii(final)
        return
    now = time.time()
    if not final and now - state["last"] < 0.1:
        return
    state["last"] = now
    cur = sum(v[0] for v in layers.values())
    # Fixed: the whole image, known before the first byte. Otherwise: only the
    # layers that have announced themselves, which is why that total climbs.
    tot = fixed_total if state["fixed"] else sum(v[1] for v in layers.values())
    if final:
        pct = 100
    elif tot:
        pct = min(100, int(cur * 100 // tot))
    else:
        pct = 0
    if state["extract"] and (not tot or cur >= tot):
        tail = "  %3d%%  extracting" % pct
    elif tot:
        tail = "  %3d%%  %s" % (pct, sizes(cur, tot, not state["fixed"]))
    else:
        tail = "  %3d%%" % pct           # every layer cached: no bytes to count
    # The tail is padded to a fixed width so the bar cannot change length
    # mid-download (the size text grows by a digit as it climbs). The pad is
    # the widest either mode can print — "  100%  1234.5/~1234.5 GB" — and it
    # is deliberately ONE number for both, because a pull that falls back to
    # estimating mid-flight must not resize the bar as it does so.
    tail = tail.ljust(25)
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
        # A cached layer is finished, not absent. With a manifest we know how
        # many bytes it stands for, so the bar jumps FORWARD over it instead of
        # the total quietly shrinking around a layer worth nothing.
        size = mapped(lid) if state["fixed"] else None
        if state["fixed"] and size is None:
            degrade()
        if size is None:
            layers.setdefault(lid, [0, 0])
        else:
            layers[lid] = [size, size]
    elif st.startswith("Downloading"):
        got, size = int(pd.get("current") or 0), int(pd.get("total") or 0)
        if state["fixed"]:
            mapped_size = mapped(lid)
            if mapped_size is None:
                degrade()
            else:
                size = mapped_size
        layers[lid] = [got, size]
    elif st.startswith("Download complete") or st.startswith("Pull complete"):
        if lid in layers:
            layers[lid][0] = layers[lid][1]
        state["extract"].discard(lid)
    elif st.startswith("Extracting"):
        state["extract"].add(lid)
    paint()


if ascii_mode:
    ascii_open()
    if not fixed_total:
        threading.Thread(target=ascii_clock, daemon=True).start()

try:
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
finally:
    # Reached on the error paths too: a half-drawn row still has to tell the
    # caller which column its [ERROR] tag pads from.
    if ascii_mode:
        ascii_report()
PY
}

pull_image() {   # box → 0 on success (draws the bar; caller draws the status)
  local box=$1 img repo tag short log manifest colf col rc=0
  img="${IMAGE_PREFIX}${box}${IMAGE_SUFFIX}"
  repo=${img%:*} tag=${img##*:}
  # The bar is labelled with the image, not with the registry and owner that
  # every one of these images shares: the tail reserves 25 columns now that it
  # has to fit both a fixed total and an estimated one, and on an 80-column
  # terminal the difference between the full ref and this is the difference
  # between a bar and no bar. Stripping through the last slash keeps that true
  # for any prefix. The ref in full is in the step log, which is where anyone
  # asking WHICH registry is already looking.
  short=${repo##*/}
  log=$(step_log pull "$box")
  : > "$log"
  # Ask the registry how big this image is before asking podman to fetch it, so
  # the bar has a denominator that does not move. It is allowed to come back
  # empty (offline, private repo, a registry in a mood) — that is the estimating
  # mode, not an error — so its complaint goes to the log and its exit status is
  # ignored here as it is there.
  manifest=$(python3 -c "$(_pull_manifest_py)" "$repo" "$tag" 2>>"$log") \
    || manifest=""
  # Where the --ascii block reports the column it stopped on. Beside the step
  # log because that path is already per-box and already disposable.
  colf="$log.col"
  rm -f "$colf"
  # -N (--no-buffer): without it curl hands the JSON stream over in ~16 KB
  # blocks, so the aggregator below repaints in lurches no matter how often the
  # API reports. It is the whole "the bar only moves every few seconds" fix.
  curl -fsS -N --unix-socket "$PULL_SOCK" -X POST \
       "http://d/v1.40/images/create?fromImage=$repo&tag=$tag" 2>>"$log" \
    | python3 -c "$(_pull_progress_py)" \
        "$short..." "$(disp_width)" "$BAR_F" "$BAR_E" "$ASCII" "$manifest" \
        "${img%:*}..." "$STATUS_W" "$colf" \
        2>>"$log" \
    || rc=$?
  # --ascii drew its own block in place of the status line the caller would have
  # opened, and left the cursor mid-row: hand the tag the column it stopped on
  # (as a name-column offset, which is what status_head pads from) so [OK] still
  # lands in the tag column. No file means nothing was drawn — leave the line
  # closed and let status_head draw the head itself.
  if [[ $ASCII -eq 1 && -s $colf ]] && read -r col < "$colf"; then
    STATUS_COL=$(( col - 2 )); [[ $STATUS_COL -lt 0 ]] && STATUS_COL=0
    STATUS_NAME="$img..."
    STATUS_OPEN=1
  fi
  rm -f "$colf"
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
    distrobox assemble create --file "$(fs_path "$(ini_file "$box")")" || rc=$?
  if [[ $rc -eq 0 ]]; then
    SESSION_STATE[$box]=STOPPED
    # The [A] rung starts only the boxes whose server is meant to come up with
    # the box (Jei's rev-2 semantics): starting a STARTUP_ENABLED=0 box would be an
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
    printf '  %ssystemctl not found %s cannot manage boot auto-start.%s\n' \
      "$C_TEXT" "$EMD" "$RESET"
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
      [[ $RUNG != w ]] && all_names+=("$(img_disp "$box")...")
      [[ $RUNG == c || $RUNG == a ]] && all_names+=("$(box_ctr "$box")...")
    done
    for box in ${units[@]+"${units[@]}"}; do
      all_names+=("$(unit_name "$box")...")
    done
    [[ ${#units[@]} -gt 0 ]] && all_names+=("loginctl enable-linger...")
    [[ ${#all_names[@]} -gt 0 ]] && status_width "${all_names[@]}"
    # FLOOR for a section that will draw a pull bar. The bar is a fixed 100
    # marks in two 50-mark rows, so its closing "]" always lands in column 52
    # and the tag needs the room after it. Dropping ":latest" from the display
    # took 7 columns off every name here, which would otherwise have pulled the
    # tag column in on top of the bar; 53 puts it back at the 59 the drawings
    # are built around. Never past what the terminal can show — a narrow
    # terminal keeps the clamp status_width already applied.
    if [[ $RUNG != w ]] && [[ $STATUS_W -lt 53 ]] \
       && [[ $(( $(disp_width) - 2 - 7 )) -ge 53 ]]; then
      STATUS_W=53
    fi
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
        # answer, and until it does the aggregator has nothing to paint. In
        # --ascii the aggregator opens its OWN header line (the s39 block stands
        # in for this status line), so opening one here would print the ref
        # twice; pull_image reports back where that block stopped instead.
        [[ $ASCII -eq 1 ]] \
          || status_start "$(img_disp "$box")..."
        pull_image "$box" || rc=$?
        if [[ $rc -eq 0 ]]; then
          status_ok "$(img_disp "$box")..."
        else
          status_err "$(img_disp "$box")..." "$(step_log pull "$box")"
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
  # $f is the spelling; only the redirect resolves it.
  local f=$EMIT_DIR/NOTES.md box port bs hs data pcache note
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
    printf '\nEntering a stopped box therefore starts it — and, if `STARTUP_ENABLED=1`, its\n'
    printf 'service with it. Both doors are the SAME environment: a `pip install`\n'
    printf 'you do interactively is what the served process runs.\n'
    printf '\n## Your installation\n\n'
    printf '| Box | Start w Box | Start w Host | Port | Data dir | Cache dir |\n'
    printf '|---|---|---|---|---|---|\n'
    for box in "${SELECTED[@]}"; do
      port=$(box_port_disp "$box")
      bs=$(yn_word "$(box_boxsv "$box")")
      hs=$(yn_word "$(box_hstsv "$box")")
      data="${PATHS["$box:data"]:-${EXD_PATH["$box:data"]:-?}}"
      # A box carried over from an older layout has no cache dir of its own to
      # report (nothing bound one); it says so rather than naming a path the
      # ini does not carry.
      pcache="${PATHS["$box:pcache"]:-${EXD_PATH["$box:pcache"]:-?}}"
      printf '| %s | %s | %s | %s | %s | %s |\n' \
        "$box" "$bs" "$hs" "$port" "$data" "$pcache"
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
    # The Q4 write-up: three host roots, told as "what may be deleted", which
    # is the only distinction between them a user has to remember. The paths
    # themselves are in the table above (they are per box, and may have been
    # typed one by one), so this names the ROLES.
    printf '\n## Three places your files live\n\n'
    printf 'Every box reads three host directories, and what separates them is\n'
    printf 'what may be thrown away:\n\n'
    printf -- '- **Data dir** (`data/<box>` by default) — PERSISTENT. Your work and\n'
    printf '  everything you authored: the seeded config you edited, the model\n'
    printf '  tree, ComfyUI%s `user/` and custom nodes, ds4%s saved sessions, the\n' \
      "'s" "'s"
    printf '  finetuning workspace, `server.env`. droste-setup.sh deletes\n'
    printf '  nothing here unasked: the one way it ever does is the "remove data\n'
    printf '  at new path" answer, when a move you accepted lands on a directory\n'
    printf '  that already has something in it — and that question names the\n'
    printf '  directory first.\n'
    printf -- '- **Cache dir** (`caches/<box>` by default) — PROGRAM CACHES, and\n'
    printf '  nothing else: the Python environment overlay and its work dir,\n'
    printf '  scratch temp, llama%s saved-prompt slots, ds4%s KV disk, the seeded\n' \
      "'s" "'s"
    printf '  `extra_model_paths.yaml`, the server state dir. Nothing in here is\n'
    printf '  authored and nothing is irreplaceable — droste-setup.sh offers to\n'
    printf '  EMPTY it when it finds leftovers from an older generation, and the\n'
    printf '  box rebuilds what it needs at the next start.\n'
    printf -- '- **Compute caches** (`%s`) — the compiled GPU\n' "$COMPUTE_CACHE"
    printf '  kernels, SHARED by every box because their content is keyed by\n'
    printf '  version and architecture. compute-caches is safe to delete anytime;\n'
    printf '  kernels rebuild on next start. The installer never touches it.\n'
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
    printf '\n## Starting and stopping the server\n\n'
    printf 'There are TWO settings, and the difference is how long they last.\n\n'
    printf '**Right now** — run these INSIDE the box (`distrobox enter <name>`):\n\n'
    printf '    server_status     # what the box wants, and what is really true\n'
    printf '    server_start      # start this box%s server now\n' "'s"
    printf '    server_stop       # stop it — until the box next starts\n'
    printf '    server_restart    # stop, then start\n\n'
    printf 'A `server_stop` is deliberately TEMPORARY: the server comes back the\n'
    printf 'next time the box starts, so you can never leave a box quietly dead\n'
    printf 'and forget why. These verbs act on the SERVER; to restart the whole\n'
    printf 'container use `podman restart <name>`.\n\n'
    printf '**Permanently** — `<data dir>/server.env`, read at EVERY box start:\n\n'
    printf '    STARTUP_ENABLED=1   # 0 = interactive only, nothing is launched\n'
    printf '    PORT=8188           # the port the server binds (host networking)\n\n'
    printf 'Edit it and `podman restart <name>` — no recreate needed, and the\n'
    printf 'file survives image updates and box recreation. droste-setup.sh writes\n'
    printf 'it from your answers for every box it (re)configures, and leaves it\n'
    printf 'alone for boxes you asked to KEEP.\n\n'
    printf 'If you have used droste before, this key used to be called `SERVE`.\n'
    printf 'Old files still work — `SERVE` is still read — and the next time\n'
    printf 'droste-setup.sh reconfigures a box it rewrites the file with the new\n'
    printf 'name.\n'
    printf '\n## Supervision (podman healthcheck)\n\n'
    printf 'Each box is created with a healthcheck that probes its service from\n'
    printf 'inside (`--health-on-failure=restart`), so a wedged or crashed server\n'
    printf 'is brought back. A box that is not meant to be serving right now\n'
    printf 'always reports healthy — the probe knows the difference.\n\n'
    printf 'The server is relaunched ON ITS OWN first: only if that fails does\n'
    printf 'the whole container restart, so a crashed server no longer closes\n'
    printf 'the shells of anyone working in the box. If you stopped the server\n'
    printf 'yourself with `server_stop`, nothing restarts anything — the box\n'
    printf 'knows you meant it.\n\n'
    printf 'The probe checks TWO things: that the service THIS box started is\n'
    printf 'still running, and that it answers. Both are needed because the boxes\n'
    printf 'share the host network: if the port in `server.env` is already taken\n'
    printf 'when the box starts, the box does NOT start a second listener (it\n'
    printf 'says so in `<data dir>/.droste-serve.log`) and reports UNHEALTHY —\n'
    printf 'the stranger on that port is not your server. Give the box its own\n'
    printf 'port or free that one; each restart retries.\n\n'
    printf 'The START PERIOD is generous on purpose (these services answer\n'
    printf 'nothing while they load multi-GB weights; llama even answers 503):\n\n'
    for box in "${SELECTED[@]}"; do
      printf '    %-12s %s\n' "$box" "${BOX_HEALTH_START[$box]}"
    done
    printf '\nInspect it with `podman inspect --format "{{json .State.Health}}"`.\n'
    printf '\n## Stopping: what actually happens\n\n'
    printf 'The box%s pid 1 is distrobox-init, which does NOT forward SIGTERM to\n' "'s"
    printf 'the served process, so `podman stop` on its own cannot ask the server\n'
    printf 'to exit — it kills it at the `--stop-timeout %s` ceiling.\n' \
      "$STOP_TIMEOUT"
    printf 'The systemd unit above therefore runs `server_stop` INSIDE the box\n'
    printf 'first, which does ask it, and only then stops the container. If you\n'
    printf 'stop a box by hand and want the same courtesy, run `server_stop` in\n'
    printf 'the box before `podman stop`. Nothing in these images buffers state\n'
    printf 'that a clean shutdown would flush, so this is politeness rather than\n'
    printf 'protection.\n'
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
      # The test resolves; the line printed does NOT — it is a command the
      # reader pastes into a shell, which expands a ~ itself.
      if [[ -f $(fs_path "$(ini_file "$box")") ]]; then
        printf '    distrobox assemble create --file %s\n' "$(ini_file "$box")"
      fi
    done
    printf '\nRecreating replaces the container; your data dir, your cache dir,\n'
    printf 'server.env and the in-box overlays under them are untouched — that\n'
    printf 'is what makes in-box installs survive a recreate (pip packages ride\n'
    printf 'the environment overlay in the cache dir, custom nodes their own\n'
    printf 'overlay in the data dir).\n'
    # The ini is the one generated file a user is invited to edit, and the
    # spelling record is the one line in it that looks like machinery. Explain
    # both here rather than leaving the reader to guess what may be touched.
    printf '\n## Editing a box%s ini by hand\n\n' "'s"
    printf 'Every bind a box has lives in the ONE `volume=` value of its ini:\n'
    printf '`distrobox assemble` reads only the LAST `volume=` key, so a second\n'
    printf 'line would silently drop the first. Its sources are written out in\n'
    printf 'full because that is what podman binds — a source that does not begin\n'
    printf 'with `/` or `./` is read as the NAME of a named volume, so a `~`\n'
    printf 'there would quietly stop being a bind at all.\n\n'
    printf 'Underneath it sits a record line, shaped like this:\n\n'
    printf '    # droste-setup: spelled="~/droste/data/<box>:/opt/data ..."\n\n'
    printf 'That is the same list of binds in the spelling you typed. It is what\n'
    printf 'lets droste-setup.sh show you your own paths on the next run rather\n'
    printf 'than a reconstruction of them, and it is rewritten from your answers\n'
    printf 'every time, so there is nothing to maintain there by hand. Change a\n'
    printf 'bind in `volume=` and it takes effect: `volume=` WINS when the two\n'
    printf 'disagree, and the record simply stops naming that directory.\n'
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
      printf -- '- %s: port=%s, box-start=%s, host-boot=%s, data=`%s`, cache=`%s`, %s.%s\n' \
        "$box" "${CFG_PORT[$box]}" "$(yn_word "${CFG_BOXSV[$box]:-}")" \
        "$(yn_word "${CFG_HSTSV[$box]:-}")" "${PATHS["$box:data"]}" \
        "${PATHS["$box:pcache"]}" "$note" \
        "$([[ -n ${BOX_CONFIG[$box]} ]] \
           && printf ' Seeded config: %s.' "${BOX_CONFIG[$box]}")"
    done
    printf '\nEscape hatch: `-e ALLOW_EPHEMERAL=1` downgrades missing-critical-\n'
    printf 'bind errors to warnings (NOT recommended — data will not persist).\n'
    printf '\n## Health check\n\n'
    printf 'On the GPU host, the repo'\''s `scaffolding/check-rocm.sh` validates\n'
    printf 'GPU access + per-box smoke across all images (see its --help).\n'
  } > "$(fs_path "$f")"
  # Jei's "---" is deliberate: a plain rule that says "that part is done",
  # closing the run's chattiest phase before the final report opens below.
  printf '\n%s---%s\n%sWrote %s.%s\n' \
    "$C_TEXT" "$RESET" "$C_FILE" "$f" "$RESET"
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
# table serve both cell widths: the 3-column [Y] of --ascii eats one column of
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
    if [[ $ASCII -eq 1 ]]; then gcol=(12 17 24); else gcol=(12 18 24); fi
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
    note=${BOX_NOTE[$box]//@DATA@/${data:-~/droste/$box/data}}
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
  printf '%s%s%s\n' "$C_SUB" "$1 (files in $EMIT_DIR)" "$RESET"
  printf '%s%s%-12s%s%s%s%s%s%s%s%s%s%s%s\n' "$C_TEXT" "$BULLET" "distrobox:" \
    "$C_EXE" "distrobox " "$C_CMD" "assemble create " \
    "$C_TGT" "--file " "$C_PH" "<box>" "$C_TGT" "-halo.ini" "$RESET"
  return 0
}

# The final pointer, the one line every run ends on.
dash_pointer() {
  printf '%s%s%s%s%s\n' "$C_ARROW" "$ARROW_G" "$C_TEXT" \
    "Definitions + full guide: $EMIT_DIR (ini, NOTES.md)" \
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
  # creating (and re-asks if the user declines or the create fails). The factory
  # spelling is a literal ~ (see seed_globals): every path derived from the
  # answer inherits whatever spelling the answer has.
  # shellcheck disable=SC2088  # a LITERAL ~, resolved by fs_path at use
  ask_path_as "Identify a path for droste resource storage" "~/droste"
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
      printf '%sAll selected boxes kept as-is %s definitions unchanged.%s\n' \
        "$C_TEXT" "$EMD" "$RESET"
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
