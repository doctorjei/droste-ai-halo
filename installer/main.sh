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
  # without asking.
  ask_config_root
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
      # 🗄️ A global_mitigation() call stood here, walking every path General Setup
      # had collected to find the one to raise the filesystem question on. Each of
      # those paths settles its own filesystem at the moment it is answered now
      # (ask_path_settled), so there is nothing left for a later pass to find.
      general_setup
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

  # ⭐ LAST, AND IT NO LONGER HAS TO BE. The config path was re-askable by Data
  # Mapping until 0.7.0, so an offer made beside the original prompt could persist
  # a path this run then stopped using — and a stale export in the user's own
  # startup file is worse than no export at all. That path is gone: the answer is
  # final the moment it is given. What keeps the offer HERE is the second reason —
  # it writes to a file we do not own, and it belongs with the run's other
  # mutations rather than in the middle of the interview.
  # ⚠️ OUTSIDE the selection branch on purpose: a run that selects no box still
  # answered the config question, and the answer is just as unfindable next time.
  offer_config_export
  dashboard
  return 0
}

main
