# ── Per-box configuration ────────────────────────────────────────────────────
# The port prompt lives HERE, not with the other ask_* atoms, and the move is
# deliberate: it is the only prompt that has to know something about droste
# itself. Validating a number needs nothing but the number, but refusing a port
# ANOTHER box has already been given means reading BOX_NAME, BOXES and CFG_PORT
# — three project globals — and those three were the whole of the prompt
# layer's dependence on this program. So it sits beside the code that stores
# what it produces (configure_box, immediately below), which is where a reader
# looking for "where does the port come from" would look anyway.
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
  # binds. /opt/data is where the box seeds <box>.cfg, so this path is what
  # decides where the box reads its settings from — and where the installer
  # merges the port and box-start answers after the first start.
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
    printf '# service up (the init hook reads %s/%s\n' "$data" "${BOX_CFG[$box]}"
    printf '# at every start and launches on the port recorded there).\n'
    # The record of what this installer last answered — read back on the next
    # run as the fallback for <box>.cfg (port, box start) and for the systemd
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
    # box whose <box>.cfg turns serving on later is supervised without a recreate.
    flags+=" --health-cmd $HEALTH_CMD"
    flags+=" --health-interval $HEALTH_INTERVAL"
    flags+=" --health-timeout ${BOX_HEALTH_TIMEOUT[$box]}"
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
    printf '# /opt/data = this box%s PERSISTENT state (your work and the seeded\n' "'s"
    printf '# configs, %s among them) — never wiped. /opt/program-cache\n' "${BOX_CFG[$box]}"
    printf '# = its PROGRAM CACHE (venv upper, scratch, per-box caches) — the\n'
    printf '# installer offers to empty it when it finds an older generation there.\n'
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

# ── The box's settings file: recording the two answers we asked for ──────────
# 🚨 THE INSTALL ORDER IS THE WHOLE DESIGN, AND IT IS NOT A CONVENTION:
#     create → START (the start is what SEEDS <box>.cfg) → cfg_set → restart.
# <box>.cfg is seeded `if_missing` by apply_templates.py at the box's FIRST
# CONTAINER START, and the seeder SKIPS a destination that already exists. An
# installer that wrote the file FIRST would leave a small stub that PERMANENTLY
# BLOCKS the seed: the user would get a config file holding the serve settings
# and NONE of the several hundred documented application settings, with nothing
# failing and nothing warning. cfg_set REFUSES to create a missing file, which
# is what turns this ordering into a guarantee — see the refusal in cfg_set, and
# do not add a create path at either end.
#
# ⚠️ The box is therefore STARTED even at the rung that only creates. That start
# is not "running the box": the FIRST start has no cfg to read, so the serve
# intent reads as absent, no server is launched (contract B2), and create_box
# puts the container back to the state the rung asked for afterwards. The
# alternative is dropping two answers the user just gave on the floor.
#
# NEVER touched for a KEPT box (keep = "change nothing about settings"): only a
# box being created gets here at all, and only the settings it was ASKED about
# are merged. Every other byte of the file is the user's and comes out exactly
# as it went in.

# How long to wait for the seed. The init hook mounts the overlays and, on a
# comfyui box with no registry yet, scans the model tree — minutes, not seconds.
# The template step runs before the launch but after the mounts, so this has to
# be generous; it is a CEILING, not a delay (the poll returns the moment the
# file settles).
CFG_SEED_WAIT=300
cfg_wait_seed() {  # file → 0 once it exists and has stopped growing, 1 on timeout
  local f=$1 i=0 n=$(( CFG_SEED_WAIT * 2 )) cur="" prev=""
  while [[ $i -lt $n ]]; do
    if [[ -f $f ]]; then
      # apply_templates.py seeds with shutil.copy2, which is NOT atomic: the file
      # can exist while it is still being written. Two consecutive polls agreeing
      # on a non-zero size is the cheap way to not merge into half a file.
      cur=$(wc -c < "$f" 2>/dev/null) || cur=""
      if [[ -n $cur && $cur -gt 0 && $cur == "$prev" ]]; then return 0; fi
      prev=$cur
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# Merge this run's answers into the box's settings file. Runs as one run_step
# child, so everything it says lands in that step's log; it reports a real value
# CHANGE by touching the marker file, which is what tells create_box whether a
# restart is owed. (A child cannot hand a variable back to the parent.)
#
# The vocabulary is the file's OWN: STARTUP_ENABLED's menu reads {yes, no*}, so
# that is what gets written. The retired server.env wrote `1`, which under a
# {yes, no} menu would have the user open their config file and find a value
# that is not in its own list of values.
write_box_cfg() {  # box marker → 0 recorded, 1 something could not be recorded
  local box=$1 marker=$2 f key val name cur rc=0
  f=$(box_cfg_file "$box") || return 0
  [[ -n $f ]] || return 0
  f=$(fs_path "$f")      # the box's data dir, as the kernel needs it spelled
  if ! cfg_wait_seed "$f"; then
    warn "$f has not appeared after ${CFG_SEED_WAIT}s $EMD the box seeds it at its first start, so your port and startup answers were not recorded"
    return 1
  fi
  for key in STARTUP_ENABLED PORT; do
    case $key in
      STARTUP_ENABLED) val=$([[ -n ${CFG_BOXSV[$box]:-} ]] && printf yes || printf no) ;;
      PORT)            val=${CFG_PORT[$box]} ;;
    esac
    name=$(cfg_name "$box" "$key")
    cur=$(cfg_get "$name" "$f")
    if ! cfg_set "$name" "$val" "$f"; then rc=1; continue; fi
    # The marker means "a value on disk is not what it was", which is the only
    # thing a restart is for. cfg_set is idempotent — an unchanged value writes
    # nothing at all — so this mirrors its own no-op test rather than guessing.
    # No marker (mktemp failed) is not an error here: the caller then treats the
    # settings as changed, which costs a restart and is the safe direction.
    if [[ -n $marker && $cur != "$val" ]]; then printf '1\n' > "$marker" || :; fi
  done
  return $rc
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

