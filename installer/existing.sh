# ── Existing-setup detection + parsing (re-run safety) ───────────────────────
# ONE container per box, named exactly like the image stem. The FILE name drops
# the redundant "droste-" prefix (the emit dir is a user-facing directory), and
# the systemd user unit that starts the box at host boot drops the "-halo".
box_ctr()   { printf 'droste-%s-halo' "$1"; }
ini_file()  { printf '%s/%s-halo.ini' "$EMIT_DIR" "$1"; }
unit_name() { printf 'droste-%s.service' "$1"; }
unit_file() { printf '%s/.config/systemd/user/%s' "$HOME" "$(unit_name "$1")"; }
# The box's settings file on the HOST side of its data bind: /opt/data/<box>.cfg
# inside the box is <data dir>/<box>.cfg here. It is the one file that carries
# the serve settings the box reads at EVERY start (P1's droste-serve.sh) AND the
# several hundred application settings the box seeded for the user — which is
# why the installer only ever MERGES single lines into it (cfg_set), and never
# creates it.
box_cfg_file() {  # box → path ("" when the data dir is not known yet)
  local d=${PATHS["$1:data"]:-${EXD_PATH["$1:data"]:-}}
  [[ -n $d ]] && printf '%s/%s' "$d" "${BOX_CFG[$1]}"
}

# The name of one of the five serve settings for a box: DROSTE_<APP>_<KEY>.
cfg_name() {  # box key → DROSTE_<APP>_<KEY>
  printf 'DROSTE_%s_%s' "${BOX_APP[$1]}" "$2"
}

dest_to_label() {  # box dest → label ("" if unknown)
  local box=$1 dest=$2 pair
  # /opt/program-cache is the PER-BOX cache root (s38 taxonomy) and /opt/caches
  # the SHARED compute one — one letter apart on the container side, and two
  # different host roots. An ini written before s38 has no /opt/program-cache
  # bind at all; that is not an error, it just means nothing seeds `pcache`.
  case "$dest" in
    /opt/data) printf 'data'; return 0 ;;
    /opt/program-cache) printf 'pcache'; return 0 ;;
    /opt/models) printf 'models'; return 0 ;;
    /opt/caches) printf 'caches'; return 0 ;;
    */.cache/huggingface) printf 'hf'; return 0 ;;
  esac
  for pair in ${BOX_EXTRA_BINDS[$box]}; do
    if [[ ${pair#*:} == "$dest" ]]; then printf '%s' "${pair%%:*}"; return 0; fi
  done
  printf ''
}

# Read back what the last run wrote. NO MIGRATION (Jei s38 Q4): an ini from
# before the storage taxonomy records the OLD shapes — the data dir at
# `<rc>/<box>/data`, a workspace beside it, the shared caches at `<rc>/caches`,
# and no /opt/program-cache bind at all. Every one of those is read as what it
# says, and the parts the old layout has nothing to say about (the box's
# program-cache dir) simply stay unseeded, so they offer their factory default.
# A path that does not fit the new <base>/<box> shape makes its family answer
# "no common base" (family_base), which routes it to the per-box question — the
# user is asked where it goes now rather than being moved without being told.
#
# TWO LINES CARRY THE PATHS, AND THEY ARE NOT PEERS (s39). `volume=` is what
# distrobox and podman act on, so its sources are always resolved absolutes —
# podman 5.4.2 binds a source only when it starts with / or ./, and anything
# else silently becomes a NAMED VOLUME with that string for a name, so a ~ or a
# $HOME on that line is not a bind at all. The SPELLING the user wrote is
# therefore recorded beside it, in the `# droste-setup: spelled="..."` comment,
# in the same "<src>:<dest>" shape so the two lines read against each other by
# dest.
#
# PRECEDENCE, RULED (Jei s39): volume= WINS. It is authoritative for the value,
# always; the comment only ever contributes a spelling, and only when it names
# the same directory (same_dir, so a symlinked or aliased home still matches).
# When they disagree, the comment is describing some other directory — a
# hand-edited volume= line, most likely — and there is nothing left for it to
# spell, so the volume= string is taken verbatim.
parse_existing_ini() {  # box
  local box=$1 f line vols entry src dest label
  local -A vsrc=() spelled=()
  f=$(fs_path "$(ini_file "$box")")
  [[ -f $f ]] || return 0
  while IFS= read -r line; do
    if [[ $line =~ ^volume=\"(.*)\"$ ]]; then
      vols=${BASH_REMATCH[1]}
      for entry in $vols; do
        src=${entry%%:*}
        dest=${entry#*:}; dest=${dest%%:*}
        label=$(dest_to_label "$box" "$dest")
        # First entry per label wins, exactly as before. `if`, not `[[ … ]] &&`:
        # a false test as the last command of a loop body is the status of the
        # whole loop, and this script runs under `set -e`.
        if [[ -n $label && -z "${vsrc[$label]:-}" ]]; then vsrc[$label]=$src; fi
      done
    elif [[ $line =~ ^#[[:space:]]*droste-setup:[[:space:]]*spelled=\"(.*)\"$ ]]; then
      # The spelling record. Collected, not applied: the two lines may arrive in
      # either order in a file someone has edited, so they are reconciled once
      # the whole ini has been read.
      vols=${BASH_REMATCH[1]}
      for entry in $vols; do
        src=${entry%%:*}
        dest=${entry#*:}; dest=${dest%%:*}
        label=$(dest_to_label "$box" "$dest")
        if [[ -n $label && -z "${spelled[$label]:-}" ]]; then spelled[$label]=$src; fi
      done
    elif [[ $line =~ DROSTE_OVERLAY_MODE=([a-z]+) ]]; then
      # additional_flags carries --env DROSTE_OVERLAY_MODE=<mode>.
      EXD_MODE[$box]=${BASH_REMATCH[1]}
    elif [[ $line =~ ^#[[:space:]]*droste-setup:[[:space:]]*port=([0-9]+)[[:space:]]+box-start=([a-z]+)[[:space:]]+host-boot=([a-z]+) ]]; then
      # The record line emit_ini writes: what THIS installer last answered. It
      # is the fallback for the two live sources below (<box>.cfg + systemd),
      # which are what the user may have changed by hand since.
      EXD_PORT[$box]=${BASH_REMATCH[1]}
      [[ ${BASH_REMATCH[2]} == yes ]] && EXD_BOXSV[$box]=1
      [[ ${BASH_REMATCH[3]} == yes ]] && EXD_HSTSV[$box]=1
    fi
  done < "$f"
  # Reconcile: the value comes from volume=, the spelling from the comment when
  # it still names that same directory. abs_path gives whichever won the same
  # lexical tidy a typed answer gets — and leaves a ~ alone.
  for label in "${!vsrc[@]}"; do
    src=${vsrc[$label]}
    if [[ -n "${spelled[$label]:-}" ]] && same_dir "${spelled[$label]}" "$src"; then
      src=${spelled[$label]}
    fi
    EXD_PATH["$box:$label"]=$(abs_path "$src")
  done
  return 0
}

# The LIVE serve state of a box: its <box>.cfg (which the user may have edited
# with an editor — that is the whole point of the file) wins over the ini's
# record of what droste-setup.sh last wrote. THIS IS THE READ-BACK THAT MAKES A
# MODIFY RUN SAFE: a hand-edited port or startup answer becomes the DEFAULT the
# prompt offers, so the run shows the user their own setting instead of silently
# proposing to overwrite it.
#
# 🚨 PARSE, NEVER SOURCE — via cfg_get, the installer's half of the shared
# contract. The retired server.env was droste's outright and could be read with an
# ad-hoc regex; <box>.cfg is the user's several-hundred-line config file and the
# only reading of it that may ever be trusted is the one the box itself uses.
#
# ⚠️ ABSENT IS NOT "no". cfg_get answers "" for absent AND for blank (rule 5:
# blank means "no opinion"), and in both cases the box falls back to the droste
# default — so the installer must NOT read that as an answer and must leave the
# ini's record standing as the fallback. Only a value the user actually wrote
# overrides it. The old code assigned EXD_BOXSV="" on anything non-truthy,
# which turned "the file says nothing" into "the user said no".
parse_box_cfg() {  # box
  local box=$1 f v
  f=$(box_cfg_file "$box") || return 0
  [[ -n $f ]] || return 0
  f=$(fs_path "$f")      # a data dir the user spelled with ~ is still a dir
  [[ -f $f && -r $f ]] || return 0
  # STARTUP_ENABLED's vocabulary is {yes, no} — that is what the file's own menu
  # shows and what cfg_set writes. Read TOLERANTLY anyway (the box's droste::bool
  # accepts on/1/true too, and a file is the user's to type into); write one form.
  v=$(cfg_get "$(cfg_name "$box" STARTUP_ENABLED)" "$f")
  if [[ -n $v ]]; then
    case "${v,,}" in
      1|true|yes|on) EXD_BOXSV[$box]=1 ;;
      *)             EXD_BOXSV[$box]="" ;;
    esac
  fi
  v=$(cfg_get "$(cfg_name "$box" PORT)" "$f")
  [[ $v =~ ^[0-9]+$ ]] && EXD_PORT[$box]=$v
  return 0
}

# Host-boot state comes from systemd itself, not from a file we wrote: the user
# may have disabled the unit by hand. `is-enabled` exits non-zero for disabled
# AND for "no such unit", which are the same answer to us.
parse_host_unit() {  # box
  local box=$1
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl --user is-enabled "$(unit_name "$box")" >/dev/null 2>&1; then
    EXD_HSTSV[$box]=1
  elif [[ ! -f $(unit_file "$box") ]]; then
    EXD_HSTSV[$box]=""
  fi
  return 0
}

detect_existing() {
  local box state
  for box in "${BOXES[@]}"; do
    [[ -f $(fs_path "$(ini_file "$box")") ]] && EX_INI[$box]=1
    if [[ -n $RUNTIME ]]; then
      state=$("$RUNTIME" ps -a --filter "name=^$(box_ctr "$box")\$" \
              --format '{{.State}}' 2>/dev/null | head -n1) || state=""
      [[ -n $state ]] && EX_CTR[$box]=$state
    fi
    # ini FIRST: it is what says where the data dir (hence <box>.cfg) is.
    parse_existing_ini "$box"
    parse_box_cfg "$box"
    parse_host_unit "$box"
  done
  return 0
}

# The conditional block under the resource-path answer: which definition files
# the just-named resource path already holds. Printed BEFORE the box table
# because it is the reason a re-runner is about to pick a subset.
detected_block() {
  local box
  local -a ini=()
  for box in "${BOXES[@]}"; do
    [[ -n "${EX_INI[$box]:-}" ]] && ini+=("$box")
  done
  [[ ${#ini[@]} -eq 0 ]] && return 0
  say ""
  # ONE list now: one container per box means one settings file per box, so the
  # old two-lane listing (ini + yaml) has nothing left to distinguish.
  printf '  %s%s%s %s%s%s\n' "$C_ARROW" "$ARROW_M" "$RESET" \
    "$C_DETH" "Previous box setup configurations detected:" "$RESET"
  printf '  %sBox settings (ini):  %s\n' "$C_TEXT" "$(name_list "$C_DETN" "${ini[@]}")"
  say ""
  printf '  %s%s%s\n' "$C_SELP" \
    "Select the boxes you wish to edit, modify, or rebuild." "$RESET"
  return 0
}

