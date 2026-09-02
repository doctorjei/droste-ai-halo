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
# (default ~/droste/):
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
# the port the service BINDS: droste-setup.sh records it as DROSTE_<APP>_PORT in
# the box's <box>.cfg and the init hook passes it to the service on the command
# line. ds4's upstream default is 8000, same as
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

# The box's SETTINGS FILE, seeded (if missing) onto /opt/data at the box's FIRST
# CONTAINER START and owned by the user from then on. This is the file the five
# serve settings live in, so this map is what the installer writes through — it
# MIRRORS `CFG_FILE` in each target's baked build-spec (/opt/data/<box>.cfg) and
# has to keep mirroring it. The name follows the BOX; the settings inside it
# follow the APPLICATION (see BOX_APP).
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
  [data]="venv overlay upper, caches, seeded config"
  [input]="source files you feed ComfyUI"
  [output]="generated images/videos"
  [workspace]="notebooks + trained adapters - your work"
)

# The ONE pre-first-use action (dashboard Notes column; @DATA@ substituted).
declare -A BOX_NOTE=(
  [comfyui]=""
  [llama]="Model: @DATA@/llama.cfg"
  [vllm]="Model: @DATA@/vllm_config.yaml"
  [ds4]="Model: @DATA@/ds4.cfg"
  [finetuning]="Token: @DATA@/.droste-serve.log (grep token=)"
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
# launched in the BACKGROUND (droste-serve.sh:856 ends in `&`), so a probe never
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

