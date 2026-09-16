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
# `podman start` is the server door (the init hook reads the box's <box>.cfg
# from its data dir and launches the service on its configured port). There is
# no separate server container and no compose file any more.
#
# It guides every bind in the mount contract, host ports, whether each box
# serves at box start / at host boot, and overlay-hostile-filesystem
# mitigation; then it EMITS per-box recreation records into an emit dir
# ($DROSTE_CONFIG, else $XDG_CONFIG_HOME/droste, else ~/.config/droste):
#   <box>-halo.ini                   (distrobox assemble record — the ONE
#                                     container definition, healthcheck flags
#                                     and all)
#   NOTES.md                         (full guide with YOUR real paths baked in)
# and optionally pulls images / creates boxes / starts servers (build ladder).
# Boxes asked to start at HOST BOOT also get a systemd user unit
# (~/.config/systemd/user/droste-<box>.service) doing `podman start`.
#
# THE PORT AND BOX-START ANSWERS ARE NOT AN EMITTED FILE. They are two settings
# in the box's OWN config file, <data dir>/<box>.cfg, which the box seeds from
# its baked template at its FIRST CONTAINER START and which belongs to the user
# from then on. So the installer creates the box, STARTS it once (that start is
# what seeds the file), merges those two lines into it, and restarts it if
# anything changed — see write_box_cfg. It never creates that file itself: doing
# so would block the seed and cost the user every other setting in it.
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

# ── What the display/prompt layer is told about US ───────────────────────────
# The two values below are the ENTIRE input side of the layer described in the
# banner further down (display helpers → path fitting → prompt plumbing). That
# layer draws every screen and reads every answer, and it is meant to stay
# liftable into another program of Jei's; a hard-coded "droste-setup.sh" inside
# it is a small tie, but it is still a tie, and the point of the exercise is
# that there are none. So the layer says "$UI_PROG" and this line says what
# $UI_PROG is — once, here, where a reader looks for the program's identity.
#
# UI_INPUT_VAR holds a NAME, not a path, on purpose: the layer both READS the
# variable (indirectly) and NAMES it back in its error message, so a caller
# that renames the hook keeps a message that still tells the truth. Indirect
# expansion is safe here for one reason only — UI_INPUT_VAR is assigned right
# here, unconditionally. `${!NAME-}` aborts under `set -u` when NAME itself is
# unset (measured; the `-` fallback does NOT save it, because bash cannot even
# work out which variable it was asked about), and it is fine when it is set.
UI_PROG="droste-setup.sh"
UI_INPUT_VAR="DROSTE_SETUP_INPUT"
# ── UI_MKDIR — the layer's THIRD declared input (s80) ────────────────────────
# 🚨 THE LAYER CREATES A DIRECTORY, AND THAT IS THE ONE THING IT DOES THAT THE
# HOST MAY NEED TO OVERRIDE. `ensure_dir` asks "Create <path>?" and then makes
# it — and under `--dry-run` this program must not. Calling dry::fs from inside
# the layer was the obvious fix and is FORBIDDEN by the layer's own rule 2 ("the
# layer never calls back out"), which check-installer-layering.sh enforces.
# ⭐ SO IT GOES THROUGH THE SEAM THE LAYER ALREADY HAS, rather than through a
# hole cut in it: a NAME the host sets, called indirectly, exactly as
# UI_INPUT_VAR already is. A different host sets it to something that plainly
# runs `mkdir -p` and the layer lifts out unchanged — which is the whole promise
# these two lines exist to keep.
# ⚠️ ADDING A THIRD INPUT IS A REAL COST and is not to be done casually: every
# entry here is a promise the next host has to keep. It is also the only edit
# check-installer-layering.sh's own header says a maintainer should ever make to
# it (its UI_INPUTS list), so the two files move together — if you add a fourth,
# add it there in the same commit or the layer check goes red.
UI_MKDIR="ui_mkdir"
# ── UI_DIR_EXISTS — the layer's FOURTH declared input (s84) ──────────────────
# 🚨 THE LAYER ALSO ASKS WHETHER A DIRECTORY IS THERE, AND UNDER `--dry-run` THE
# FILESYSTEM IS THE WRONG PLACE TO ASK. `ensure_dir` opened with `[[ -d $real ]]`
# — true of a real run, wrong of a dry one, because the directory this program
# announced it would create was deliberately never made. The second question
# about one path then re-asks "Create X?" where a real run says nothing.
# ⭐ IT IS THE SAME SEAM AS UI_MKDIR AND THE SAME ARGUMENT, ONE STEP ON: a host
# that intercepts the CREATE has to be able to intercept the TEST, or its model
# of what it created is invisible to the only code that would consult it. Adding
# the test to the layer's declared inputs keeps rule 2 intact; calling droste's
# `dry::modelled` from inside `ensure_dir` would not.
# ⚠️ A HOST WITH NOTHING TO MODEL POINTS IT AT `[[ -d $2 ]]` and the layer lifts
# out unchanged. ⚠️ AND IT TAKES BOTH SPELLINGS, in UI_MKDIR's order and for
# UI_MKDIR's reason: the SPELLED path is what a model is keyed on (the path
# spelling contract forbids storing the resolved one), the RESOLVED path is what
# the kernel is asked about.
# ⚠️ A FOURTH INPUT IS A FOURTH PROMISE THE NEXT HOST HAS TO KEEP — and it must
# be added to check-installer-layering.sh's UI_INPUTS in the same commit, or the
# layer check goes red naming it.
UI_DIR_EXISTS="ui_dir_exists"

# ── The factory roots: XDG, and the one override ─────────────────────────────
# FOUR ROOTS, AND THEY ARE INDEPENDENT OF ONE ANOTHER (0.7.0, Jei). Until now
# there was ONE "droste resource storage" path and everything else hung off it,
# so moving it moved the data and the caches too. Now each family lives where
# its own kind of file belongs: the .ini files and NOTES.md under the CONFIG
# root, the per-box data under the DATA root, and the two cache families under
# the CACHE root. Answering one of the four questions no longer moves any of
# the other three.
#
#   config   $DROSTE_CONFIG | $XDG_CONFIG_HOME/droste | ~/.config/droste
#   data     $XDG_DATA_HOME/droste                    | ~/.local/share/droste
#   pcache   $XDG_CACHE_HOME/droste/program           | ~/.cache/droste/program
#   compute  $XDG_CACHE_HOME/droste/compute           | ~/.cache/droste/compute
#
# 🚨 THE ASYMMETRY IS THE WHOLE OF IT, AND READING IT BACKWARDS BREAKS THE
# OVERRIDE SILENTLY. DROSTE_CONFIG IS THE CONFIG ROOT ITSELF — DROSTE_CONFIG=/foo
# means /foo, NOT /foo/droste. The XDG variables are PARENTS (that is what the
# basedir spec says they are: the directory user-specific files are stored
# RELATIVE TO), so they get /droste appended. One says "here"; the others say
# "under here".
#
# ⚠️ `:-`, NOT `-`, ON EVERY NAME HERE, AND IT IS NOT A HOUSE-STYLE SLIP. The
# XDG basedir spec defines its fallback on "either not set or empty", so an
# exported-but-empty XDG_CONFIG_HOME MUST read as absent — and DROSTE_CONFIG
# follows this project's own rule, which says the same thing in its own words: a
# blank must behave exactly as if the setting were absent. Do not "correct"
# these to the plain `-` form; that would make `DROSTE_CONFIG=` mean "the root
# is the empty string".
#
# ⚠️ A FALLBACK IS A LITERAL ~, resolved by fs_path at use — the same spelling
# contract every other factory path keeps, so a default the user accepts is
# shown and stored the way the installer would have written it. A variable that
# IS set is taken exactly as it stands: XDG requires an absolute path, and
# abs_path absolutizes one that (against the spec) is not.
#
# ⭐ ONE READER, so no call site has to remember any of the above. The seeds in
# seed_globals, the config-path prompt in main, and the data_root/pcache_root
# fallbacks all ask this function.

# The XDG CONFIG PARENT on its own, spec default and all. Two callers need it and
# they need it for different things — factory_root builds the config root UNDER
# it, step_log_root asks whether the config root lies WITHIN it — so it is
# spelled ONCE, here, and neither of them carries a second copy of `~/.config`
# that could rot out of step with this one.
# ⚠️ `:-`, for the reason given above: the basedir spec's fallback is "either not
# set or empty", so an exported-but-empty variable reads as absent.
xdg_config_home() {  # → $XDG_CONFIG_HOME, or the basedir spec's default for it
  # shellcheck disable=SC2088  # LITERAL ~, resolved by fs_path at use (see above)
  if [[ -n ${XDG_CONFIG_HOME:-} ]]; then printf '%s' "$XDG_CONFIG_HOME"
  else printf '%s' '~/.config'; fi
}

factory_root() {  # config|data|pcache|compute → the root droste offers by default
  # shellcheck disable=SC2088  # LITERAL ~, resolved by fs_path at use (see above)
  case "$1" in
    config)
      if [[ -n ${DROSTE_CONFIG:-} ]]; then printf '%s' "$DROSTE_CONFIG"
      else printf '%s/droste' "$(xdg_config_home)"; fi ;;
    data)
      if [[ -n ${XDG_DATA_HOME:-} ]]; then printf '%s/droste' "$XDG_DATA_HOME"
      else printf '%s' '~/.local/share/droste'; fi ;;
    pcache)
      if [[ -n ${XDG_CACHE_HOME:-} ]]; then printf '%s/droste/program' "$XDG_CACHE_HOME"
      else printf '%s' '~/.cache/droste/program'; fi ;;
    compute)
      if [[ -n ${XDG_CACHE_HOME:-} ]]; then printf '%s/droste/compute' "$XDG_CACHE_HOME"
      else printf '%s' '~/.cache/droste/compute'; fi ;;
    *) return 1 ;;
  esac
  return 0
}

# ── Where the installer's OWN logs go ────────────────────────────────────────
# 🚨 LOGS ARE NOT CONFIG, AND THE XDG DEFAULT IS WHAT MADE THAT VISIBLE. The step
# logs sat at "$EMIT_DIR/logs" back when the config root was a single "droste
# resource storage" path whose stated purpose was "(re)creation records, logs, &
# data". With the four roots split apart, that same expression spells
# ~/.config/droste/logs — and a rotating capture of podman's chatter is not
# configuration under any reading.
#
# 🏁 THE RULE (Jei's final spec) — THREE BRANCHES, FIRST MATCH WINS:
#
#   1. the user ELECTED a common persistent data path → <elected base>/sys_logs
#   2. else $DROSTE_CONFIG is WITHIN $XDG_CONFIG_HOME → <data root>/sys_logs
#   3. else                                           → $DROSTE_CONFIG/sys_logs
#
# where $DROSTE_CONFIG is the variable itself when it has a value and
# $XDG_CONFIG_HOME/droste when it does not — i.e. exactly `factory_root config`.
#
# ⭐ THE LEAF IS `sys_logs`, NOT `logs`, AND THE NAME IS DOING WORK. A box's own
# serve log is `<program>/logs/<box>-serve.log`; these are the INSTALLER'S logs,
# written on the host by a different writer at a different time. Two directories
# both called `logs` under two droste-owned roots is a question every reader has
# to re-answer, and `sys_logs` answers it once, in the path itself.
#
# 🗄️ BRANCH 1 REPLACES AN EARLIER READING, AND THE REVERSAL IS THE POINT (Jei).
# This function used to reach for `factory_root data` — the FACTORY data root —
# and argue that the installer's own logs are not box data, so the user's answer
# to "Persistent data base path" should not move them. Jei OVERRULED that: an
# elected common base is the user saying where droste's bulk lives on this
# machine, and the logs go with it. Do not re-derive the old argument; it was
# heard and decided.
#
# ⭐ AND BRANCH 2 IS "WITHIN", NOT "EQUALS". DROSTE_CONFIG=~/.config/mydroste is a
# config root the user moved WITHIN the XDG config tree — still config, still no
# place for a rotating capture of podman's chatter — so it takes the data root
# exactly as the default ~/.config/droste does. An equality test would have sent that one case
# to branch 3 and written logs under $XDG_CONFIG_HOME after all, which is the one
# outcome this whole rule exists to prevent.
# 🚨 WITHIN INCLUDES THE DEFAULT, WHICH IS THE COMMON CASE: $XDG_CONFIG_HOME/droste
# IS a child of $XDG_CONFIG_HOME, so branch 2 is what an untouched machine gets.
# 🚨 AND IT IS A COMPONENT-WISE TEST, NEVER A STRING PREFIX — /tmp/cfgx/droste is
# NOT within /tmp/cfg and must fall to branch 3. path_within owns that trap.
#
# 🚨 THE CONFIG ROOT HERE IS $DROSTE_CONFIG — THE ENVIRONMENT VARIABLE, LITERALLY,
# NOT $EMIT_DIR. That is what the spec says and it is what Jei ruled when it was
# put to him: `factory_root config` is the whole of it, so an exported root is
# read and an unset one falls to $XDG_CONFIG_HOME/droste.
# 🗄️ IT READ $EMIT_DIR FIRST, AND THE ARGUMENT FOR THAT WAS OVERRULED. It said a
# path TYPED at the prompt counts as much as an exported one, since naming a root
# is naming a root. Do not re-derive it.
# ⭐ WHAT MAKES THE LITERAL READING COHERENT IS THAT THE PROMPT DOES NOT FIRE WHEN
# THE VARIABLE IS SET (main, `ask_config_root`). The environment pins the config
# root outright, so in every run where DROSTE_CONFIG has a value, $EMIT_DIR IS
# that value and the two readings cannot disagree. They part company only in the
# other direction — variable unset, root TYPED — and there branch 2 sends the logs
# to the data root, which is where an untouched machine puts them anyway.
#
# ⭐ AND NO DEFAULT IS SPELLED OUT TWICE: factory_root and xdg_config_home own
# those strings, so there is no second copy here to rot — and no copy of the blank
# rule either, since `factory_root config` already reads DROSTE_CONFIG= as unset.
#
# ⚠️ NOT THE BOX'S SERVE LOGS. Those are <program>/logs/<box>-serve.log, written
# inside the container by droste-serve.sh from the box's own config. Different
# writer, different file, and nothing here touches them.
step_log_root() {   # → the root the installer's own step logs live under
  local cfg
  # BRANCH 1. DATA_AUTO is the election itself — it is set nowhere but the yes
  # arm of "Store persistent data at common base path" — and the `-n` beside it
  # is not belt-and-braces: "" is not a place, and a root of "" would compose a
  # log path rooted at /.
  if [[ ${DATA_AUTO:-0} -eq 1 && -n ${DATA_ROOT:-} ]]; then
    printf '%s' "$DATA_ROOT"
    return 0
  fi
  # The ENVIRONMENT's config root, never the answered one — see above. It is also
  # why this function is safe to call at any point in the run: it depends on
  # nothing the interview has or has not asked yet.
  cfg=$(factory_root config)
  if path_within "$cfg" "$(xdg_config_home)"; then
    factory_root data          # BRANCH 2
  else
    printf '%s' "$cfg"         # BRANCH 3
  fi
}

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

# 🚨 THE ONE PLACE A BIND LEAF IS NAMED. Every user-facing form of a leaf's name
# derives from this table: the path prompt lowercases it mid-sentence, bind_row
# below hands it to the summary box, and leaf_word lowercases it for the move
# sentences. The two shorter forms are EXCEPTION LISTS over this one, not copies
# of it — a leaf spelled out in three tables is a leaf whose three spellings
# drift, and nothing was keeping these in step until s81.
# ⚠️ `program` WAS SPELLED `data` UNTIL s79, while both of its user-facing strings
# already said "Program Data" — the internal/external divergence Jei's own rule
# forbids, and the reason the rename cost nothing on screen.
declare -A BIND_TITLE=(
  [program]="Program Data" [config]="Configuration" [user]="Saved Workflows"
  [input]="Input Files" [output]="Output Files" [workspace]="Workspace"
)

# Summary-box row headers, and ONLY for the families whose title does not fit
# there — the box is narrow. Everything else falls back to BIND_TITLE through
# bind_row(), so `program` and `workspace` (which said their titles verbatim)
# are gone from here: an entry that repeats its title is a copy waiting to
# disagree, and a new leaf gets a row header by existing.
# ⚠️ `Config`, NOT `Configuration`: SUM_HDR_W is 14 columns and "Configuration:"
# fills it exactly, so the value would sit flush against the colon with no space
# between them. That is what this table is FOR — every entry here earns its line
# by being shorter than the title, and none of them may merely restate it.
declare -A BIND_ROW=(
  [config]="Config" [user]="Workflows"
  [input]="Input" [output]="Output"
)

# The row header for a leaf: its short form when it needs one, its title when it
# does not. One reader for the fallback, so no call site has to remember it.
# ⚠️ A leaf with NO title is a bug, and it stays loud: `set -u` aborts on the
# inner expansion rather than inventing a name from the label.
bind_row() {   # label → summary-box row header
  printf '%s' "${BIND_ROW[$1]:-${BIND_TITLE[$1]}}"
}

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
# the port the service BINDS: droste-setup.sh records it as DROSTE_<APP>_PORT in
# the box's <box>.cfg and the init hook passes it to the service on the command
# line. ds4's upstream default is 8000, same as
# vllm, so its default is nudged to 8001 to keep both runnable side by side.
declare -A BOX_HOST_PORT=(
  [comfyui]=8188 [llama]=9931 [vllm]=8000 [ds4]=8001 [finetuning]=8888
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

# Extra CRITICAL binds beyond /opt/program + the shared HF cache (CRITICAL rows):
# space-separated "label:container-dest". These hold irreplaceable user work.
# ORDER IS DISPLAY ORDER: it drives both the path prompts and the summary box
# rows, so comfyui lists output before input (Jei's mockup, both places).
#
# 🚨 `config` IS ON EVERY BOX (s79) AND IS FIRST. It is the one thing here that
# nothing gets back — the box's hand-edited settings — and it was a directory
# INSIDE the program bind until s79, where the user could not be offered a path
# for it. ⚠️ Its label is also what dest_to_label hands cfg_write_seeds, so this
# row is what makes the config files land anywhere at all.
# 🚨 comfyui's `user` JOINED THEM in the same change, for the same reason: it was
# a SURFACE out of the program bind, and a surface is a directory the installer
# cannot place. It holds the user's saved workflows.
#
# ⚠️ NEITHER IS EVER ASKED WHEN THE DATA ELECTION WAS ACCEPTED — auto_label puts
# every data-family bind under <base>/<box>/<label> without a prompt, so the
# ordinary run gains no questions from either.
declare -A BOX_EXTRA_BINDS=(
  [comfyui]="config:/opt/config user:/opt/ComfyUI/user output:/opt/ComfyUI/output input:/opt/ComfyUI/input"
  [llama]="config:/opt/config"
  [vllm]="config:/opt/config"
  [ds4]="config:/opt/config"
  [finetuning]="config:/opt/config workspace:/opt/workspace"
)

# Where each box's OVERLAY UPPERS land on the HOST, said as a BIND LABEL plus a
# path relative to that bind — never as a host path. Each target's baked
# build-spec declares its overlays as <upper>:<lower> with the upper on the
# CONTAINER side ("/opt/program/venv:/opt/venv", and comfyui's
# "/opt/program/custom_nodes:/opt/ComfyUI/custom_nodes"); this table is the
# host-side mirror of that declaration, the same relationship BOX_CFG has with
# each build-spec's CFG_FILE, and it has to keep mirroring it.
#
# ⭐ A LABEL, NOT A PATH, IS THE WHOLE POINT: the host root is whatever
# PATHS[<box>:<label>] settled on THIS RUN, so everything derived from this
# table follows the answer the user gave rather than restating a layout. Move
# the root and nothing here changes.
#
# THE RELATIVE PART NAMES THE LEVEL WHOSE TOP-LEVEL ENTRIES ARE THE UNIT OF
# INSTALLATION, which is not the upper's own root: inside a venv that is
# site-packages (one directory per installed distribution), while comfyui's
# custom_nodes upper IS that level already (one directory per node). Anything
# deeper belongs to a package or a node and is its own business.
# The interpreter version is a GLOB on purpose — the image picks it, and a
# pinned python3.NN would silently stop matching the first time the base moves.
declare -A BOX_OVERLAY_UPPERS=(
  [comfyui]="program:venv/lib/python*/site-packages program:custom_nodes"
  [llama]="program:venv/lib/python*/site-packages"
  [vllm]="program:venv/lib/python*/site-packages"
  [ds4]="program:venv/lib/python*/site-packages"
  [finetuning]="program:venv/lib/python*/site-packages"
)

# WHERE AN UPPER USED TO LIVE, label to label — one row per LABEL in the table
# above whose ROOT has moved. The venv upper sat on the program-cache root until
# s79, which is the root the installer offers to empty: a box set up before the
# move has its owner's `pip install`s under a path the box no longer reads, and
# the two things owed to that owner are that the wipe LEAVES THEM ALONE and that
# the run SAYS WHERE THEY ARE.
#
# ⭐ A MAP, NOT A SECOND PATH TABLE: everything derived from it still comes out of
# PATHS/EXD_PATH, so the report and the wipe exclusion follow whatever the roots
# settled on rather than restating a layout. A row retires the day no box in the
# field can still be in the old shape.
# ⚠️ NO MIGRATION (s41's precedent, "I can manually fix my boxes"): nothing here
# moves a byte, and nothing offers to delete one.
# ⚠️ ONE ROW PER LABEL, NOT PER UPPER. comfyui has two uppers under `program` and
# only the venv arrived from `pcache`; retired_upper_entry intersects this map
# with what is ACTUALLY on the old root, so a custom_nodes dir that was never
# there matches nothing and the row costs nothing.
declare -A OVERLAY_UPPER_WAS=(
  [program]="pcache"
)

# OPTIONAL /opt/models bind point (OPTIONAL row; finetuning has none).
declare -A BOX_HAS_MODELS=(
  [comfyui]=1 [llama]=1 [vllm]=1 [ds4]=1 [finetuning]=0
)

# The box's SETTINGS FILE, written onto /opt/config by THIS INSTALLER when it is
# absent — before the box has ever started (s77) — and owned by the user from the
# moment it exists. This is the file the five serve settings live in, so this map
# is what the installer writes through — it MIRRORS `CFG_FILE` in each target's
# baked build-spec (/opt/config/<box>.cfg) and has to keep mirroring it.
# 🚨 THE NAME FOLLOWS THE BOX; THE SETTINGS INSIDE IT FOLLOW THE APPLICATION (see
# BOX_APP) — and that is not merely a convention any more: droste::box_name
# derives the box's own name from CFG_FILE's basename, so a box whose file were
# named for its application would silently rename its two log files.
declare -A BOX_CFG=(
  [comfyui]="comfyui.cfg"
  [llama]="llama.cfg"
  [vllm]="vllm.cfg"
  [ds4]="ds4.cfg"
  [finetuning]="finetuning.cfg"
)

# A SECOND seeded file, where the box has one. vllm's model/engine configuration
# is its own YAML rather than a setting in vllm.cfg, and the user is told about
# it by name; nothing else here has one. NOT a settings file — never written by
# this installer, only named in NOTES.md so the user can find it.
declare -A BOX_CFG_EXTRA=(
  [comfyui]="" [llama]="" [vllm]="vllm_config.yaml" [ds4]="" [finetuning]=""
)

# 📐 THE DROSTE-OWNED PREFIX IS `DROSTE_<APP>_*` — THE APPLICATION, NOT THE BOX.
# It looks like the box name on four of five because the names COINCIDE;
# finetuning is the box where the distinction is observable and it settles it —
# every droste-owned setting there is DROSTE_JUPYTER_*, and there is no such
# thing as a DROSTE_FINETUNING_* (targets/finetuning/build-spec says so).
declare -A BOX_APP=(
  [comfyui]="COMFYUI"
  [llama]="LLAMA"
  [vllm]="VLLM"
  [ds4]="DS4"
  [finetuning]="JUPYTER"
)

# One-line explanations for the prompted bind families (what lives there).
# Reference only since the per-bind headers were dropped — kept as the record of
# what each prompted bind actually holds.
# shellcheck disable=SC2034
declare -A BIND_DESC=(
  [config]="the settings files you edit - nothing gets these back"
  [program]="the venv + custom-node overlay uppers, model tree, logs"
  [pcache]="scratch, slots, kv-disk, the per-box compute-cache fallback"
  [user]="your saved ComfyUI workflows + its own UI settings"
  [input]="source files you feed ComfyUI"
  [output]="generated images/videos"
  [workspace]="notebooks + trained adapters - your work"
)

# The ONE pre-first-use action (dashboard Notes column). TWO placeholders since
# s79, because the two roots they name are two different questions: @CONFIG@ is
# where the user goes to TYPE something, @PROGRAM@ where the box WROTE something.
declare -A BOX_NOTE=(
  [comfyui]=""
  [llama]="Model: @CONFIG@/llama.cfg"
  [vllm]="Model: @CONFIG@/vllm_config.yaml"
  [ds4]="Model: @CONFIG@/ds4.cfg"
  [finetuning]="Token: @PROGRAM@/logs/finetuning-serve.log (grep token=)"
)

IMAGE_PREFIX="ghcr.io/doctorjei/droste-"   # + <box> + "-halo:" + tag

# ── THE IMAGE LINE THIS INSTALLER PINS (s77) ─────────────────────────────────
# 🚨 THE PIN IS A PROPERTY OF THE INSTALLER, FIXED AT PUBLISH — never derived at
# runtime, and NEVER from a config file. A v0.6.x installer pins the `0.6` image
# line, and that is what guarantees the installer and the image agree, and
# therefore that the config files it writes match the image it installs.
# 📐 `X.Y`, ruled by Jei (s73): "technically there should be no interface changes
# from X.Y.z for any 'z', so the config should be compatible."
# ⇒ 🚨 **A PATCH RELEASE MUST NOT CHANGE THE CONFIG SURFACE.** No renamed
# settings, no retired names, no default that changes behavior. Ordinary semver,
# but here it is load-bearing because the pin enforces it.
#
# ⚠️ `latest` IS THE HONEST ANSWER FOR AN UNRELEASED ASSEMBLY, and it is what
# keeps working from a checkout unchanged. A release substitutes the real line.
# ⚠️ A NAMED CONSTANT, not an expression over DROSTE_VERSION. They move together
# today and a pre-release deliberately breaks that (see the assembler): a tagged
# rc pins its EXACT tag, because `release.yml` leaves the moving `X.Y` alias on
# the last stable, so an rc pinning `0.7` would install a DIFFERENT build than
# the one it was published beside — or nothing at all.
DROSTE_IMAGE_TAG="latest"
IMAGE_SUFFIX="-halo:$DROSTE_IMAGE_TAG"

# ── THE VERSION THIS INSTALLER IS (s77) ──────────────────────────────────────
# Stamped as a comment on the first line of every config file and ini the
# installer writes (`# droste-version: X.Y.Z`), so a file can say which release
# authored it. NOTHING CONSUMES IT YET — it reserves the option to migrate a
# config later without taking it (Jei, s73: "we can READ compatible config files
# and reserve the OPTION to rewrite them"), and ABSENT IS NOT WRONG, because
# every box in the field predates stamping.
#
# 🚨 `dev` IS THE HONEST ANSWER OUTSIDE A RELEASE, AND THE DEFAULT MUST STAY ONE.
# Never stamp a version we do not have. `release.yml` hands the real one to
# scripts/assemble-droste-setup.sh, which substitutes this line; a plain assembly
# leaves it alone. ⚠️ That is also what keeps `lint-shell.yml`'s "two assemblies
# are byte-identical" gate green — the version may not come from the clock, the
# environment or a git describe, because all three would break it, and breaking
# it would be the gate working.
DROSTE_VERSION="dev"
# The image ref AS SHOWN to the reader: the image STEM alone — no registry, no
# owner, no tag. Every part dropped here is shared by every image this
# installer pulls, so on screen it is 25 columns that distinguish nothing:
# seven for the tag (hardcoded :latest above) and eighteen for the registry and
# owner. Those columns are the difference between the pull bar's header fitting
# its line and not, on an 80-column terminal.
# ⭐ Stripping through the LAST SLASH keeps that true for any prefix, rather
# than assuming this one.
# ⚠️ The full ref is not lost — it is in the step log, which is where anyone
# asking WHICH registry is already looking, and a failing row names that log.
# The PULL and the ini keep the whole ref: one has to name a tag, the other is
# the reference distrobox resolves.
# 🔗 pull_image() labels its bar the same way and for the same reason; these
# two must agree, or one pull prints two different names for one image.
img_disp() {   # box → droste-<box>-halo
  local ref
  ref="${IMAGE_PREFIX}${1}${IMAGE_SUFFIX%:*}"
  printf '%s' "${ref##*/}"
}
# ONE container per box, named exactly like the image stem: droste-<box>-halo.
# (The old -server / -box lane suffixes are gone with the lanes; see box_ctr().)
INIT_HOOK="/opt/resources/resolve/droste-init-hook.sh"

# Where the BAKED templates live INSIDE the image: every config file a box seeds,
# plus the `templates.yaml` manifest that says where each one goes.
# 🚨 SINCE s77 THE INSTALLER IS THE ONE THAT COPIES THEM OUT AND WRITES THEM —
# this is no longer just the reference copy it diffs a user's file against, it is
# the source of the files themselves (box_templates → cfg_write_seeds).
# 🚨 IT MIRRORS TWO THINGS AND HAS TO KEEP MIRRORING BOTH — the default of
# RESOLVE_TEMPLATES_DIR in base/resolve/droste-resolve.sh, and the COPY that
# puts templates/ there in every targets/Container.<box>.
# ⚠️ THE FILE LIST IS NOT WRITTEN DOWN HERE, ON PURPOSE. `templates.yaml` travels
# with the templates, so cfg_write_seeds reads the manifest rather than restating
# it; a list here would be a second copy that rots the day a target gains a ninth
# seeded file. BOX_CFG still names the one file the installer MERGES answers into.
# ⚠️ It is read with `podman cp`, NOT `podman exec` — `cp` works on a container
# that has never been started, which is what lets the config exist before the
# first start. (`exec` also inherits nothing from the init hook, so the in-box
# value of RESOLVE_TEMPLATES_DIR was never available to us either way; the path is
# written out rather than expanded from the box's environment.)
CFG_TEMPLATE_DIR="/opt/resources/templates"

# ── Healthcheck contract (P1's droste-healthcheck.sh, baked in every image) ───
# droste-setup.sh wires podman's healthcheck at CREATE time (the images carry no
# HEALTHCHECK of their own): the probe reads the box's <box>.cfg for the port
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
# 🚨 TIMEOUT IS NOT THE SAME KNOB AS START PERIOD, AND LEAVING IT UNSET WAS A BUG.
# podman defaults --health-timeout to 30s (verified against podman 5.4.2's own
# --help) and kills a probe that overruns it, which on-failure=restart then counts
# as a failure and bounces the container.
# ⭐ WHAT IT ACTUALLY BOUNDS IS PRE_LAUNCH, NOT MODEL LOADING. The service is
# launched in the BACKGROUND (droste-serve.sh's serve::launch ends in `&`), so a probe never
# waits for weights; the start period below is what covers those. But when the
# healthcheck finds the service down it calls serve::relaunch, which runs the
# box's PRE_LAUNCH synchronously inside the probe — and comfyui's rescans the
# whole model tree. On a large tree that alone exceeds 30s, so the box that most
# needs a relaunch is the one whose relaunch gets killed and restart-looped.
# ⚠️ GENEROUS EVERYWHERE, deliberately (Jei): the boxes that load models can have
# slow pre-launch paths we have not found, and the only cost of erring long is a
# later detection of a genuinely wedged probe — the same trade the start periods
# already make. A value above the interval is safe here because the `starting`
# state record makes a second concurrent relaunch a no-op.
declare -A BOX_HEALTH_TIMEOUT=(
  [comfyui]=10m [llama]=5m [vllm]=5m [ds4]=5m [finetuning]=2m
)
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
# 🚨 EVERY VALUE HERE HAS A TWIN IN THE BOX: each targets/<box>/build-spec carries the
# same duration as its HEALTH_START row. The probe needs the number (it bounds the
# `server_restart` grace window — serve::restart_window_bound, B17) and cannot read this
# file, which is the host's. ⚠️ CHANGE BOTH, and change them together: the build-spec row
# is what the box acts on, and g1lab/probebudget.sh reddens per box when they disagree.
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
# Rough size of the baked content copy-mode would duplicate onto /opt/program-cache
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

