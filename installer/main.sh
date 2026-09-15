# ── Main flow ────────────────────────────────────────────────────────────────
main() {
  init_input
  logo_header
  banner "Droste Installer for Halo Architectures"
  preflight
  quit_notice

  section "Box Selection & Setup" intro
  sub "Droste configuration files" intro
  # A typo here fans out into every emitted file — ask_path_as confirms before
  # creating (and re-asks if the user declines or the create fails). The factory
  # spelling comes from factory_root (a literal ~ unless XDG or DROSTE_CONFIG
  # named a directory), and every file written here inherits the answer's
  # spelling.
  # ⭐ THIS ANSWER NO LONGER PLACES ANYTHING ELSE (0.7.0). The data and cache
  # roots are asked in General Setup and default from their own XDG variables,
  # so this is the config root and nothing more.
  # ⭐ AND THE QUESTION ITSELF LIVES IN ask_config_root, WHICH IS THE ONLY PLACE
  # IT IS AUTHORED — prompt, default and the DROSTE_CONFIG rule that can answer it
  # without asking. Data Mapping's re-ask calls the same function. `open` says
  # this is the call that opens the run, so a pinned root is announced and settled
  # here rather than refused.
  ask_config_root open
  # The config path is what makes the old definition files findable, so this
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

  # ⭐ LAST, BECAUSE THIS IS THE FIRST MOMENT THE CONFIG PATH IS FINAL. Data
  # Mapping can re-ask it (reask_slot rc), so an offer made beside the original
  # prompt could persist a path this run then stopped using — and a stale export
  # written into the user's own startup file is worse than no export at all.
  # ⚠️ OUTSIDE the selection branch on purpose: a run that selects no box still
  # answered the config question, and the answer is just as unfindable next time.
  offer_config_export
  dashboard
  return 0
}

main
