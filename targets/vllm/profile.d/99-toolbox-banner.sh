#!/usr/bin/env bash
# Lightweight banner with machine/GPU and ROCm version (vLLM edition)
# No Triton env sourcing, same info/format as the image/video banner.

# Only show for interactive shells
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
  # Prefer the PyTorch HIP version from the venv, fallback to rocm pkg metadata
  local PY="/torch-therock/.venv/bin/python"
  [[ -x "$PY" ]] || PY="python"
  "$PY" - <<'PY' 2>/dev/null || true
try:
    import torch
    v = getattr(getattr(torch, "version", None), "hip", "") or ""
    if v:
        print(v)
    else:
        raise Exception("no torch.version.hip")
except Exception:
    try:
        import importlib.metadata as im
        try:
            print(im.version("_rocm_sdk_core"))
        except Exception:
            print(im.version("rocm"))
    except Exception:
        print("")
PY
}

# The port this box's service ACTUALLY listens on. In the merged (distrobox)
# lane the init hook launches `vllm serve` with DROSTE_VLLM_PORT from
# /opt/data/vllm.cfg (appended as --port, which outranks the `port:` key in
# vllm_config.yaml), so a baked-in number in the text below would be wrong for
# every box that changed it.
# 🚨 PARSED, NEVER SOURCED (s60). The two serve keys used to live in a
# droste-owned server.env, which was safe to source; they now live in the USER's
# own vllm.cfg, several hundred lines of their settings. So this asks
# droste::cfg_get — the scanning reader written for exactly this — and gets a
# VALUE back instead of executing the user's file at every login.
# The rest of the discipline is unchanged and deliberate: the read runs in a
# SUBSHELL with errexit/nounset off, its stdin closed and its stderr discarded
# (cfg_get warns about a mangled line, and a login banner is not where a user
# wants to meet that), then the answer is range-checked — so a missing,
# unreadable or hand-mangled file quietly falls back to the in-container default
# (8000: vllm's own) instead of printing garbage or failing the login shell. The
# LAST assignment wins, which is cfg_get's rule as it was sourcing's.
# ⚠️ The path is a literal here rather than read from the baked build-spec's
# CFG_FILE, and that is the point: the file we tell the user to edit further down
# and the file we read here must be the same string, guaranteed by being one.
serve_port() {
  local def=8000 file="${DROSTE_SERVE_ENV:-/opt/data/vllm.cfg}" pv=""
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
      droste::cfg_get DROSTE_VLLM_PORT "$file"
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
# DROSTE_VLLM_HOST is a user setting now, so a box bound to one interface would
# otherwise be handed a URL that answers nothing — the same silent-lie defect as
# a stale port, on the first thing a user reads.
# Asks droste-serve.sh's serve::probe_addr: THE single source every probe in this
# project uses, so the banner and the healthcheck cannot disagree about where the
# server is. Deriving it here instead would copy two rules (the wildcard test and
# the IPv4 validation, which rejects e.g. a leading-zero octet the server would
# never have bound) into a place nobody would think to update.
# Run in a SUBSHELL, same discipline as serve_port: sourcing that library sets a
# dozen DROSTE_* defaults, turns errexit back on and defines the serve::
# namespace, none of which belongs in a user's interactive shell — and a library
# that is missing or broken must not take the login with it.
# ⚠️ THIS IS A DISPLAY ADDRESS, NOT A BIND ADDRESS. probe_addr answers "where do
# I reach it", so a wildcard bind comes back as loopback — right in a URL and
# catastrophic in a --host flag, which would then bind loopback ONLY.
# 127.0.0.1 is rendered `localhost`: the same endpoint, the friendlier spelling,
# and the text every box printed before HOST was a setting. Anything that is not
# a specific dotted quad lands there too — a validated shape check on our own
# library's answer, so a change upstream of us cannot put a hostname, an empty
# string or a wildcard into a printed URL.
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

# serve_host — the address to BIND, for the ad-hoc `vllm serve` row printed below.
# Prints a usable IPv4 literal and returns 0; prints NOTHING and returns 1 when the
# configured one cannot be honoured.
#
# 🚨 THIS IS THE OTHER ADDRESS QUESTION AND serve_addr CANNOT ANSWER IT. probe_addr
# maps the wildcard to loopback because "where do I browse" and "what do I bind"
# have different right answers, so printing it as a --host would tell the user to
# bind loopback ONLY. This reads the SETTING instead: same file, same parser
# (droste::cfg_get), same IPv4 rule the server lane applies (serve::_is_ipv4). That
# rule is CALLED, never copied — a second dotted-quad test here is the duplicated-
# validation defect this project keeps paying for.
#
# 🚨 A FAILURE IS NEVER RESOLVED TOWARD A WIDER BIND (Jei, s60: "fail"). Until s60
# the row below printed `--host 0.0.0.0` as a literal, so a user who narrowed their
# box's bind was handed a command that undoes it — and handed it by us, which is
# worse than them typing it. This box serves an OpenAI-compatible API with no
# authentication in front of it, which is what makes the widening expensive. Absent
# or blank is our documented default and yields 0.0.0.0; anything we cannot honour
# returns 1, and no command is printed at all.
#
# The three arms, each chosen rather than fallen into:
#   no config file      → 0.0.0.0. Nothing to honour, and it is what the server
#                         lane reads from the same absence.
#   exists, unreadable  → REFUSE. The setting may narrow the bind and we cannot
#                         see it; the server lane refuses to serve on this file at
#                         all, so a printed recipe that guessed would be the one
#                         thing on the box ignoring the user's own file.
#   library unreachable → REFUSE, same reason. Unable to read is not permission to
#                         widen.
# Same subshell discipline as serve_port and serve_addr: errexit/nounset off, stdin
# closed, stderr discarded from the first line INSIDE (a trailing redirect on the
# assignment runs after the substitution and silences nothing), and the library's
# serve:: namespace left in there rather than in a user's interactive shell.
serve_host() {
  local h file="${DROSTE_SERVE_ENV:-/opt/data/vllm.cfg}"
  [ -f "$file" ] || { printf '0.0.0.0\n'; return 0; }
  [ -r "$file" ] || return 1
  h=$(
    set +e +u +o pipefail
    exec 2>/dev/null
    [ -r /opt/resources/resolve/droste-serve.sh ] || exit 1
    # shellcheck disable=SC1091
    . /opt/resources/resolve/droste-serve.sh >/dev/null </dev/null || exit 1
    v=$(droste::cfg_get DROSTE_VLLM_HOST "$file")
    # A blank behaves exactly as absent (s57): our default, never the empty string
    # — which as a --host argument is a bind failure, not a default.
    [ -n "$v" ] || { printf '0.0.0.0\n'; exit 0; }
    serve::_is_ipv4 "$v" || exit 1
    printf '%s\n' "$v"
  ) || return 1
  # Nothing is re-validated out here on purpose: the one rule already ran inside,
  # and a weaker copy of it in this shell is the second implementation the note
  # above refuses. The emptiness test is not that copy — it is the guard against
  # printing a flag with no argument after it.
  [ -n "$h" ] || return 1
  printf '%s\n' "$h"
}

MACHINE="$(oem_info)"
GPU="$(gpu_name)"
ROCM_VER="$(rocm_version)"
SERVE_PORT="$(serve_port)"
SERVE_ADDR="$(serve_addr)"
# The BIND address for the ad-hoc row, and an empty string is its refusal: the row
# says why instead of printing a command with a wider address than the user asked
# for. `|| SERVE_BIND=""` because a failing command substitution would otherwise
# leave a non-zero $? sitting in a login shell.
SERVE_BIND="$(serve_host)" || SERVE_BIND=""

echo
printf '%s\n' \
  $'             \033[1;97m ╔\033[1;96m═╤\033[1;94m═╤\033[0;34m════╗ \033[1;90m🭺🭺🭺🭺🭺\033[0;37m🭺🭺🭺🭺🭺🭺\033[1;97m🭺🭺🭺🭺🭺🭺🭺🭺\033[0;37m🭺🭺🭺🭺🭺🭺\033[1;90m' \
  $'             \033[1;96m ╟─┘\033[0;37m■\033[0;94m│\033[0;34m    ║ \033[1;90m █🮂🮂\033[0;37m🭕🭏    \033[1;97m        \033[0;37m🭋' \
  $'             \033[1;94m ╟───┘ \033[0;34m\033[1;97m██ \033[0;34m║ \033[1;90m █ \033[0;37m  █ 🭩🬂\033[1;97m🭗🭄🮂🭏 🭄🮀🭧\033[0;37m🭢🬨🬂🭗🭂🮀\033[1;90m🭍' \
  $'             \033[0;34m ║ \033[0;34m\033[0;34m\033[0;34m       ║ \033[1;90m █\033[0;37m  🭊🭠 🭞\033[1;97m  🭕▂🭠 ▄ \033[0;37m🭨🭬🭦🭩🭛🭓\033[1;90m🬭🬽' \
  $'             \033[0;34m\033[0;34m\033[0;34m\033[0;34m ╚════════╝ \033[1;90m`\033[0;37m🮃🮃🮃🭘🭷🭷\033[1;97m🭷🭷🭷🭷🭷🭷🭷🭣\033[0;37m🬂🭘🭷🭷🭷🭷\033[1;90m🭷🭷🭷🭷\033[0m'
cat <<'ASCII'
                      vLLM: Interactive Box

ASCII
echo
printf 'AMD Ryzen AI Max Strix Halo: vLLM Toolbox (gfx1151, ROCm via TheRock)\n'
[[ -n "$ROCM_VER" ]] && printf 'ROCm nightly: %s\n' "$ROCM_VER"
echo
printf 'Machine: %s\n' "$MACHINE"
printf 'GPU    : %s\n\n' "$GPU"
printf 'Image : ghcr.io/doctorjei/droste-vllm-halo\n'
printf 'Repo  : https://github.com/doctorjei/droste-ai-halo\n\n'
printf 'This box runs an OpenAI-compatible vLLM server on port %s when it starts.\n' "$SERVE_PORT"
printf 'Config file: /opt/data/vllm_config.yaml  (vllm serve --config).\n'
printf 'With no model: set there, vLLM serves its own default, Qwen/Qwen3-0.6B.\n\n'
printf 'Usage:\n'
printf '  - %-18s → %s\n' "Pick a model" "edit model: in /opt/data/vllm_config.yaml"
printf '  - %-18s → %s\n' "vLLM server"  "starts with the box; commented MODEL_TABLE stanzas in the config"
# The --host is DROSTE_VLLM_HOST, not the display address above: this row is a
# command the user will run, so it must bind what the box was configured to bind.
# When that setting cannot be honoured the command is WITHHELD (Jei, s60: "fail") —
# printing `--host 0.0.0.0` regardless is how a user who deliberately narrowed the
# bind ends up serving an unauthenticated API on every interface.
if [[ -n "$SERVE_BIND" ]]; then
  printf '  - %-18s → %s\n' "Ad-hoc serve" "vllm serve <model> --host $SERVE_BIND --port $SERVE_PORT"
else
  printf '  - %-18s → %s\n' "Ad-hoc serve" "not shown: fix DROSTE_VLLM_HOST in /opt/data/vllm.cfg"
  printf '  %-20s   %s\n' "" "(an IPv4 literal, or delete the line to bind 0.0.0.0)"
fi
printf '  - %-18s → %s\n' "API test"     "curl $SERVE_ADDR:$SERVE_PORT/v1/chat/completions"
echo
printf 'Server control (acts on the SERVER, not the box):\n'
printf '  - %-18s → %s\n' "server_status" "what the box wants, and what is really true"
printf '  - %-18s → %s\n' "server_start" "start it now; server_stop / server_restart too"
printf '  - %-18s → %s\n' "server_stop" "lasts until the box restarts, not beyond"
printf '  - %-18s → %s\n' "at box start" "DROSTE_VLLM_STARTUP_ENABLED in /opt/data/vllm.cfg"
echo
# The middle field is the address the FORWARD lands on at the far end, so it has
# to be the one the server actually bound: with host networking the listener is
# on the host itself, and `localhost` there answers nothing on a box whose
# DROSTE_VLLM_HOST names one interface.
printf 'SSH tip: ssh -L %s:%s:%s user@host\n\n' "$SERVE_PORT" "$SERVE_ADDR" "$SERVE_PORT"

unset PROMPT_COMMAND
PS1='\u@\h:\w\$ '
