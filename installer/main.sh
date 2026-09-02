# ── Main flow ────────────────────────────────────────────────────────────────
main() {
  init_input
  logo_header
  banner "Droste Installer for Halo Architectures"
  preflight
  quit_notice

  section "Box Selection & Setup" intro
  sub "Box configuration, settings, logs, & other resources" intro
  # A typo here fans out into every emitted file — ask_path_as confirms before
  # creating (and re-asks if the user declines or the create fails). The factory
  # spelling is a literal ~ (see seed_globals): every path derived from the
  # answer inherits whatever spelling the answer has.
  # shellcheck disable=SC2088  # a LITERAL ~, resolved by fs_path at use
  ask_path_as "Identify a path for droste resource storage" "~/droste"
  EMIT_DIR=$ANS_PATH
  DEFAULT_ROOT=$EMIT_DIR
  # The resource path is what makes the old definition files findable, so this
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

  dashboard
  return 0
}

main
