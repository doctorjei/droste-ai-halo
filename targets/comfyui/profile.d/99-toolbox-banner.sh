#!/usr/bin/env bash
# Lightweight banner with machine/GPU and ROCm nightly version

# Load ROCm env quietly if present
[[ -f /etc/profile.d/01-rocm-envs.sh ]] && . /etc/profile.d/01-rocm-envs.sh

oem_info() {
  local v="" m="" d lv lm
  for d in /sys/class/dmi/id /sys/devices/virtual/dmi/id; do
    [[ -r "$d/sys_vendor" ]] && v=$(<"$d/sys_vendor")
    [[ -r "$d/product_name" ]] && m=$(<"$d/product_name")
    [[ -n "$v" || -n "$m" ]] && break
  done
  # ARM/SBC fallback
  if [[ -z "$v" && -z "$m" && -r /proc/device-tree/model ]]; then
    tr -d '\0' </proc/device-tree/model
    return
  fi
  lv=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  lm=$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')
  if [[ -n "$m" && "$lm" == "$lv "* ]]; then
    printf '%s\n' "$m"
  else
    printf '%s %s\n' "${v:-Unknown}" "${m:-Unknown}"
  fi
}

# Reject empty / placeholder GPU names so the ladder keeps falling through.
_gpu_ok() {
  local n
  n=$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -z "$n" ]] && return 1
  case "$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')" in
    n/a|na|none|null|unknown|"not supported"|"unknown amd gpu"|"amd gpu") return 1 ;;
  esac
  return 0
}

# Resolve a friendly GPU name. Runs at every login: every probe is guarded by
# command -v, silenced, and (where a probe could hang) bounded by `timeout`, so
# a missing/wedged tool can never error out or stall the login shell.
# ROCm CLI tools ship in /opt/venv/bin, which is NOT on PATH at profile.d time
# (zz-venv-last.sh only prepends it via PROMPT_COMMAND, after banners source).
# Resolve by PATH first, then that known location — like rocm_version()'s
# absolute python path — so rocminfo/rocm-smi are found at banner time.
_rocm_tool() { command -v "$1" 2>/dev/null || { [[ -x "/opt/venv/bin/$1" ]] && printf '/opt/venv/bin/%s\n' "$1"; }; }

gpu_name() {
  local name="" cand="" gfx="" rinfo="" TO="" rbin="" sbin=""
  # Bound probes that can hang (rocminfo/rocm-smi enumerate hardware). If the
  # `timeout` binary is absent we just run the command directly.
  command -v timeout >/dev/null 2>&1 && TO="timeout 3"

  # rocminfo: capture once, then parse for both a friendly name and the gfx
  # target. APUs like Strix Halo populate "Marketing Name" even when other
  # sources are blank, so it leads the ladder.
  if rbin=$(_rocm_tool rocminfo); then
    rinfo=$($TO "$rbin" 2>/dev/null)
    # (1) First GPU agent's Marketing Name. Device Type appears after the Name/
    # Marketing lines within an agent block, so buffer then emit at Device Type.
    cand=$(printf '%s\n' "$rinfo" | awk '
      /^[[:space:]]*Marketing Name:[[:space:]]/ { m=$0; sub(/^[[:space:]]*Marketing Name:[[:space:]]*/,"",m) }
      /^[[:space:]]*Device Type:[[:space:]]/ {
        d=$0; sub(/^[[:space:]]*Device Type:[[:space:]]*/,"",d)
        if (d ~ /GPU/) { print m; exit }
      }')
    _gpu_ok "$cand" && name="$cand"
    # gfx target (e.g. gfx1151) of the first GPU agent — kept for the fallback.
    gfx=$(printf '%s\n' "$rinfo" | awk '
      /^[[:space:]]*Name:[[:space:]]/ { n=$0; sub(/^[[:space:]]*Name:[[:space:]]*/,"",n) }
      /^[[:space:]]*Device Type:[[:space:]]/ {
        d=$0; sub(/^[[:space:]]*Device Type:[[:space:]]*/,"",d)
        if (d ~ /GPU/) { print n; exit }
      }' | grep -oiE 'gfx[0-9a-f]+' | head -n1)
  fi

  # (2) rocm-smi --showproductname. Column/CSV layout varies by ROCm version,
  # so scan several likely value fields and take the first non-placeholder.
  if [[ -z "$name" ]] && sbin=$(_rocm_tool rocm-smi); then
    cand=$($TO "$sbin" --showproductname 2>/dev/null \
      | grep -iE 'Card Series|Card Model|Product Name|Device Name|Market Name' \
      | sed -E 's/.*:[[:space:]]*//' | head -n1)
    _gpu_ok "$cand" && name="$cand"
    # CSV form: header row of column names, then per-GPU value rows.
    if [[ -z "$name" ]]; then
      cand=$($TO "$sbin" --showproductname --csv 2>/dev/null \
        | awk -F, 'NR>1 && NF>1 { for (i=2;i<=NF;i++) if ($i!="" && $i!="N/A") { print $i; exit } }')
      _gpu_ok "$cand" && name="$cand"
    fi
  fi

  # (3) amdgpu sysfs — product_name is populated on some boards/APUs.
  if [[ -z "$name" ]]; then
    local f
    for f in /sys/class/drm/card*/device/product_name; do
      [[ -r "$f" ]] || continue
      cand=$(<"$f")
      if _gpu_ok "$cand"; then name="$cand"; break; fi
    done
  fi

  # (4) lspci fallback for the display/VGA controller description.
  if [[ -z "$name" ]] && command -v lspci >/dev/null 2>&1; then
    cand=$(lspci 2>/dev/null | grep -iE 'vga|display|3d controller' \
      | grep -iE 'amd|ati|radeon' | head -n1 | sed -E 's/.*: //')
    _gpu_ok "$cand" && name="$cand"
  fi

  # (5) No friendly name, but ROCm clearly sees a GPU → show the gfx target;
  #     far more useful than a generic "Unknown".
  [[ -z "$name" && -n "$gfx" ]] && name="AMD GPU ($gfx)"

  # trim leading/trailing spaces and squeeze multiple spaces to one
  name=$(printf '%s' "$name" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//' -e 's/[[:space:]]\{2,\}/ /g')
  # (6) Absolute last resort.
  printf '%s\n' "${name:-AMD GPU (gfx target unknown)}"
}

rocm_version() {
  local PY="/opt/venv/bin/python"
  [[ -x "$PY" ]] || PY="python"
  "$PY" - <<'PY' 2>/dev/null || true
try:
    import importlib.metadata as im
    try:
        print(im.version('_rocm_sdk_core'))
    except Exception:
        print(im.version('rocm'))
except Exception:
    print("")
PY
}

# The port this box's service ACTUALLY listens on. In the merged (distrobox)
# lane the init hook launches ComfyUI with DROSTE_COMFYUI_PORT from
# /opt/data/comfyui.cfg, so a baked-in number in the text below (and in
# start_comfy_ui) would be wrong for every box that changed it.
# 🚨 PARSED, NEVER SOURCED (s60). The two serve keys used to live in a
# droste-owned server.env, which was safe to source; they now live in the USER's
# own comfyui.cfg, several hundred lines of their settings. So this asks
# droste::cfg_get — the scanning reader written for exactly this — and gets a
# VALUE back instead of executing the user's file at every login.
# The rest of the discipline is unchanged and deliberate: the read runs in a
# SUBSHELL with errexit/nounset off, its stdin closed and its stderr discarded
# (cfg_get warns about a mangled line, and a login banner is not where a user
# wants to meet that), then the answer is range-checked — so a missing,
# unreadable or hand-mangled file quietly falls back to the in-container default
# (8188: the SERVICE line's) instead of printing garbage or failing the login
# shell. The LAST assignment wins, which is cfg_get's rule as it was sourcing's.
# ⚠️ The path is a literal here rather than read from the baked build-spec's
# ENV_FILE, and that is the point: the file we tell the user to edit further down
# and the file we read here must be the same string, guaranteed by being one.
serve_port() {
  local def=8188 file="${DROSTE_SERVE_ENV:-/opt/data/comfyui.cfg}" pv=""
  if [[ -f "$file" && -r "$file" ]]; then
    pv=$(
      set +e +u +o pipefail
      # 🚨 THE STDERR REDIRECT BELONGS IN HERE, NOT ON THE CLOSING `)`. A trailing
      # `2>/dev/null` on an ASSIGNMENT is applied AFTER the command substitution has
      # already run — expansions precede redirections in a simple command — so it
      # silences nothing that happens inside it. Measured, not deduced: cfg_get's
      # "unterminated quote" warning printed into a login banner through exactly
      # that gap. `exec` covers the source, the parser and anything added later.
      exec 2>/dev/null
      [ -r /opt/resources/resolve/droste-cfg.sh ] || exit 1
      # shellcheck disable=SC1091
      . /opt/resources/resolve/droste-cfg.sh >/dev/null </dev/null || exit 1
      droste::cfg_get DROSTE_COMFYUI_PORT "$file"
    ) || pv=""
  fi
  if [[ "$pv" =~ ^[0-9]{1,5}$ ]] && [ "$pv" -ge 1 ] && [ "$pv" -le 65535 ]; then
    printf '%s\n' "$pv"
  else
    printf '%s\n' "$def"
  fi
}

# The address to REACH this box's service, for the URLs printed below.
# `localhost` was a safe constant only while every box bound the wildcard;
# DROSTE_COMFYUI_HOST is a user setting now, so a box bound to one interface
# would otherwise be handed a URL that answers nothing — the same silent-lie
# defect as a stale port, on the first thing a user reads.
# Asks droste-serve.sh's serve::probe_addr: THE single source every probe in this
# project uses, so the banner and the healthcheck cannot disagree about where the
# server is. Deriving it here instead would copy two rules (the wildcard test and
# the IPv4 validation, which rejects e.g. a leading-zero octet the server would
# never have bound) into a place nobody would think to update.
# Run in a SUBSHELL, like serve_running below: sourcing that library sets a dozen
# DROSTE_* defaults, turns errexit on and defines the serve:: namespace, none of
# which belongs in a user's interactive shell.
# ⚠️ THIS IS A DISPLAY ADDRESS, NOT A BIND ADDRESS. probe_addr answers "where do I
# reach it", so a wildcard bind comes back as loopback — right in a URL and
# catastrophic in a --listen flag, which would then bind loopback ONLY. Never
# feed this to a server.
# 127.0.0.1 is rendered `localhost`: the same endpoint, the friendlier spelling,
# and the text every box printed before HOST was a setting. Anything that is not
# a specific dotted quad lands there too — a validated shape check on our own
# library's answer, so a future change upstream of us cannot put a hostname, an
# empty string or a wildcard into a printed URL.
serve_addr() {
  local a
  a=$(
    set +e +u +o pipefail
    # Same reason as serve_port's: a trailing redirect cannot reach inside a
    # command substitution, and this library reports on stderr by design.
    exec 2>/dev/null
    [ -r /opt/resources/resolve/droste-serve.sh ] || exit 1
    # shellcheck disable=SC1091
    . /opt/resources/resolve/droste-serve.sh >/dev/null </dev/null || exit 1
    serve::read_config >/dev/null
    serve::probe_addr
  ) || a=""
  case "$a" in
    ''|0.0.0.0|127.0.0.1) a=localhost ;;
  esac
  [[ "$a" == localhost || "$a" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || a=localhost
  printf '%s\n' "$a"
}

# serve_running — is THIS box's service up right now? Prints "<pid> <port>" and
# returns 0, else returns 1 and prints nothing.
#
# Asks droste-serve.sh's own state record rather than probing the port, because a
# probe cannot tell OUR service from a squatter — that distinction is the whole
# point of serve::state_ok, and it is the same call the healthcheck makes. Run in
# a SUBSHELL, like serve_port above: sourcing droste-serve.sh sets a dozen
# DROSTE_* defaults and defines the serve:: namespace, none of which belongs in a
# user's interactive shell. errexit/nounset off and stdin closed so a hand-edited
# comfyui.cfg cannot take the login shell down with it — read_config PARSES that
# file (droste::cfg_get) rather than sourcing it, but this subshell is what makes
# a broken LIBRARY harmless too.
serve_running() {
  ( set +e +u +o pipefail
    [ -r /opt/resources/resolve/droste-serve.sh ] || exit 1
    # shellcheck disable=SC1091
    . /opt/resources/resolve/droste-serve.sh >/dev/null 2>&1 </dev/null || exit 1
    serve::read_config >/dev/null 2>&1
    # INTENT, not config (s45): ask whether a server is wanted right now, the same
    # question the healthcheck asks. Reading STARTUP_ENABLED here would call a
    # hand-stopped server "not serving because the box is interactive-only", which is
    # the wrong reason and the wrong advice.
    serve::is_active >/dev/null 2>&1 || exit 1
    serve::state_ok >/dev/null 2>&1 || exit 1
    printf '%s %s' "${SERVE_REC_PID:-?}" "${SERVE_PORT:-?}"
  ) 2>/dev/null
}

MACHINE="$(oem_info)"
GPU="$(gpu_name)"
ROCM_VER="$(rocm_version)"
SERVE_PORT="$(serve_port)"
SERVE_ADDR="$(serve_addr)"

echo
printf '%s\n' \
  $'             \033[1;97m ╔\033[1;96m═╤\033[1;94m═╤\033[0;34m════╗ \033[1;90m🭺🭺🭺🭺🭺\033[0;37m🭺🭺🭺🭺🭺🭺\033[1;97m🭺🭺🭺🭺🭺🭺🭺🭺\033[0;37m🭺🭺🭺🭺🭺🭺\033[1;90m' \
  $'             \033[1;96m ╟─┘\033[0;37m■\033[0;94m│\033[0;34m    ║ \033[1;90m █🮂🮂\033[0;37m🭕🭏    \033[1;97m        \033[0;37m🭋' \
  $'             \033[1;94m ╟───┘ \033[0;34m\033[1;97m██ \033[0;34m║ \033[1;90m █ \033[0;37m  █ 🭩🬂\033[1;97m🭗🭄🮂🭏 🭄🮀🭧\033[0;37m🭢🬨🬂🭗🭂🮀\033[1;90m🭍' \
  $'             \033[0;34m ║ \033[0;34m\033[0;34m\033[0;34m       ║ \033[1;90m █\033[0;37m  🭊🭠 🭞\033[1;97m  🭕▂🭠 ▄ \033[0;37m🭨🭬🭦🭩🭛🭓\033[1;90m🬭🬽' \
  $'             \033[0;34m\033[0;34m\033[0;34m\033[0;34m ╚════════╝ \033[1;90m`\033[0;37m🮃🮃🮃🭘🭷🭷\033[1;97m🭷🭷🭷🭷🭷🭷🭷🭣\033[0;37m🬂🭘🭷🭷🭷🭷\033[1;90m🭷🭷🭷🭷\033[0m'
cat <<'ASCII'
                    ComfyUI: Interactive Box

ASCII
echo
printf 'AMD Ryzen AI Max Strix Halo: Image & Video Toolbox (gfx1151, ROCm via TheRock)\n'
[[ -n "$ROCM_VER" ]] && printf 'ROCm nightly: %s\n' "$ROCM_VER"
echo
printf 'Machine: %s\n' "$MACHINE"
printf 'GPU    : %s\n\n' "$GPU"
printf 'Image : ghcr.io/doctorjei/droste-comfyui-halo\n'
printf 'Repo  : https://github.com/doctorjei/droste-ai-halo\n\n'
# Serving state, ASKED not assumed. The pre-s34 text here said "in a
# distrobox/toolbox shell nothing autostarts", which was true when the distrobox
# lane and the server lane were two separate containers. Since the merge it is
# ONE container with two doors, and the server door autostarts whenever
# DROSTE_COMFYUI_STARTUP_ENABLED says so — so the old line invited the user to
# start a second ComfyUI on a port the first one already holds.
printf 'ComfyUI server: http://%s:%s\n' "$SERVE_ADDR" "$SERVE_PORT"
if serve_running >/dev/null; then
  printf '  - ALREADY SERVING on port %s. Stop it with: server_stop\n' "$SERVE_PORT"
  printf '    Logs: tail -f /opt/data/.droste-serve.log\n'
else
  printf '  - Not serving right now → start it with: server_start\n'
fi
printf '  - server_start · server_stop · server_restart · server_status\n'
printf '    These act on the SERVER, not the box. A stop lasts until the box\n'
printf '    restarts; for a permanent change set DROSTE_COMFYUI_STARTUP_ENABLED\n'
printf '    in /opt/data/comfyui.cfg.\n'
echo
printf 'Model downloaders (shared HF cache; scanner links them in at start):\n'
printf '  get_wan22.sh · get_qwen_image.sh · get_hunyuan15.sh · get_ltx2.sh\n\n'
# The middle field is the address the FORWARD lands on at the far end, so it has
# to be the one the server actually bound: with host networking the listener is
# on the host itself, and `localhost` there answers nothing on a box whose
# DROSTE_COMFYUI_HOST names one interface.
printf 'SSH tip: ssh -L %s:%s:%s user@host\n\n' "$SERVE_PORT" "$SERVE_ADDR" "$SERVE_PORT"

# Launcher (flags match the container SERVICE line). A function, not an alias:
# the extra-model-paths config is only seeded where an init hook ran (distrobox);
# plain toolbox has no /opt/program-cache/extra_model_paths.yaml, and ComfyUI's
# unguarded open() would crash on the missing file — pass the flag only if the
# file exists.
# serve_port is re-read here rather than reusing $SERVE_PORT from banner time, so
# a comfyui.cfg edited during the session takes effect on the next launch.
# ⚠️ `--listen 0.0.0.0` stays a literal: this is a BIND address, and the banner's
# $SERVE_ADDR is a display one (0.0.0.0 shows as localhost). It also means this
# foreground lane does not follow DROSTE_COMFYUI_HOST — flagged, not fixed here.
# start_comfy_ui — KEPT AS AN ALIAS, because users may know this name (it predates the
# verbs). It names the new verb once and then does what it always did: run ComfyUI in
# the FOREGROUND of this shell, which is still the right tool for watching a run.
# ⚠️ s45 replaced its refusal text, not its refusal. The s44 version warned and pointed
# at `kill <pid>` + editing SERVE=0; Jei ruled against warning — "I don't think we should
# warn the user. I think we should change our box's behavior" — so it now points at the
# verb that does the thing properly.
start_comfy_ui() {
  # REFUSE if the server door already has one up. One container, two doors since
  # s34: launching here would race the running service for the port, and ComfyUI's
  # bind failure names neither the other instance nor the door that started it.
  local state pid port
  if state=$(serve_running); then
    read -r pid port <<<"$state"
    printf 'ComfyUI is ALREADY RUNNING (pid %s) on port %s → http://%s:%s\n' \
      "$pid" "$port" "$(serve_addr)" "$port"
    printf '  logs: tail -f /opt/data/.droste-serve.log\n\n'
    printf 'To run one here in the foreground instead, stop the server first:\n'
    printf '  server_stop\n'
    printf 'That lasts until the box restarts. For a permanent change, set\n'
    printf 'DROSTE_COMFYUI_STARTUP_ENABLED=no in /opt/data/comfyui.cfg.\n'
    return 1
  fi
  printf 'Tip: server_start runs ComfyUI in the background, supervised, and\n'
  printf 'survives you closing this shell. start_comfy_ui runs it here, in the\n'
  printf 'foreground, which is what you want when you are watching it.\n\n'
  local extra=()
  [[ -f /opt/program-cache/extra_model_paths.yaml ]] \
    && extra=( --extra-model-paths-config /opt/program-cache/extra_model_paths.yaml )
  cd /opt/ComfyUI && python main.py --listen 0.0.0.0 --port "$(serve_port)" \
    --disable-mmap --gpu-only --disable-smart-memory --cache-none --bf16-vae \
    "${extra[@]}"
}
