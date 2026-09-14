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
  local box=$1 name log rc=0 src=0 serve=0 record=0
  name=$(box_ctr "$box")
  # 🚨 THE DRY BRANCH IS HERE AND NOT INSIDE THE `run_step` CALLS BELOW, and the
  # reason is not tidiness. `run_step` sends its child's stdout to the step log —
  # which a dry run resolves to /dev/null — so a wrapper placed inside one would
  # print its prediction into a black hole and the run would report nothing at
  # all. ⭐ A PREDICTION THE USER CANNOT SEE IS WORSE THAN NO PREDICTION: the run
  # still looks like it worked.
  if dry::on; then
    dry::would "remove the existing $name container, if there is one"
    dry::would "create $name from $(ini_file "$box")"
    if is_configured "$box"; then dry::would "write $name's config files"; fi
    if [[ $RUNG == a && -n "${CFG_BOXSV[$box]:-}" ]]; then
      dry::would "start $name"
    fi
    return 0
  fi
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
    # 🚨 ONE REASON TO START, NOT TWO (s77). There used to be a SEEDING START
    # here: `podman start` replays the init line, the init line seeded <box>.cfg
    # from the baked template, and the box therefore had to run ONCE before the
    # installer had a file to record the port and box-start answers in — which
    # also meant the service read a file that did not yet hold them, so a RESTART
    # was owed whenever a value had actually changed. A start, a merge, a restart
    # and (for a box not meant to serve) a stop, to produce one config file.
    #
    # The installer writes that file itself now (write_box_cfg → cfg_write_seeds,
    # out of the container we just created and have NOT started), so the only
    # surviving reason to start is the [A] rung's own: a box whose server is meant
    # to come up when the box does.
    #
    # ⚠️ TWO OBSERVABLE CONSEQUENCES, both deliberate. A (re)configured box that is
    # not meant to serve is no longer started at all, so (1) its `if_empty` trees
    # (comfyui input/user, finetuning workspace) are seeded at the USER's first
    # start instead of during the install, and (2) the install no longer proves
    # such a box can start. The first is a deferral; the second is a real loss,
    # accepted because the start it bought also cost every user a start+stop cycle
    # and a restart.
    serve=0; record=0
    [[ $RUNG == a && -n "${CFG_BOXSV[$box]:-}" ]] && serve=1
    is_configured "$box" && record=1
    # The config files FIRST, and before any start: that ordering is what makes
    # the rest of this block simple, and it is the whole single-writer change.
    if [[ -n $RUNTIME && $record -eq 1 ]]; then
      run_step "configuring" "$log" write_box_cfg "$box" || rc=1
    fi
    # ...then the start, which now finds a finished file and needs no restart.
    if [[ -n $RUNTIME && $serve -eq 1 ]]; then
      src=0
      run_step "starting" "$log" "$RUNTIME" start "$name" || src=$?
      if [[ $src -eq 0 ]]; then SESSION_STATE[$box]=ACTIVE; else rc=1; fi
    fi
  fi
  if [[ $rc -eq 0 ]]; then status_ok "$name..."; else status_err "$name..." "$log"; fi
  return 0
}

# ── The consented cache clear, carried out ───────────────────────────────────
# WHY IT IS HERE AND NOT WHERE IT IS ASKED (s80, closing s79's G4). The clear
# needs the box STOPPED — its overlay work dirs and the server's state dir are
# under the root being emptied — and the interview is not a moment at which a box
# may be bounced: the paths are still being settled and nothing has been written.
# So the question stays in the interview, where the path it applies to is on
# screen, and the action happens here, where stopping a container is already what
# this section does.
# 🚨 THE DEFECT THIS CLOSES: Jei answered Y, the box was running, the clear
# declined, and the run finished green. A knob that swallows a word and does
# nothing is worse than one that rejects it.
#
# ⭐ AND THE SWEEP RIDES THIS WINDOW, deliberately. sweep_overlay_debris runs in
# the interview too, where it can only act on a box that is already stopped; a
# box we have just stopped is its second and better chance, and it is idempotent
# — it re-globs and finds nothing when the first pass already cleaned. Its own
# running-box note is what makes the first pass honest; this is what makes the
# note rare.
#
# ⚠️ THE RESTART IS CONDITIONAL, AND NOT OUT OF CAUTION. At rungs [c] and [a] the
# create rung removes and rebuilds this container within seconds, so starting it
# here would start a box in order to destroy it — and for vllm that start is ~116
# seconds of weight loading thrown away. A box already STOPPED stays stopped
# (ruled): we restore the state we found, we do not impose one.
clear_box_caches() {  # box log → 0 the consent was honored, 1 it was not
  local box=$1 log=$2 name state stopped=0 rc=0
  name=$(box_ctr "$box")
  state=$(box_state "$box")
  # 🚨 STOPPING AND STARTING A BOX IS A CHANGE, AND JEI RULED IT OUT OF A DRY RUN
  # EXPLICITLY (s79): "we really shouldn't stop and start anything in a dry run;
  # we should see if the empty directories exist, that the permissions are
  # available, etc — i.e. 'could we do this'." So this says what it would do, in
  # the order it would do it, and touches neither the container nor the disk.
  # ⚠️ Same reason as create_box for guarding HERE: the run_step calls below
  # write to a log a dry run points at /dev/null.
  if dry::on; then
    if [[ $state == ACTIVE ]]; then dry::would "stop $name"; fi
    dry::would "clear the contents of ${PATHS["$box:pcache"]:-its cache dir}"
    dry::would "remove any orphaned overlay directories under ${BOX_NAME[$box]}'s uppers"
    if [[ $state == ACTIVE && $RUNG != c && $RUNG != a ]]; then
      dry::would "start $name again"
    fi
    return 0
  fi
  if [[ $state == ACTIVE ]]; then
    if [[ -z $RUNTIME ]]; then
      printf 'no container runtime, so %s could not be stopped\n' "$name" >>"$log"
      return 1
    fi
    run_step "stopping" "$log" "$RUNTIME" stop "$name" || {
      printf 'could not stop %s, so its caches were left alone\n' "$name" >>"$log"
      return 1; }
    stopped=1
    SESSION_STATE[$box]=STOPPED
  fi
  run_step "clearing" "$log" clear_pcache "$box" || rc=1
  # NEVER gates the restart: the sweep is unconsented housekeeping, and a box the
  # user is owed back must come back whether or not it found anything to remove.
  run_step "sweeping" "$log" sweep_overlay_debris "$box" || :
  if [[ $stopped -eq 1 && $RUNG != c && $RUNG != a ]]; then
    run_step "starting" "$log" "$RUNTIME" start "$name" || {
      printf 'caches cleared, but %s could not be started again\n' "$name" >>"$log"
      return 1; }
    SESSION_STATE[$box]=ACTIVE
  fi
  return $rc
}

# The Executing group that owns it. It runs at EVERY rung, including [w]: the
# consent is an answer about this box's storage, not a step on the build ladder,
# and gating it on a rung is how it would go missing again.
clear_caches() {  # box...
  local box log rc
  local -a boxes=("$@")
  [[ ${#boxes[@]} -gt 0 ]] || return 0
  exec_hdr "Clearing Caches"
  for box in "${boxes[@]}"; do
    log=$(step_log clear "$box")
    : > "$log"
    status_start "$(box_ctr "$box")..."
    rc=0
    clear_box_caches "$box" "$log" || rc=$?
    if [[ $rc -eq 0 ]]; then
      status_ok "$(box_ctr "$box")..."
    else
      status_err "$(box_ctr "$box")..." "$log"
      # The failure is on screen already, but it scrolls. This is what survives
      # to the end of the run, because an unhonored yes is the one outcome the
      # user has to act on themselves.
      CLEAR_UNDONE[$box]=1
    fi
  done
  return 0
}

# One box's host-boot enablement (or its removal). Returns non-zero when the
# unit could not be put in the state the user asked for.
host_unit_step() {  # box log → 0 ok
  local box=$1 log=$2 unit rc=0
  unit=$(unit_name "$box")
  # Both arms write: one creates a unit and enables it, the other disables one
  # and deletes the file. Said whole rather than wrapped call by call, because
  # `systemctl enable` without the file it names is not half of the action, it
  # is a different one — and because these too are redirected into the log.
  if dry::on; then
    if [[ -n "${CFG_HSTSV[$box]:-}" ]]; then
      dry::would "write $(unit_file "$box") and enable $unit"
    elif [[ -f $(unit_file "$box") ]]; then
      dry::would "disable $unit and remove $(unit_file "$box")"
    fi
    return 0
  fi
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
  local box b ladder=() units=() clears=() all_names=() svc_log rc=0
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
  # CONFIGURE only, and only where there is still something to remove. A KEPT box
  # was never asked (its paths were not settled this run), and a box whose cache
  # root has nothing clearable in it would be a status line about no work.
  for box in "${CONFIGURE[@]}"; do
    clear_pending "$box" && clears+=("$box")
  done
  # ONE column for the whole section: every status line the run will print is
  # measured before the first of them is drawn.
  if [[ ${#ladder[@]} -gt 0 ]]; then
    for box in "${ladder[@]}"; do
      [[ $RUNG != w ]] && all_names+=("$(img_disp "$box")...")
      [[ $RUNG == c || $RUNG == a ]] && all_names+=("$(box_ctr "$box")...")
    done
    # The clear group draws a status line per box at EVERY rung, so its names
    # have to be measured here too — at [w] and [p] nothing else contributes a
    # container name, and a name wider than the column would push its own tag
    # off the end of the line.
    for box in ${clears[@]+"${clears[@]}"}; do
      all_names+=("$(box_ctr "$box")...")
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
  # BEFORE the pull and the create, because it is maintenance on the state those
  # two are about to build on: a container created against a cache root the user
  # asked to have emptied should find it emptied. It is also the only group that
  # may leave a box running when it found one running, which the create rung
  # would then have to undo.
  clear_caches ${clears[@]+"${clears[@]}"}
  if [[ $RUNG != w && ${#ladder[@]} -gt 0 ]]; then
    exec_hdr "Pulling Images"
    svc_log=$(step_log pull service)
    : > "$svc_log"
    # The API service is the pull mechanism, not an optimization: if it will not
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
        [[ $ANSI -eq 0 ]] \
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

