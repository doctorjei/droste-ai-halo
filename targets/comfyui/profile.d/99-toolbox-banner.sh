#!/usr/bin/env bash
# Lightweight banner with machine/GPU and ROCm nightly version

# Load ROCm env quietly if present
[[ -f /etc/profile.d/01-rocm-envs.sh ]] && . /etc/profile.d/01-rocm-envs.sh

# Only show for interactive shells. It sits AFTER the env load above, not before:
# the guard is about the BANNER, and a non-interactive login shell
# (`distrobox enter comfyui -- cmd`) must still get the ROCm environment.
case $- in *i*) ;; *) return 0 ;; esac

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
# /opt/config/comfyui.cfg, so a baked-in number in the text below (and in
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
# CFG_FILE, and that is the point: the file we tell the user to edit further down
# and the file we read here must be the same string, guaranteed by being one.
# 🚨 THE FALLBACK IS READ FROM THE BAKED BUILD-SPEC, NEVER TYPED HERE (s66). This used
# to be a literal, a fourth copy of the port that NOTHING cross-checked — the other three
# (build-spec, <box>.cfg, installer/contract.sh) are pinned against each other by
# g1lab/servewire.sh, so a port that moved left this one behind. ⚠️ IT HAD ALREADY GONE
# WRONG: ds4's copy read 8000, which is VLLM's port, while its spec said 8001 — so on a
# machine running both, an unreadable ds4.cfg printed a recipe aimed at the wrong server.
# Deriving it means the two cannot disagree. ⚠️ If the grep fails the value stays EMPTY
# and the range test below rejects it, so a missing spec prints nothing rather than a lie.
serve_port() {
  local def file="${DROSTE_SERVE_ENV:-/opt/config/comfyui.cfg}" pv=""
  def=$(sed -n 's/^SERVE_PORT_DEFAULT=\([0-9]\{1,5\}\).*/\1/p' \
        /opt/resources/build-spec 2>/dev/null | head -1)
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

# serve_host — the address to BIND, for the foreground launcher below. Prints a
# usable IPv4 literal and returns 0; prints NOTHING and returns 1 when the
# configured one cannot be honored.
#
# 🚨 THIS IS THE OTHER ADDRESS QUESTION AND serve_addr CANNOT ANSWER IT. probe_addr
# maps the wildcard to loopback because "where do I browse" and "what do I bind"
# have different right answers, so feeding it to --listen would bind loopback ONLY.
# This reads the SETTING instead: same file, same parser (droste::cfg_get), same
# IPv4 rule the server lane applies (serve::_is_ipv4). That rule is CALLED, never
# copied — a second dotted-quad test here is the duplicated-validation defect this
# project keeps paying for, and it would drift the first time a leading-zero octet
# is argued about again.
#
# 🚨 A FAILURE IS NEVER RESOLVED TOWARD A WIDER BIND (Jei, s60: "fail"). Until s60
# this lane hardcoded `--listen 0.0.0.0`, so a user who narrowed their box's bind
# got EVERY interface back the moment they ran it in the foreground — the same shape
# as a certificate with no key: they believe the port is protected and it is not.
# Absent or blank is our documented default and yields 0.0.0.0; anything we cannot
# honor returns 1, and the caller declines to launch rather than widening.
#
# The three arms, each chosen rather than fallen into:
#   no config file      → 0.0.0.0. Nothing to honor, and it is what the server
#                         lane reads from the same absence.
#   exists, unreadable  → REFUSE. The setting may narrow the bind and we cannot
#                         see it; the server lane refuses to serve on this file at
#                         all, so a foreground that guessed would be the one thing
#                         on the box ignoring the user's own file.
#   library unreachable → REFUSE, same reason. Unable to read is not permission to
#                         widen.
# Same subshell discipline as serve_port and serve_addr: errexit/nounset off, stdin
# closed, stderr discarded from the first line INSIDE (a trailing redirect on the
# assignment runs after the substitution and silences nothing), and the library's
# serve:: namespace left in there rather than in a user's interactive shell.
serve_host() {
  local h file="${DROSTE_SERVE_ENV:-/opt/config/comfyui.cfg}"
  [ -f "$file" ] || { printf '0.0.0.0\n'; return 0; }
  [ -r "$file" ] || return 1
  h=$(
    set +e +u +o pipefail
    exec 2>/dev/null
    [ -r /opt/resources/resolve/droste-serve.sh ] || exit 1
    # shellcheck disable=SC1091
    . /opt/resources/resolve/droste-serve.sh >/dev/null </dev/null || exit 1
    v=$(droste::cfg_get DROSTE_COMFYUI_HOST "$file")
    # A blank behaves exactly as absent (s57): our default, never the empty string
    # — which as a --listen argument is a bind failure, not a default.
    [ -n "$v" ] || { printf '0.0.0.0\n'; exit 0; }
    serve::_is_ipv4 "$v" || exit 1
    printf '%s\n' "$v"
  ) || return 1
  # Nothing is re-validated out here on purpose: the one rule already ran inside,
  # and a weaker copy of it in this shell is the second implementation the note
  # above refuses. The emptiness test is not that copy — it is the guard against
  # handing an empty argument to a flag.
  [ -n "$h" ] || return 1
  printf '%s\n' "$h"
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
  $'             \033[1;96m ╟─┘\033[1;93m★\033[0;94m│\033[0;34m    ║ \033[1;90m █🮂🮂\033[0;37m🭕🭏    \033[1;97m        \033[0;37m🭋' \
  $'             \033[1;94m ╟───┘ \033[0;34m\033[1;93m🟊  \033[0;34m║ \033[1;90m █ \033[0;37m  █ 🭩🬂\033[1;97m🭗🭄🮂🭏 🭄🮀🭧\033[0;37m🭢🬨🬂🭗🭂🮀\033[1;90m🭍' \
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
  printf '    Logs: tail -f /opt/program/logs/comfyui-serve.log\n'
else
  printf '  - Not serving right now → start it with: server_start\n'
fi
printf '  - server_start · server_stop · server_restart · server_status\n'
printf '    These act on the SERVER, not the box. A stop lasts until the box\n'
printf '    restarts; for a permanent change set DROSTE_COMFYUI_STARTUP_ENABLED\n'
printf '    in /opt/config/comfyui.cfg.\n'
echo
printf 'Model downloaders (shared HF cache; scanner links them in at start):\n'
printf '  get_wan22.sh · get_qwen_image.sh · get_hunyuan15.sh · get_ltx2.sh\n\n'
# The middle field is the address the FORWARD lands on at the far end, so it has
# to be the one the server actually bound: with host networking the listener is
# on the host itself, and `localhost` there answers nothing on a box whose
# DROSTE_COMFYUI_HOST names one interface.
printf 'SSH tip: ssh -L %s:%s:%s user@host\n\n' "$SERVE_PORT" "$SERVE_ADDR" "$SERVE_PORT"

# service_argv — the command line the SERVER would run, DERIVED rather than
# remembered. Prints it NUL-delimited and returns 0; prints NOTHING when this box's
# configuration cannot be turned into a command line.
#
# 🚨 IT REPLACED A HARDCODED SNAPSHOT, AND THE SNAPSHOT HAD ALREADY GONE WRONG (found
# s73). start_comfy_ui used to type out five flags — --disable-mmap --gpu-only
# --disable-smart-memory --cache-none --bf16-vae — while the service's line is built
# by comfyui_argv translating a FOURTEEN-row table plus DROSTE_COMFYUI_CACHE. Two of
# the five were false in shipped images: --disable-smart-memory has not been on the
# service line since `9f95652` (MODEL_RESIDENCY's default `cache` emits nothing), and
# --cache-none is the OPPOSITE of what CACHE's default `ram` emits (--cache-ram).
# ⭐ AND IT WAS NEVER DRIFT FROM A SHARED COPY — there was no copy. The other NINE
# settings were not represented here at all, so someone who set VRAM=lowvram and
# reached for the foreground launcher to find out why their box was slow got
# --gpu-only anyway. That is the worst shape of failure for the one tool whose whole
# pitch is "runs it here, in the foreground, which is what you want when you are
# watching it": a divergence presents as "it works in the foreground", which sends
# the next hour in the wrong direction.
# ⭐ THE CURE IS THE ONE ALREADY APPLIED TO THE PORT, ONE FIELD OVER. serve_port
# stopped being a literal for exactly this reason — "ds4's copy read 8000, which is
# VLLM's port" — and deriving it meant the two could no longer disagree. The argv is
# the neighboring value that never got the same treatment.
#
# WHAT IT RUNS IS THE SERVER'S OWN SEQUENCE, IN THE SERVER'S ORDER:
#   serve::read_config     the five serve settings and the refusals that come with
#                          them (unreadable cfg, a host we cannot honor, a
#                          half-configured TLS pair). We stop where the server stops.
#   source the build-spec  COMFYUI_ARGV_HEAD/TAIL, the flag table, comfyui_argv.
#   droste::cfg_apply      step 6 of resolve::apply_spec — the SAME function both
#                          doors use, a child shell and an env diff, never a source.
#   comfyui_argv           step 7's argv-building half, and only that half.
#   apply_port/host/tls    serve::maybe_launch's last three lines, verbatim, so the
#                          address and port land in the flags this box spells its own
#                          way (--listen) without a second table of spellings here.
#
# 🚨 comfyui_argv, NOT PRE_LAUNCH, AND THAT IS WHY THIS IS CHEAP. comfyui_pre_launch
# also syncs the model tree, chmods /opt/ComfyUI/temp and reclaims root-owned files —
# work that belongs to a container start and wants privileges a login shell does not
# have. comfyui_argv was split out of it to be callable alone: "Its own function so it
# can be driven alone (source the spec, call it, print SERVICE) without the mounts,
# the profile.d source or the model scan."
# ⚠️ SO A NEW SETTING MUST BE TRANSLATED INSIDE comfyui_argv, NEVER IN PRE_LAUNCH
# AROUND IT. One emitted outside it would reach the service and not this lane, which
# is the exact defect this function exists to end.
#
# ⚠️ STDERR IS NOT DISCARDED HERE, UNLIKE serve_port / serve_addr / serve_host. Those
# three run at BANNER time, on every login, where a warning is noise in front of a
# prompt. This one runs because the user typed a command and is about to watch a
# server in the foreground, so comfyui_argv's "that value is not valid, using the
# default" and cfg_apply's own warnings are precisely what they need to read — and
# they are the same sentences the supervised lane writes to the serve log.
service_argv() {
  ( set +e +u +o pipefail
    [ -r /opt/resources/resolve/droste-serve.sh ] || exit 1
    # shellcheck disable=SC1091
    . /opt/resources/resolve/droste-serve.sh >/dev/null </dev/null || exit 1
    # ⚠️ AGAIN, AFTER THE SOURCE. droste-serve.sh sets -euo pipefail as it loads, so
    # the options set above are gone by here; droste-healthcheck.sh does the same
    # `set +e` in the same place and for the same reason.
    set +e +u +o pipefail
    serve::read_config
    # We refuse wherever the SERVER refuses, on its reasons rather than a second set
    # of ours — and server_status prints the sentence itself, so it is not restated
    # here in a fourth wording.
    [ -z "${SERVE_CONFIG_ERR:-}" ] || exit 1
    [ -n "${SERVE_PORT:-}" ]       || exit 1
    spec=${DROSTE_BUILD_SPEC:-/opt/resources/build-spec}
    [ -r "$spec" ] || exit 1
    # shellcheck disable=SC1090
    . "$spec" >/dev/null || exit 1
    droste::cfg_apply "${CFG_FILE:-}" >/dev/null
    comfyui_argv >/dev/null || exit 1
    # ⚠️ THE MODEL-PATHS CONFIG IS DROPPED WHEN ITS FILE IS ABSENT, and that guard is
    # older than this function: the file is seeded by the resolver, so "plain toolbox
    # has no /opt/config/extra_model_paths.yaml, and ComfyUI's unguarded open() would
    # crash on the missing file." The SERVICE lane never meets that case (the resolver
    # seeds the file before anything builds an argv); this lane can, so the guard
    # stays — but the flag and the path are READ FROM THE SPEC now instead of typed.
    # ⭐ THE `-eq 2` IS THE ASSUMPTION MADE EXPLICIT, not a length check: the tail is a
    # flag and its file. If it ever stops being that pair the guard simply does not
    # fire, and a missing file becomes ComfyUI's own loud open() error — which is what
    # the service lane already does with it, and far better than dropping two tokens
    # chosen by position.
    # 🚨 IT RUNS HERE, BEFORE THE THREE APPLIES, AND THAT ORDER IS LOAD-BEARING. The
    # tail is the last thing in SERVICE only as comfyui_argv leaves it: serve::apply_tls
    # APPENDS its two flags (nothing in comfyui_argv emits a certificate, so
    # serve::_apply_flag finds none to replace), so a drop placed after it removes
    # `--tls-keyfile <path>` and leaves the model-paths flag it was aiming at. MEASURED,
    # not reasoned — it was written after the applies and bannerhost's TLS row caught it
    # on the first run.
    if [ "${#COMFYUI_ARGV_TAIL[@]}" -eq 2 ] && [ ! -f "${COMFYUI_ARGV_TAIL[1]}" ]; then
        SERVICE=( "${SERVICE[@]:0:${#SERVICE[@]}-2}" )
    fi
    serve::apply_port "$SERVE_PORT"
    serve::apply_host "$SERVE_HOST"
    serve::apply_tls
    printf '%s\0' ${SERVICE[@]+"${SERVICE[@]}"}
  )
}

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
    printf '  logs: tail -f /opt/program/logs/comfyui-serve.log\n\n'
    printf 'To run one here in the foreground instead, stop the server first:\n'
    printf '  server_stop\n'
    printf 'That lasts until the box restarts. For a permanent change, set\n'
    printf 'DROSTE_COMFYUI_STARTUP_ENABLED=no in /opt/config/comfyui.cfg.\n'
    return 1
  fi
  # REFUSE rather than bind wider than asked (Jei, s60). A DROSTE_COMFYUI_HOST we
  # cannot honor used to be ignored here in favor of 0.0.0.0 — every interface,
  # on a box with no authentication — which is the one outcome a user narrowing the
  # bind was trying to avoid. The message names the setting and the file; the
  # per-value diagnosis (IPv6 vs not-an-address) belongs to serve::read_config and
  # is printed by the server lane, so it is not restated here in a second wording.
  # ⚠️ THE VERDICT IS WHAT IS WANTED HERE, NOT THE ADDRESS — service_argv below gets
  # its own from serve::read_config, which applies serve::_is_ipv4 to the same setting
  # in the same file and therefore cannot reach a different answer. This gate stays
  # because it names the LIKELIEST mistake in the user's own terms; the generic
  # refusal further down would only be able to say "something in the file".
  if ! serve_host >/dev/null; then
    printf 'NOT STARTING: DROSTE_COMFYUI_HOST in /opt/config/comfyui.cfg cannot be used\n'
    printf 'as a bind address, and this shell will not pick a wider one for you.\n'
    printf '  - put an IPv4 literal there (e.g. 127.0.0.1), or\n'
    printf '  - delete the line to bind 0.0.0.0, the default.\n'
    printf 'server_status says the same about the supervised server.\n'
    return 1
  fi
  # The argv, built from this box's config the way the server builds it. NUL-delimited
  # because a catch-all value may legitimately contain spaces — DROSTE_COMFYUI_EXTRA_ARGS
  # is tokenized by droste::split_args, which honors quoting, and a newline- or
  # space-delimited hand-off here would undo that one step before exec.
  # 🚨 A FAILURE REFUSES; IT DOES NOT FALL BACK TO THE OLD LITERALS. Those literals are
  # what this function was written to delete, and a fallback to them would be silent,
  # rare, and wrong in exactly the cases where someone is already debugging. There is
  # nothing to widen here either — the refusal costs a foreground run, not a bind.
  local argv=()
  mapfile -d '' -t argv < <(service_argv)
  if [ "${#argv[@]}" -eq 0 ]; then
    printf 'NOT STARTING: the settings in /opt/config/comfyui.cfg could not be turned\n'
    printf 'into a command line, so there is nothing here that is safe to run.\n'
    printf 'server_status says what is wrong, in the same words the server uses.\n'
    return 1
  fi
  printf 'Tip: server_start runs ComfyUI in the background, supervised, and\n'
  printf 'survives you closing this shell. start_comfy_ui runs it here, in the\n'
  printf 'foreground, which is what you want when you are watching it.\n\n'
  # The cd is the service lane's too (comfyui_pre_launch ends with it), for any path
  # ComfyUI resolves relatively; the argv's own main.py is absolute regardless.
  cd /opt/ComfyUI && "${argv[@]}"
}
