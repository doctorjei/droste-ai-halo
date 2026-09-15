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
    # 🚨 [[:digit:]], NOT [0-9], AND A LENGTH CAP AND 10#. All three are load-
    # bearing, and each one alone left a value that REACHED the arithmetic and
    # was then ACCEPTED — an error printed by `(( ))` makes the condition false,
    # so the bad port sailed past the guard and into the box's config:
    #   `１`  — [0-9] is a locale-collating RANGE and matched it (en_US.UTF-8)
    #   `08`  — read as octal: "value too great for base"
    #   a 20-digit number — silently WRAPS, so it can land back inside 1-65535
    # ⭐ POSIX pins [[:digit:]] to 0-9 in every locale. ⚠️ [[:alnum:]] does not.
    if [[ ! $ANS =~ ^[[:digit:]]{1,5}$ ]] || (( 10#$ANS < 1 || 10#$ANS > 65535 )); then
      say "  Please give a port number (1-65535)."
      continue
    fi
    # ⭐ NORMALIZE ONCE, HERE, AND EVERYTHING DOWNSTREAM COMPARES LIKE WITH LIKE.
    # The duplicate check below is a STRING comparison against other boxes'
    # recorded ports, so an accepted `08` would not match a recorded `8` and two
    # boxes could be handed the same port with no complaint. The value the user
    # meant is the same number either way; the spelling is ours to settle.
    ANS=$((10#$ANS))
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

# What the PORT PROMPT offers, and nothing else. Same shape as path_default():
# a modify run's defaults come from the recorded entries and fall back to the
# fresh ones ("one question set, three run types"), which is why this is the one
# place left that may test ACTION.
port_default() {  # box → the port to offer at the prompt
  local box=$1
  if [[ ${ACTION[$box]} == modify && -n "${EXD_PORT[$box]:-}" ]]; then
    printf '%s' "${EXD_PORT[$box]}"
  else
    printf '%s' "${BOX_HOST_PORT[$box]}"
  fi
}

# 🚨 THE PORT DECISION, IN ONE PLACE — AND AN ELECTION IS AN ANSWER (S2a, s67).
# "Use default ports for all services" is a question the user answered YES to;
# the value it settles is THE DEFAULT, for a box that already exists exactly as
# much as for a new one. This function used to fall back to `port_default` on
# that branch, so a modify run on a box carrying a recorded port re-recorded THAT
# port and the election changed nothing — v0.4.0 shipped llama on 8080, v0.5.0
# moved it to 9931, and every box created before the move kept 8080 however the
# question was answered, while the README documented the new one.
# ⚠️ THE ELECTION IS THE ONLY THING THAT MAY OVERWRITE A RECORDED PORT. A user
# who declined it is asked, and the prompt still OFFERS what their box already
# has — so a custom port survives unless its owner says otherwise. That
# narrowness is the whole licence: write_box_cfg merges this value into a file
# that is otherwise seeded `if_missing` and never overwritten.
set_box_port() {  # box → CFG_PORT[box]  (prompts only when defaults were declined)
  local box=$1
  if [[ $PORTS_DEFAULT -eq 1 ]]; then
    CFG_PORT[$box]=${BOX_HOST_PORT[$box]}
    return 0
  fi
  ask_port "$box" "$(port_default "$box")"
  CFG_PORT[$box]=$ANS_PORT
  return 0
}

# ONE section per box now ("Box Settings"), carrying whatever General Setup left
# unanswered for it: a Networking subheader (its port, and the two start
# questions when either was answered "case-by-case") and a "<Box> Paths"
# subheader (the binds no wholesale answer placed). A box with nothing left to
# ask shows its banner and its summary, and no section at all.
configure_box() {  # box
  local box=$1 pair label dest
  local asked=0 bw sv_def=N hs_def=N
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
  # The decision and the prompt both live in set_box_port; want_port only
  # decides whether a SECTION is opened for it (nothing is asked when the
  # install-wide election already settled every port).
  set_box_port "$box"
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
  # The program dir FIRST (+ fs probe / overlay mitigation), then the other
  # CRITICAL binds — `config` among them since s79, and first in that list.
  # ⭐ WHY THE PROGRAM DIR LEADS EVEN THOUGH CONFIG IS THE MORE PRECIOUS ROOT:
  # path_derived hangs every other data-family bind off the PARENT of the settled
  # program dir, and the overlay-filesystem question is asked about the root that
  # carries the uppers. Both of those are the program dir's, so it has to be
  # answered before anything can be derived from it.
  # /opt/config is where the box reads its settings from, and where the installer
  # merges the port and box-start answers before the box has ever started.
  if [[ ${#todo[@]} -gt 0 ]]; then
    if [[ $asked -eq 0 ]]; then
      asked=1
      section "Box Settings"
    fi
    subhdr "${BOX_NAME[$box]} Paths"
    PATHS_HDR=1
  fi
  set_bind_path "$box" program
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
  # 🚨 THE RECORD FOLLOWS THE DATA, IMMEDIATELY. Until s69 the ini was written
  # only in the Executing phase, so a ^C anywhere between here and there left the
  # data at its NEW path and the ini naming the OLD one, with nothing detecting
  # it on any later run. Jei hit exactly that in s47 and repaired his box by hand.
  # ⚠️ EVERY INPUT emit_ini NEEDS IS ALREADY SETTLED AT THIS LINE, which is what
  # makes this safe rather than a partial record: CFG_PORT, CFG_BOXSV and
  # CFG_HSTSV are answered above (set_box_port and the two serve questions), and
  # PATHS is what relocate_box just finished settling. Checked, not assumed.
  # ⭐ Only when something MOVED — see RELOC_MOVED. A box that moved nothing has
  # no record to get out of step, so it writes nothing until Executing, exactly
  # as before; that keeps the blast radius to the case being fixed.
  # ⚠️ execute() rewrites this file later. That is not waste and must not be
  # "optimised" away: this write exists to be there when the later one never
  # happens.
  [[ $RELOC_MOVED -eq 1 ]] && emit_ini "$box"
  # BEFORE the cache question, deliberately: on a box from before s79 the two are
  # about the SAME directory — one says where that box's own installs are, the
  # other asks whether to empty the root they sit on — and the statement has to
  # land before the question, not after it.
  report_moved_uppers "$box"
  # And before anything at all is written: a config left at the retired path is
  # the one failure here that is silent, so it is said while the run can still be
  # stopped with ^C and nothing has been created.
  report_retired_configs "$box"
  stale_cache_offer "$box"
  # UNCONDITIONAL, no question, and silent when it works — an empty directory
  # contains nothing to lose, so there is no consent to ask for. AFTER the offer
  # above on purpose: a cleared cache takes the whole venv upper with it and
  # leaves this nothing to find, while a DECLINED clear (or a box that was never
  # asked) is exactly the case this exists for.
  sweep_overlay_debris "$box"

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
  vals+=("$(path_default "$box" program)")
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
  # data root, PATHS holds the spelling that was chosen for it.
  keys+=("$(bind_row program):") vals+=("${PATHS["$box:program"]}") kind+=(v)
  for pair in ${BOX_EXTRA_BINDS[$box]}; do
    label=${pair%%:*}
    keys+=("$(bind_row "$label"):") vals+=("${PATHS["$box:$label"]}") kind+=(v)
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
  # SIMPLE: the box is a LIST. No borders, so no width to pad to and no fitting
  # to do -- a value that would have been shortened to fit inside a frame is
  # printed whole, which is the point of the plain rendering.
  if [[ $SIMPLE -eq 1 ]]; then
    for (( i = 0; i < n; i = i + 1 )); do
      case ${kind[i]} in
        s) printf '\n' ;;
        g) printf '  %s_%s_%s\n' "$C_SGRP" "${keys[i]}" "$RESET" ;;
        *) printf '    %s- %s%-*s %s%s%s\n' \
             "$C_SBUL" "$C_SHDR" "$SUM_HDR_W" "${keys[i]}" \
             "$C_SVAL" "${vals[i]}" "$RESET" ;;
      esac
    done
    return 0
  fi
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
      # RESET lands before the padding (a colored blank is a blank, an
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
  data=${PATHS["$box:program"]}
  # dry::skip rather than dry::fs: the write IS this function — forty printf
  # lines into one redirect, with no single command a wrapper could stand in
  # front of. ⚠️ It returns before `exec_file`, which is the status line, so a
  # dry run says "would write" instead of "wrote" and cannot claim both.
  dry::skip "write $f" && return 0
  {
    # 📐 THE VERSION STAMP, FIRST LINE, SAME SPELLING AS EVERY CONFIG FILE THIS
    # INSTALLER WRITES (ruled s73: "Its own line is best"). ⚠️ NOT folded into the
    # `# droste-setup:` record below, which is a different thing — that one is the
    # answers this run gave, read back by parse_existing_ini; this one is who
    # wrote the file. One question per line.
    # ⚠️ A COMMENT, so distrobox's ini parser ignores it and parse_existing_ini
    # does not see a new key.
    printf '# droste-version: %s\n' "$DROSTE_VERSION"
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
    # 📐 THE THREE ROOTS LEAD, IN TAXONOMY ORDER — config, program, cache — which
    # is the order resolve::apply_spec ensures them in, the order NOTES.md explains
    # them in, and the order every shipped targets/<box>/distrobox.ini writes them
    # in. ⚠️ emitguard compares this list against those samples POSITION BY
    # POSITION, so the three are not free to drift apart.
    # ⚠️ `config` IS a BOX_EXTRA_BIND (it is prompted and summarised like one), so
    # the loop below has to skip it or it would be written twice. That skip is the
    # price of leading with it, and it is cheaper than a second table.
    vols="$(fs_path "${PATHS["$box:config"]}"):/opt/config"
    spell="${PATHS["$box:config"]}:/opt/config"
    vols="$vols $(fs_path "$data"):/opt/program"
    spell="$spell $data:/opt/program"
    # The box's PROGRAM CACHE root, right behind its program dir: the overlay
    # WORK dirs and every copy-mode materialization live here, and so does the
    # server's per-start state. It is not a BOX_EXTRA_BIND (nobody is asked about
    # it as a work dir), so the bind is written here, by name, for every box.
    # ⚠️ THE VENV UPPER LEFT THIS ROOT IN s79. It is under the program dir above,
    # which is the root nothing here ever offers to empty.
    vols="$vols $(fs_path "${PATHS["$box:pcache"]}"):/opt/program-cache"
    spell="$spell ${PATHS["$box:pcache"]}:/opt/program-cache"
    for pair in ${BOX_EXTRA_BINDS[$box]}; do
      label=${pair%%:*} dest=${pair#*:}
      [[ $label == config ]] && continue      # already written, above
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
    printf '# /opt/config = this box%s CONFIG SURFACE (%s and nothing\n' "'s" "${BOX_CFG[$box]}"
    printf '# else of its kind) — never wiped, never overwritten, and nothing\n'
    printf '# gets it back. /opt/program = its PROGRAM DATA (the venv overlay\n'
    printf '# upper and its work dir, i.e. what YOU installed in the box, plus its\n'
    printf '# model tree and logs) — a reinstall would get it back, and nothing\n'
    printf '# here ever offers to delete it. /opt/program-cache = its PROGRAM\n'
    printf '# CACHE (scratch, slots, server state) — the installer offers to\n'
    printf '# empty that one when it finds an older generation there.\n'
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
#     create → WRITE the config files → start (only if the box is to serve).
# The installer copies the baked templates out of the container it just created
# — which has never been started — and writes every config file that is absent.
# The service therefore reads a FINISHED file on its first start: no seeding
# start, no merge into something that appeared underneath us, and no restart.
#
# 🗄️ THIS COMMENT USED TO STATE THE OPPOSITE ORDER AS "THE WHOLE DESIGN", and
# said outright that "an installer that wrote the file FIRST would leave a small
# stub that PERMANENTLY BLOCKS the seed". THAT REASONING WAS SOUND AND ITS
# PREMISE IS GONE: the hazard was writing a FIVE-LINE STUB holding only the serve
# settings, because `if_missing` would then skip the real template forever. We
# write the WHOLE TEMPLATE, so there is no stub to block anything, and the merge
# lands in a file that already carries every documented application setting.
# ⚠️ Do not "restore" the old order from a stale note: it exists to serve a
# seeding step that is being removed (plans/installer-owns-config-s73.md).
#
# ⭐ cfg_set STILL REFUSES to create a missing file, and that refusal is worth
# keeping for a different reason now: it is what makes "the file exists because
# WE wrote it" checkable rather than assumed. Do not add a create path there.
#
# ⚠️ A box that is not meant to serve is therefore NOT STARTED during the
# install at all. The start existed to make the seeding happen; with the seeding
# gone, the only surviving reason to start is the [A] rung's own.
#
# NEVER touched for a KEPT box (keep = "change nothing about settings"): only a
# box being created gets here at all, and only the settings it was ASKED about
# are merged. Every other byte of the file is the user's and comes out exactly
# as it went in.

# 🗑️ `cfg_wait_seed` + `CFG_SEED_WAIT` LIVED HERE AND WERE DELETED IN s77. They
# polled for up to 300 s waiting for the IMAGE to seed <box>.cfg at the box's
# first start, and watched the size settle because `shutil.copy2` is not atomic
# so the file could exist while still being written. The installer writes the
# file itself now, with a temp file and a rename, so there is nothing to wait for
# and nothing that can be seen half-written. **Do not reintroduce a wait here:**
# if the file is absent after cfg_write_seeds, that is a failure to report, not a
# race to sleep through.

# ── <box>.cfg.example — the escape hatch for a file that is an OLDER SHAPE ───
# 🚨 THIS IS THE GENERAL CASE THE PORT ELECTION IS THE NARROW EXCEPTION TO (S2b,
# s67). `<box>.cfg` is seeded `if_missing` and is the user's from then on, so a
# box set up under an older image keeps its file for ever — settings we have
# since added are unreachable in it, and settings we have since retired sit in it
# reading as authoritative while doing nothing. We may not overwrite it. So we
# put what we WOULD have written next to it, and the user diffs.
#
# 📐 "EXACTLY WHAT WOULD HAVE BEEN WRITTEN HAD NO FILE EXISTED" is a two-step
# recipe, and both steps are here: the baked template as the box would have
# copied it, then the same cfg_set merges the caller is about to make into the
# real file. Miss the second and the example is not the file a fresh box gets.
#
# The templates are read out of the box's own container, which is the only place
# they exist — the installer is a `curl | bash` script on the host and has no
# checkout.
#
# 🚨 `podman cp`, NOT `podman exec`, AND THAT IS THE WHOLE POINT (s77). `exec`
# needs a RUNNING container, which is what forced the old create → start → merge →
# restart order and made a `.cfg.example` unreachable for a box that will not
# start. `cp` works on a container that has NEVER RUN, measured on hardware for
# every shipped image: s75 via `podman create` (35/0, Loaf + Raiju, cross-checked
# on bifrost) and s77 via `distrobox assemble create`, which is how the installer
# actually creates a box (45/0, Loaf, distrobox 1.7.0) — container `created`,
# `podman diff` EMPTY, and the bytes identical to the other path's.
#
# ⚠️ ONE `cp` OF THE WHOLE DIRECTORY, not one per file: it is the shape that was
# measured, and it is what puts `templates.yaml` itself in our hands — which is
# what lets cfg_write_seeds DERIVE the file list instead of restating it.
# ⚠️ THE DESTINATION MUST NOT EXIST. `podman cp <dir> <existing-dir>` NESTS (you
# get dest/templates/…) while into an absent dest it does not, and `<dir>/.`
# copies the contents — one command, three meanings, so it is picked on purpose.
# ⚠️ EVERY podman FAILURE HERE EXITS 125, NOT 1 (measured s75): a missing path in
# the container, a missing host destination, a container that is not there. Test
# for non-zero; never branch on 1.
# ⚠️ THE CALLER OWNS THE DIRECTORY AND REMOVES IT. No EXIT trap: pull.sh already
# installs one, and bash keeps exactly one, so adding a second here would silently
# replace the pull service's cleanup.
box_templates() {  # box → a host dir holding the box's templates on stdout, 1 if not
  local box=$1 ctr dest out rc
  # 🚨 A DRY RUN HAS NO TEMPLATES, AND THAT IS THE HONEST ANSWER RATHER THAN A
  # LIMITATION. This mktemps a directory and `podman cp`s the baked templates
  # into it — real host bytes, written for the sole purpose of feeding writes a
  # dry run does not perform. Returning 1 is the same answer a box with no
  # runtime gives, and every caller already handles it.
  # ⭐ GUARDED HERE AND NOT LEFT TO write_box_cfg, though that is its only caller
  # today: "unreachable" is a fact about this week's call graph, and this
  # function's whole job is to put bytes on the disk.
  dry::on && return 1
  [[ -n ${RUNTIME:-} ]] || return 1
  ctr=$(box_ctr "$box")
  dest=$(mktemp -d "${TMPDIR:-/tmp}/droste-tmpl.XXXXXX" 2>/dev/null) || return 1
  # mktemp -d made it, so the copy would NEST. Take the name and not the
  # directory: `cp` creates it, and an absent dest is the non-nesting form.
  rmdir "$dest" 2>/dev/null || { rm -rf "$dest" 2>/dev/null || :; }
  out=$("$RUNTIME" cp "$ctr:$CFG_TEMPLATE_DIR" "$dest" 2>&1); rc=$?
  if [[ $rc -ne 0 || ! -d $dest ]]; then
    rm -rf "$dest" 2>/dev/null || :
    warn "could not read the baked templates out of $ctr $EMD $out"
    return 1
  fi
  printf '%s' "$dest"
  return 0
}

# One box's <box>.cfg template, from a directory box_templates already copied.
box_cfg_template() {  # box templates-dir → the baked template on stdout, 1 if absent
  local box=$1 dir=$2 f
  f="$dir/${BOX_CFG[$box]}"
  [[ -f $f && -r $f ]] || return 1
  cat "$f"
}

CFG_EXAMPLE=""
seed_cfg_example() {  # box cfgfile templates-dir → 0 + CFG_EXAMPLE naming the file
  local box=$1 f=$2 tdir=$3 ex tmp dir
  CFG_EXAMPLE=""
  # Returns 1, which is this function's ordinary "no example was written" — not
  # an error, and never counted against the run. ⚠️ CFG_EXAMPLE stays empty on
  # purpose: the caller feeds it to cfg_set, and a dry run that named a file it
  # did not write would predict edits to something that does not exist.
  dry::on && return 1
  ex="$f.example"                     # <box>.cfg.example, beside what it describes
  dir=$(dirname "$f")
  tmp=$(mktemp "$dir/.droste-cfg.XXXXXX" 2>/dev/null) || {
    warn "could not write in $dir $EMD no ${BOX_CFG[$box]}.example was written"; return 1; }
  # ⚠️ THE STAMP GOES ON THE EXAMPLE TOO. This file's whole contract is "exactly
  # what would have been written had no file existed", and what cfg_seed_file
  # writes carries a stamp — an unstamped example is not the file a fresh box gets.
  if ! { printf '# droste-version: %s\n' "$DROSTE_VERSION"
         box_cfg_template "$box" "$tdir"; } > "$tmp" || [[ ! -s $tmp ]]; then
    rm -f "$tmp" 2>/dev/null || :
    # NOT fatal and NOT counted against the run: the answers still got recorded
    # in the real file. Say it once, in the step log, and carry on.
    warn "the baked ${BOX_CFG[$box]} is not in the templates copied out of $(box_ctr "$box") $EMD no .example was written"
    return 1
  fi
  # ⚠️ AN EXISTING EXAMPLE IS REFRESHED EVEN WHEN THE SHAPES NOW AGREE. It is a
  # file we wrote, describing a shape that has since moved; leaving it stale
  # would hand the user a "current" copy that is not current. What we never do
  # is CREATE one for a file that is already the right shape.
  if ! cfg_shape_differs "$tmp" "$f" && [[ ! -f $ex ]]; then
    rm -f "$tmp" 2>/dev/null || :
    return 1
  fi
  # The user's own mode, not mktemp's 0600 — the example sits in their data dir
  # beside a file they read, and should be as readable as it is.
  chmod --reference="$f" "$tmp" 2>/dev/null || :
  mv -f "$tmp" "$ex" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || :
    warn "could not write $ex"; return 1; }
  CFG_EXAMPLE=$ex
  # What changed, by name: the whole value of the example is the diff, so the log
  # should say which way to read it.
  printf 'wrote %s (the current shape of %s)\n' "$ex" "${BOX_CFG[$box]}"
  # `if`, not `[[ … ]] &&`: a false test as the last command of a list is the
  # status of the list, and this runs under `set -e`.
  if [[ -n $CFG_SHAPE_ADDED ]]; then
    printf '  settings this image adds: %s\n' "$CFG_SHAPE_ADDED"
  fi
  if [[ -n $CFG_SHAPE_GONE ]]; then
    printf '  settings your file has that this image does not: %s\n' "$CFG_SHAPE_GONE"
  fi
  return 0
}

# Write this box's config files and merge this run's answers into its settings
# file. Runs as one run_step child, so everything it says lands in that step's log.
#
# 🚨 THE ORDER THIS REPLACES IS THE WHOLE POINT (s77). It used to WAIT for the
# image to seed <box>.cfg at the box's first start, merge into what appeared, and
# leave a marker behind so create_box knew a RESTART was owed — the service had
# already read a file that did not yet hold the user's answers. Now the file is
# written before the box has ever run, so there is nothing to wait for, no marker,
# and no restart: the first start reads the finished file.
#
# The vocabulary is the file's OWN: STARTUP_ENABLED's menu reads {yes, no*}, so
# that is what gets written. The retired server.env wrote `1`, which under a
# {yes, no} menu would have the user open their config file and find a value
# that is not in its own list of values.
write_box_cfg() {  # box → 0 recorded, 1 something could not be recorded
  local box=$1 f ex="" tdir key val name rc=0
  f=$(box_cfg_file "$box") || return 0
  [[ -n $f ]] || return 0
  f=$(fs_path "$f")      # the box's data dir, as the kernel needs it spelled
  # 🚨 THE WHOLE FUNCTION IS SKIPPED, AND THAT IS WHAT KEEPS `box_templates` OUT
  # OF A DRY RUN. That helper mktemps a directory and `podman cp`s the baked
  # templates into it — host bytes written for the sole purpose of feeding the
  # writes below, none of which happen here. Guarding the writes individually
  # would leave the temp dir being created and removed on a run that promised to
  # change nothing, which is a carve-out, and a carve-out is what the checker
  # cannot express.
  # ⚠️ THE COST IS NAMED RATHER THAN HIDDEN: the settings this box would be given
  # come from those templates, so a dry run says which FILES it would write and
  # not which VALUES would be in them. The two answers this run collected are
  # named below and are the ones a user is actually deciding about.
  if dry::on; then
    dry::would "write this box's config files under $(dirname "$f") where they are absent"
    for key in STARTUP_ENABLED PORT; do
      case $key in
        STARTUP_ENABLED) val=$([[ -n ${CFG_BOXSV[$box]:-} ]] && printf yes || printf no) ;;
        PORT)            val=${CFG_PORT[$box]} ;;
      esac
      dry::would "set $(cfg_name "$box" "$key")=$val in $f"
    done
    return 0
  fi
  # The baked templates, copied out of the container the ladder just created. It
  # has never run, and `podman cp` does not need it to.
  tdir=$(box_templates "$box") || return 1
  # Every config file this box seeds, written only where the host file is absent.
  cfg_write_seeds "$box" "$tdir" || rc=1
  # S2b, BEFORE the merges below and not after: the example has to receive the
  # same two values, so it exists by the time the loop runs. A box whose file we
  # just wrote is the ordinary case and produces nothing — the file we copied IS
  # the current shape.
  # ⚠️ NOT part of `rc`. Failing to write an explanatory copy must never report
  # the run's answers as unrecorded; it says so in the step log and stops there.
  if seed_cfg_example "$box" "$f" "$tdir"; then ex=$CFG_EXAMPLE; fi
  rm -rf "$tdir" 2>/dev/null || :
  for key in STARTUP_ENABLED PORT; do
    case $key in
      STARTUP_ENABLED) val=$([[ -n ${CFG_BOXSV[$box]:-} ]] && printf yes || printf no) ;;
      PORT)            val=${CFG_PORT[$box]} ;;
    esac
    name=$(cfg_name "$box" "$key")
    # The example is what a box with NO file would have ended up with, so it
    # takes every value the real file takes. Its own outcome is not `rc`.
    if [[ -n $ex ]]; then cfg_set "$name" "$val" "$ex" || :; fi
    if ! cfg_set "$name" "$val" "$f"; then rc=1; continue; fi
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
  # Same shape as emit_ini: the write IS the function, so it is skipped whole
  # rather than wrapped command by command — the mkdir below exists only to make
  # room for the redirect under it.
  dry::skip "write $f" && return 0
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
  # ⚠️ THE GUARD IS A BLOCK AND NOT A `dry::rt` WRAPPER, because the real call
  # carries `>>"$log" 2>&1` — and a redirect hung on the wrapper would send the
  # WOULD DO line into the step log, where the one reader it is written for never
  # looks. A prediction nobody sees is not a prediction.
  if dry::on; then
    dry::would "enable lingering for ${USER:-$(id -un)}, so boxes can start at boot"
    # ⚠️ AND `LINGER` IS DELIBERATELY NOT SET. It is read later as a FACT about
    # the host, so a dry run that left the program believing lingering was on
    # would go on to report a box as able to start at boot when it cannot.
    # ⭐ MODEL AN ACTION, NEVER A WORLD: the two look alike in a diff and they
    # are not the same claim.
    return 0
  fi
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

