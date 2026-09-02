# ── Execution (the ladder rungs) ─────────────────────────────────────────────
# Was this box (re)configured this run, or merely KEPT? The ladder acts on both
# — its create rung always replaces the container — but a KEPT box's SETTINGS
# are never touched, and <box>.cfg is a settings file.
is_configured() {  # box → 0 when it is in CONFIGURE
  local b
  for b in ${CONFIGURE[@]+"${CONFIGURE[@]}"}; do
    [[ $b == "$1" ]] && return 0
  done
  return 1
}

create_box() {  # box
  local box=$1 name log rc=0 src=0 marker="" serve=0 record=0
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
    # Two independent reasons to start the container we just created:
    #
    #  1. THE SEEDING START. `podman start` is what replays the init line, and
    #     the init line is what SEEDS <box>.cfg from the baked template — so the
    #     box has to run ONCE before the installer has a file to record its port
    #     and box-start answers in. That start does not serve: the file it is
    #     about to create is the file the serve intent is read from, so on a
    #     brand-new box the intent reads as absent and nothing is launched.
    #     ONLY for a (re)configured box. KEEP means "change nothing about
    #     settings", and its <box>.cfg is a settings file.
    #  2. The [A] rung's own reason: a box whose server is meant to come up when
    #     the box does. Unchanged.
    #
    # Whatever the reason, the container ends the run in the state the rung and
    # the answer asked for — running only when (2) holds.
    serve=0; record=0
    [[ $RUNG == a && -n "${CFG_BOXSV[$box]:-}" ]] && serve=1
    is_configured "$box" && record=1
    if [[ -n $RUNTIME ]] && [[ $serve -eq 1 || $record -eq 1 ]]; then
      src=0
      run_step "starting" "$log" "$RUNTIME" start "$name" || src=$?
      if [[ $src -eq 0 ]]; then
        SESSION_STATE[$box]=ACTIVE
        if [[ $record -eq 1 ]]; then
          # The answers, merged one line at a time into the file the box just
          # seeded. The marker is how the child reports that a value on disk
          # actually changed — a restart is owed only then, and cfg_set writes
          # nothing at all when the value is already what we would write.
          marker=$(mktemp "${TMPDIR:-/tmp}/droste-cfg.XXXXXX" 2>/dev/null) || marker=""
          run_step "configuring" "$log" write_box_cfg "$box" "$marker" || rc=1
          # It is meant to serve, and it did not serve on the seeding start
          # because the setting was not there to read yet. An EMPTY marker path
          # means mktemp failed and we do not know — restart anyway, which costs
          # a restart and is the safe direction.
          if [[ $serve -eq 1 ]] && { [[ -z $marker ]] || [[ -s $marker ]]; }; then
            src=0
            run_step "restarting" "$log" "$RUNTIME" restart "$name" || src=$?
            [[ $src -eq 0 ]] || rc=1
          fi
          [[ -n $marker ]] && rm -f "$marker"
        fi
        if [[ $serve -eq 0 ]]; then
          # The start was ours, not the user's: the [c] rung stops at "created",
          # and a box whose server is not meant to come up with it would
          # otherwise be left running as an idle container.
          run_step "stopping" "$log" "$RUNTIME" stop "$name" || rc=1
          SESSION_STATE[$box]=STOPPED
        fi
      else
        rc=1
      fi
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
  # rewritten (never-clobber).
  # ⚠️ THE PORT AND BOX-START ANSWERS ARE NOT WRITTEN HERE. They live in the
  # box's own <box>.cfg, which does not exist until the box has started once and
  # seeded it — so recording them belongs to create_box, after the start, and a
  # rung that never creates a box has nowhere to put them yet. The ini's
  # `# droste-setup: port=… box-start=…` record line carries them meanwhile, and
  # is what the next run reads back.
  if [[ ${#CONFIGURE[@]} -gt 0 ]]; then
    exec_hdr "Writing Configuration Files"
    for box in "${CONFIGURE[@]}"; do
      emit_ini "$box"
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

