# ── Box selection ────────────────────────────────────────────────────────────
# The answer is parsed ROBUSTLY: anything that is not an ASCII letter or digit
# is a separator, so "1,2 3", "comfyui/llama" and "[1] [2]" all work. Tokens we
# cannot place are named back rather than silently dropped, and the prompt
# repeats.
select_boxes() {
  local box tok idx pick clean bad dw
  declare -A want=()
  if [[ ${#ARG_BOXES[@]} -gt 0 ]]; then
    for tok in "${ARG_BOXES[@]}"; do
      [[ -n "${BOX_HOST_PORT[$tok]:-}" ]] || die "unknown box: $tok"
      want[$tok]=1
    done
  else
    say ""
    # Columns land at 2 / 8 / 21 / 34 / 69. Each column carries its own colour
    # THROUGH its padding, so the row reads as four coloured fields, and the
    # [All] row wears the whole default-option scheme of an option list.
    # DESCRIPTION IS THE ELASTIC COLUMN: it is the only prose here, so a narrow
    # terminal takes its width out of that cell (clipped, not wrapped) and every
    # other column keeps its place. It never grows past its drawn 35.
    dw=$(( $(disp_width) - 39 ))
    [[ $dw -gt 35 ]] && dw=35
    [[ $dw -lt 8 ]] && dw=8
    printf '  %s %-5s%-13s%-13s%-*s%-5s%s\n' \
      "$C_SUB" "#" "Container" "Service" "$dw" "Description" "Port" "$RESET"
    idx=1
    for box in "${BOXES[@]}"; do
      printf '  %s[%s%d%s]%s   %s%-13s%s%-13s%s%-*s%s%s%s\n' \
        "$C_TBRK" "$C_TIDX" "$idx" "$C_TBRK" "$RESET" \
        "$C_CTR" "$box" "$C_SVCN" "${BOX_SERVICE[$box]}" \
        "$C_TEXT" "$dw" "$(clip "${BOX_DESC[$box]}" "$dw")" \
        "$C_PORT" "${BOX_HOST_PORT[$box]}" "$RESET"
      idx=$((idx+1))
    done
    printf '  %s[%s%s%s]%s%s%s\n' \
      "$C_BRK" "$C_OPTD" "All" "$C_BRK" "$C_OPTD" " All boxes" "$RESET"
    say ""
    while :; do
      ask_raw "Select boxes - names or numbers, space-separated $(dflt All): "
      [[ -z $ANS ]] && ANS=All
      want=()
      bad=""
      # Separators first, then one token per word.
      clean=${ANS//[!a-zA-Z0-9]/ }
      for tok in $clean; do
        case "${tok,,}" in
          all|6) for box in "${BOXES[@]}"; do want[$box]=1; done ;;
          [1-5]) pick=${BOXES[$((tok-1))]}; want[$pick]=1 ;;
          *) if [[ -n "${BOX_HOST_PORT[${tok,,}]:-}" ]]; then want[${tok,,}]=1
             else bad="$bad $tok"; fi ;;
        esac
      done
      if [[ -n $bad ]]; then
        subnote "Unrecognized:$bad $EMD use the names or numbers above."
        continue
      fi
      [[ ${#want[@]} -gt 0 ]] && break
    done
  fi
  SELECTED=()
  for box in "${BOXES[@]}"; do
    [[ -n "${want[$box]:-}" ]] && SELECTED+=("$box")
  done
  return 0
}

# ── Existing Settings (K/m/r — SETTINGS FILES ONLY) ──────────────────────────
# K/m/r decides what happens to a box's DEFINITION FILES and nothing else:
#   keep     — its interview and its file write are both skipped
#   modify   — full interview, defaults taken from the parsed existing values
#   recreate — full interview, "factory" defaults
# Containers are NOT its business: the build ladder's create rung always
# replaces whatever is there (see create_server / create_distrobox).
# CONFIGURE = boxes whose definitions are (re)generated (new/recreate/modify).
# KEEP      = boxes left untouched, but STILL offered the build ladder so a
#             prior "write only" run can later pull/create/start them.
action_of()   { case "$1" in k) printf 'keep' ;; m) printf 'modify' ;; r) printf 'recreate' ;; esac; }
action_verb() { case "$1" in keep) printf 'Keeping' ;; modify) printf 'Modifying' ;; *) printf 'Recreating' ;; esac; }
action_tail() { case "$1" in keep) printf ' as-is' ;; *) printf '' ;; esac; }

# The "[K/r/m]" cluster with the CURRENT default capitalised (opt_row and the
# prompt hint follow the same rule everywhere else in the installer).
kmr_cluster() {  # k|m|r
  case "$1" in
    m) printf 'k/r/M' ;;
    r) printf 'k/R/m' ;;
    *) printf 'K/r/m' ;;
  esac
}

box_options() {  # box-with-settings...
  local -a have=("$@")
  local box letters="Krm" choice all=1 act pl
  CONFIGURE=()
  KEEP=()
  for box in "${SELECTED[@]}"; do ACTION[$box]=""; done
  if [[ ${#have[@]} -gt 0 ]]; then
    say ""
    printf '  %s%s%s\n' "$C_HDR" "Box Options" "$RESET"
    opt_row K "eep settings as-is (make no modifications)" "" 0 "$(isdef K "$letters")"
    opt_row m "odify settings (set defaults to existing values)" "" 0 "$(isdef m "$letters")"
    opt_row r "ecreate settings (start from \"factory\" settings)" "" 0 "$(isdef r "$letters")"
    say ""
    ask_choice "Please indicate how to proceed [$(kmr_cluster k)]" "$letters"
    choice=$ANS_CH
    if [[ ${#have[@]} -gt 1 ]]; then
      ask_yn "Do the same for all boxes" Y
      all=$ANS_YN
    fi
    if [[ $all -eq 1 ]]; then
      act=$(action_of "$choice")
      for box in "${have[@]}"; do ACTION[$box]=$act; done
      say ""
      if [[ ${#have[@]} -eq 1 ]]; then
        printf '  %s%s %s%s-halo%s settings%s.%s\n' "$C_TEXT" "$(action_verb "$act")" \
          "$C_DETN" "${have[0]}" "$C_TEXT" "$(action_tail "$act")" "$RESET"
      else
        printf '  %s%s droste-halo settings%s: %s\n' "$C_TEXT" \
          "$(action_verb "$act")" "$(action_tail "$act")" \
          "$(name_list "$C_DETN" "${have[@]}")"
      fi
    else
      # A1 + Jei's round-2 correction: the answer just given IS the first box's
      # answer (it is not asked again); only the REMAINING selected boxes are
      # prompted, each defaulting to that first answer.
      pl="${choice^}${letters//[$choice${choice^}]/}"
      ACTION[${have[0]}]=$(action_of "$choice")
      for box in "${have[@]:1}"; do
        ask_choice "Please indicate how to proceed for $box [$(kmr_cluster "$choice")]" "$pl"
        ACTION[$box]=$(action_of "$ANS_CH")
      done
      say ""
      for box in "${have[@]}"; do
        act=${ACTION[$box]}
        printf '  %s%s %s%s%s settings%s.%s\n' "$C_TEXT" "$(action_verb "$act")" \
          "$C_DETN" "$box-halo" "$C_TEXT" "$(action_tail "$act")" "$RESET"
      done
    fi
  fi
  for box in "${SELECTED[@]}"; do
    [[ -n "${ACTION[$box]}" ]] || ACTION[$box]=new
    case "${ACTION[$box]}" in
      keep) KEEP+=("$box") ;;
      *)    CONFIGURE+=("$box") ;;
    esac
  done
  return 0
}

# The section itself (A6): it exists to ask K/m/r about SETTINGS, so it renders
# only when a selected box actually has settings to keep/modify/recreate —
# banner included. A virgin system never sees it, and neither does a system
# whose images are pulled but whose settings files are gone (Jei, live test:
# the images listing was cut entirely — nothing here reports on images).
existing_settings() {
  local box
  local -a haveset=()
  for box in "${SELECTED[@]}"; do
    [[ -n "${EX_INI[$box]:-}" ]] && haveset+=("$box")
  done
  # The SECTION is drawn only when a selected box has settings to ask about.
  # box_options runs EITHER WAY: besides the K/m/r question it is what sorts
  # every selected box into CONFIGURE/KEEP (a box with no settings is "new",
  # and nobody is asked anything about it).
  [[ ${#haveset[@]} -gt 0 ]] && section "Existing Settings"
  box_options ${haveset[@]+"${haveset[@]}"}
  return 0
}

# Populate a kept box's CFG_*/PATHS from its parsed existing files so the build
# ladder (pull/create/start) and the dashboard/notes work without re-asking.
hydrate_keep() {  # box
  local box=$1 pair label
  CFG_PORT[$box]=${EXD_PORT[$box]:-${BOX_HOST_PORT[$box]}}
  CFG_BOXSV[$box]=${EXD_BOXSV[$box]:-}
  CFG_HSTSV[$box]=${EXD_HSTSV[$box]:-}
  CFG_MODE[$box]=${EXD_MODE[$box]:-}
  CFG_FS[$box]=${CFG_FS[$box]:-?}
  [[ -n "${EXD_PATH["$box:data"]:-}" ]] && PATHS["$box:data"]=${EXD_PATH["$box:data"]}
  # The program-cache root gets the same treatment as the data one: it is not a
  # BOX_EXTRA_BIND (emit_ini writes its bind on its own), so the loop below
  # would never reach it, and a kept box that cannot name its cache dir cannot
  # be described in NOTES/the dashboard. An ini from before s38 records none,
  # and the box keeps the factory path.
  [[ -n "${EXD_PATH["$box:pcache"]:-}" ]] && PATHS["$box:pcache"]=${EXD_PATH["$box:pcache"]}
  for pair in ${BOX_EXTRA_BINDS[$box]}; do
    label=${pair%%:*}
    [[ -n "${EXD_PATH["$box:$label"]:-}" ]] && PATHS["$box:$label"]=${EXD_PATH["$box:$label"]}
  done
  # Shared dirs, so a kept box can still describe itself in NOTES/the dashboard.
  [[ -z $HF_CACHE      && -n "${EXD_PATH["$box:hf"]:-}" ]]     && HF_CACHE=${EXD_PATH["$box:hf"]}
  [[ -z $COMPUTE_CACHE && -n "${EXD_PATH["$box:caches"]:-}" ]] && COMPUTE_CACHE=${EXD_PATH["$box:caches"]}
  [[ -z $MODELS_DIR    && -n "${EXD_PATH["$box:models"]:-}" ]] && MODELS_DIR=${EXD_PATH["$box:models"]}
  return 0
}

# ── Global default seeding (K/m/r is known; the files are parsed) ────────────
# EVERY question except the resource-path one (which has to come first — until
# it is answered no file can be found) takes its default from what the old
# definition files say, paths AND toggles, install-wide questions included.
#
# The SOURCE is strictly narrow (Jei s34): only boxes that are BOTH selected
# this run AND marked MODIFY. Recreate means a clean slate, so a recreate box
# contributes nothing and sees the factory value; a kept box is frozen and
# skipped, so it contributes nothing either. A pure-recreate selection gets
# factory defaults everywhere. That is why this runs AFTER Box Options.
SEED_PORTS=Y                 # "use default ports for all services"
SEED_SERVE=n SEED_HOST=n     # the two three-way start questions (y|n|c)
SEED_PCACHE_Q=Y SEED_PCACHE_BASE=""  # per-box program caches at a common base
SEED_DATA_Q=Y SEED_DATA_BASE=""      # persistent data at a common base
SEED_HF="" SEED_COMPUTE="" SEED_MODELS=""   # SEED_MODELS "" = None (no bind)
# A family that fell back to per-box questions, and the recorded path that
# settled it: "<box>: <path>". Empty = no fallback (or nothing recorded to
# fall back FROM). Printed above the storage questions, because a default that
# came out of a fallback should say so — a silent flip to N with a factory
# example reads exactly like a broken read-back, which is how it was reported.
SEED_NOBASE_DATA="" SEED_NOBASE_PCACHE=""
SEED_SRC=()                  # the boxes whose files may seed anything at all

# Selected AND modify — the only boxes a default may be read from.
seed_sources() {
  local box
  SEED_SRC=()
  for box in "${SELECTED[@]}"; do
    [[ ${ACTION[$box]:-} == modify ]] && SEED_SRC+=("$box")
  done
  return 0
}

# What base does ONE recorded path imply, given the shape its family uses?
# "-" when the path is not in that shape at all.
#
# The program cache root puts the box directly under the base (<base>/<box> IS
# the cache dir); every data-family bind is a leaf beside its siblings
# (<base>/<box>/<program|input|output|workspace>).
#
# READ TOLERANTLY, WRITE STRICTLY: a data path recorded as <base>/<box> is the
# pre-s41 layout, from before the data dir became a `program` sibling of the
# others. It still names a base, and saying otherwise would report "these do not
# share a common base" about a set of paths that plainly do. The path is not
# rewritten for it — an old box keeps what its ini says until its owner moves
# it (Jei: "I can manually fix my boxes") — but it is understood.
shape_base() {  # box leaf path → base | "-"
  local box=$1 leaf=$2 p=$3 d
  if [[ $leaf == pcache ]]; then
    if [[ $p == */"$box" ]]; then printf '%s' "${p%/"$box"}"; else printf '-'; fi
    return 0
  fi
  d=$(leaf_dir "$leaf")
  if [[ $p == */"$box"/"$d" ]]; then printf '%s' "${p%/"$box"/"$d"}"; return 0; fi
  if [[ $leaf == data && $p == */"$box" ]]; then printf '%s' "${p%/"$box"}"; return 0; fi
  printf '-'
  return 0
}

# The common base of a family of recorded paths, or "" when they do not share
# the family's shape (or disagree about the base).
family_base() {   # leaf...
  local leaf box p base first="" seen=0
  for box in ${SEED_SRC[@]+"${SEED_SRC[@]}"}; do
    for leaf in "$@"; do
      p=${EXD_PATH["$box:$leaf"]:-}
      [[ -n $p ]] || continue
      base=$(shape_base "$box" "$leaf" "$p")
      if [[ $seen -eq 0 ]]; then first=$base seen=1
      elif [[ $base != "$first" ]]; then printf '-'; return 0
      fi
    done
  done
  [[ $seen -eq 0 ]] && return 0     # nothing recorded: caller keeps its factory
  printf '%s' "$first"
  return 0
}

# The label as the note says it out loud. "pcache" is this script's word for
# them, not the reader's.
leaf_word() {  # label → display word
  case "$1" in
    pcache) printf 'program cache' ;;
    data)   printf 'program data' ;;
    *)      printf '%s' "$1" ;;
  esac
}

# The DIRECTORY a bind takes under the box's own dir. The data bind is spelled
# `program` there — short for "program data", which is what its prompt has
# always called it ("Path for ComfyUI program data").
#
# ⭐ RULED (Jei, s41): THE NESTING WAS AN OVERSIGHT. The box's data dir used to
# BE <base>/<box>, with input/output living INSIDE it; the three are siblings
# now, under a box directory that is not itself a bind:
#
#     <data base>/<box>/program   → /opt/data
#     <data base>/<box>/input     → /opt/ComfyUI/input
#     <data base>/<box>/output    → /opt/ComfyUI/output
#
# Host side only — no container path changes. NO MIGRATION: existing boxes keep
# the paths their ini records (Jei: "I can manually fix my boxes"), and only new
# placements take the new shape.
leaf_dir() {  # label → directory name
  case "$1" in
    data) printf 'program' ;;
    *)    printf '%s' "$1" ;;
  esac
}

# What EXPLAINS a "-" from family_base, in terms the reader can act on. TWO
# different things produce that "-", and they do not have the same answer:
#
#   a MALFORMED path — a shape this layout does not use. One entry names it,
#   and it explains itself.
#
#   a DISAGREEMENT — every path well-shaped, the bases simply differ. This was
#   Jei's own case, and the old code fell through to "print the first recorded
#   entry", which reads as a COUNTER-EXAMPLE to the claim it is supporting: one
#   well-formed path, offered as evidence that the paths are not well-formed.
#   Both sides are named instead (Jei, s40: "comfyui data: … vs comfyui input:
#   …") — the disagreement is a relationship, so it takes two paths to show it.
#
# One line per entry, "<box> <leaf>: <path>"; nobase_note renders them. A
# separate walk from family_base on purpose — that one runs in a command
# substitution, so it cannot hand anything back out of band.
family_example() {   # leaf... → 0, 1 or 2 lines ("" when nothing is recorded)
  local leaf box p base first="" firstbase=""
  for box in ${SEED_SRC[@]+"${SEED_SRC[@]}"}; do
    for leaf in "$@"; do
      p=${EXD_PATH["$box:$leaf"]:-}
      [[ -n $p ]] || continue
      base=$(shape_base "$box" "$leaf" "$p")
      # It is quoting the user's own file back at them ("why am I being asked
      # per box?"), and $p IS what their file says.
      if [[ $base == "-" ]]; then
        printf '%s %s: %s' "$box" "$(leaf_word "$leaf")" "$p"
        return 0
      fi
      if [[ -z $first ]]; then
        first="$box $(leaf_word "$leaf"): $p" firstbase=$base
        continue
      fi
      if [[ $base != "$firstbase" ]]; then
        printf '%s\n%s %s: %s' "$first" "$box" "$(leaf_word "$leaf")" "$p"
        return 0
      fi
    done
  done
  printf '%s' "$first"
  return 0
}

# The base MOST of the recorded paths agree on — what to offer when a family has
# no single base but the files still say plainly where most of them live. Jei's
# standard is that a prompt default MATCHES THE FILE, and any recorded base
# matches a file; the factory path this replaces matched nothing on the disk.
# ⚠️ THE TIE-BREAK IS MINE, NOT RULED: on a dead heat (two boxes, two bases)
# the FIRST recorded base wins, because box order is stable and an arbitrary
# answer that is stable beats one that moves between runs. Either way the
# outliers meet the move question, which is where they get settled.
family_dominant() {  # leaf... → base ("" when nothing is well-shaped)
  local leaf box p base best="" bestn=0 n
  local -a order=()
  local -A count=()
  for box in ${SEED_SRC[@]+"${SEED_SRC[@]}"}; do
    for leaf in "$@"; do
      p=${EXD_PATH["$box:$leaf"]:-}
      [[ -n $p ]] || continue
      base=$(shape_base "$box" "$leaf" "$p")
      [[ $base == "-" ]] && continue
      if [[ -z ${count["$base"]:-} ]]; then order+=("$base"); fi
      count["$base"]=$(( ${count["$base"]:-0} + 1 ))
    done
  done
  for base in ${order[@]+"${order[@]}"}; do
    n=${count["$base"]}
    if [[ $n -gt $bestn ]]; then best=$base bestn=$n; fi
  done
  printf '%s' "$best"
  return 0
}

seed_globals() {
  local box base yes=0 no=0
  seed_sources
  # Factory values first: with no seed source (all-recreate, all-new, all-keep)
  # these are exactly what every question below offers.
  SEED_PORTS=Y
  SEED_SERVE=n SEED_HOST=n
  SEED_PCACHE_Q=Y SEED_DATA_Q=Y
  # A FACTORY DEFAULT IS SPELLED THE WAY THE INSTALLER WOULD WRITE IT: ~, not
  # an expansion of it. Nobody authored this path, so there is no other
  # spelling owed to anyone — and the moment it is offered and accepted, ~ is
  # what the user chose, which is what every later line shows. (The other
  # factory paths hang off the resource path and inherit ITS spelling, so a
  # typed /srv/droste never grows a ~ anywhere below it.)
  # shellcheck disable=SC2088  # a LITERAL ~, resolved by fs_path at use
  SEED_HF="~/.cache/huggingface"
  # The compute cache is SHARED by every box (kernels are content-keyed), so it
  # sits beside the two per-box roots rather than inside either of them.
  SEED_COMPUTE=$EMIT_DIR/compute-caches
  # No model collection until a path is typed (s38): the prompt's default is
  # the word "None", not a directory the installer would go and create.
  SEED_MODELS=""
  # The two host roots, both derived from the resource path.
  SEED_DATA_BASE=$EMIT_DIR/data
  SEED_PCACHE_BASE=$EMIT_DIR/caches
  [[ ${#SEED_SRC[@]} -eq 0 ]] && return 0
  # Each seed is the recorded path AS RECORDED — the prompt below offers that
  # string, and an empty answer hands the same string back to abs_path, so a
  # box that is left alone keeps the spelling it was set up with.
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_PATH["$box:hf"]:-}" ]] && { SEED_HF=${EXD_PATH["$box:hf"]}; break; }
  done
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_PATH["$box:caches"]:-}" ]] && { SEED_COMPUTE=${EXD_PATH["$box:caches"]}; break; }
  done
  # A recorded /opt/models bind IS the answer: it comes back as the prompt's
  # default, so an empty answer keeps the share exactly where it was.
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_PATH["$box:models"]:-}" ]] && { SEED_MODELS=${EXD_PATH["$box:models"]}; break; }
  done
  # Ports: wholesale defaults only if nothing recorded moved off them.
  for box in "${SEED_SRC[@]}"; do
    if [[ -n "${EXD_PORT[$box]:-}" && ${EXD_PORT[$box]} != "${BOX_HOST_PORT[$box]}" ]]; then
      SEED_PORTS=N
      break
    fi
  done
  # The two three-way questions: unanimous seed boxes seed their own answer,
  # a split seeds "case-by-case" (which is what the split IS).
  yes=0 no=0
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_BOXSV[$box]:-}" ]] && yes=$((yes + 1)) || no=$((no + 1))
  done
  if [[ $yes -gt 0 && $no -gt 0 ]]; then SEED_SERVE=c
  elif [[ $yes -gt 0 ]]; then SEED_SERVE=y
  else SEED_SERVE=n
  fi
  # Host boot is only meaningful for boxes that serve at box start (the
  # invariant), so only those boxes get a vote here.
  yes=0 no=0
  for box in "${SEED_SRC[@]}"; do
    [[ -n "${EXD_BOXSV[$box]:-}" ]] || continue
    [[ -n "${EXD_HSTSV[$box]:-}" ]] && yes=$((yes + 1)) || no=$((no + 1))
  done
  if [[ $yes -gt 0 && $no -gt 0 ]]; then SEED_HOST=c
  elif [[ $yes -gt 0 ]]; then SEED_HOST=y
  else SEED_HOST=n
  fi
  # The two roots, each read back from the paths its family actually records:
  # one shared base → Y with that base offered at the base prompt; no agreement
  # (or a shape the layout does not use) → N, and the boxes are asked one by
  # one. Persistent data counts its nested leaves too, since they are the same
  # family: an input dir somewhere else means the base is NOT common.
  #
  # NO AGREEMENT IS NOT NO INFORMATION (G4, Jei s40): the question still defaults
  # to N and the boxes are still asked one by one, but the base it OFFERS comes
  # from the files rather than from the factory. On his run the data question
  # offered ~/resources/droste/data — a path invented on the spot — while his
  # inis put the data base at /srv/appdata/droste, and his ruling was that the
  # default has to MATCH THE FILE (he refused a "(recorded)" marker: the value
  # itself has to be right). Saying yes here now lands the family where most of
  # it already is, and the outliers meet the move question in their own section.
  base=$(family_base data input output workspace)
  if [[ -n $base ]]; then
    if [[ $base == "-" ]]; then
      SEED_DATA_Q=N
      SEED_NOBASE_DATA=$(family_example data input output workspace)
      # `if`, not `[[ … ]] &&`: a false test as the last command of a branch is
      # the status of the whole compound, and this script runs under `set -e`.
      base=$(family_dominant data input output workspace)
      if [[ -n $base ]]; then SEED_DATA_BASE=$base; fi
    else
      SEED_DATA_BASE=$base
    fi
  fi
  base=$(family_base pcache)
  if [[ -n $base ]]; then
    if [[ $base == "-" ]]; then
      SEED_PCACHE_Q=N
      SEED_NOBASE_PCACHE=$(family_example pcache)
      base=$(family_dominant pcache)
      if [[ -n $base ]]; then SEED_PCACHE_BASE=$base; fi
    else
      SEED_PCACHE_BASE=$base
    fi
  fi
  return 0
}

# Why a family is about to be asked box by box. A fallback that says nothing
# looks exactly like a failed read-back: the question flips to N and offers a
# FACTORY example, while the user knows perfectly well where their files are.
# Naming what was found turns a silent degrade into a statement.
# One entry keeps the drawn shape (a malformed path explains itself in a
# parenthetical); a DISAGREEMENT takes two paths to show, and two paths do not
# fit in one — they are listed under the sentence instead, one per line, where a
# long path can wrap without breaking the line it is quoted inside.
#
# The sentence itself is written for the place it appears: this note fires
# during GENERAL SETUP, and a bare "comfyui: …" under a global question read as
# a stray box section (Jei: "this is not a comfyui section"). Naming the BIND on
# each line — "comfyui data", "comfyui input" — makes them quotations from the
# ini rather than a heading.
nobase_note() {   # "what" "<box> <leaf>: <path>[\n<box> <leaf>: <path>]"
  local line n=0
  [[ -n $2 ]] || return 0
  while IFS= read -r line; do n=$((n + 1)); done <<<"$2"
  if [[ $n -le 1 ]]; then
    printf '\n  %sExisting %s do not share a common base%s\n' "$C_QTXT" "$1" "$RESET"
    printf '  %s(%s) - asking per box.%s\n' "$C_QTXT" "$2" "$RESET"
    return 0
  fi
  printf '\n  %sExisting %s do not share a common base - asking per box:%s\n' \
    "$C_QTXT" "$1" "$RESET"
  while IFS= read -r line; do
    printf '    %s%s%s\n' "$C_QTXT" "$line" "$RESET"
  done <<<"$2"
  return 0
}

# ── General Setup ────────────────────────────────────────────────────────────
# Everything that can be settled ONCE for the whole install: the two networking
# questions that would otherwise repeat per box (ports, and when a box's server
# comes up), then the two HOST ROOTS (program caches, persistent data) and the
# paths every box shares — the compute cache, the HF cache, the model share.
general_setup() {
  local pcache_common=0 data_common=0
  section "General Setup"
  subhdr "Networking"
  # One answer settles every per-box port question (the table above just showed
  # the defaults, so this is the moment they can be accepted wholesale).
  ask_yn "Use default ports for all services" "$SEED_PORTS"
  [[ $ANS_YN -eq 1 ]] && PORTS_DEFAULT=1
  # Does a box's SERVICE come up when its container starts?
  # (DROSTE_<APP>_STARTUP_ENABLED — this asks about BOX START only, never about
  # whether a server should be up right now; that is the box's own .IS_ACTIVE.)
  # "case-by-case" hands the question to each box's own section.
  ask_ync "Start servers at box start" "$SEED_SERVE"
  SERVE_MODE=$ANS_3
  # And does the BOX come up at host boot? (a systemd user unit doing `podman
  # start`.) INVARIANT (Jei): host boot ⇒ box start. So a box that does not
  # serve at box start is never asked about host boot, at any level:
  #   box-start = no   → host boot is no, no question anywhere
  #   box-start = c    → host boot is implicitly case-by-case, and only the
  #                      boxes that answered yes above are asked
  #   box-start = yes  → the install-wide question below
  case "$SERVE_MODE" in
    y) ask_ync "Start servers at host boot" "$SEED_HOST"; HOST_MODE=$ANS_3 ;;
    c) HOST_MODE=c ;;
    *) HOST_MODE=n ;;
  esac
  # ── Storage Paths: the two elections, then one block per family ────────────
  # Jei's s41 layout. The two yes/no questions stand together under "Storage
  # Paths" — PERSISTENT DATA FIRST, since it is the half people care about and
  # the half the box sections then talk about — and everything each answer
  # implies is asked under its own subheader, beside the shared paths that
  # belong to the same family. The old single run of prompts put the model share
  # between two caches and the base prompts three questions away from the
  # question that decided them.
  #
  # Each election names the BASE, not the templated leaf (Jei, live test): the
  # per-box shape is the installer's business, and spelling it out here read as
  # though the literal string were the answer. Where the family lands is said
  # once, in the italic line under the subheader.
  subhdr "Storage Paths"
  nobase_note "data dirs" "$SEED_NOBASE_DATA"
  ask_yn "Store persistent data at common base path (e.g., $SEED_DATA_BASE)" \
    "$SEED_DATA_Q"
  data_common=$ANS_YN
  nobase_note "program cache dirs" "$SEED_NOBASE_PCACHE"
  ask_yn "Store program caches at common base path (e.g., $SEED_PCACHE_BASE)" \
    "$SEED_PCACHE_Q"
  pcache_common=$ANS_YN

  subhdr "Host Data Paths"
  # A base prompt renders ONLY for a family the user agreed to place at a common
  # base (Jei s38); declining routes that family to the per-box path question in
  # the box's own section instead.
  if [[ $data_common -eq 1 ]]; then
    prose "*Data will be stored at <base>/<box>." "$C_QTXT"
    ask_path_as "Persistent data base path" "$SEED_DATA_BASE"
    DATA_ROOT=$ANS_PATH
    DATA_AUTO=1
  fi
  # The optional read-only model share — a path-or-None prompt, so the bind and
  # its location are one answer instead of a toggle plus a follow-up — and the
  # HF cache, which is a MODEL STORE and never wiped, whatever its name says.
  ask_path_or_none "Path to bind as read-only share /opt/models" "$SEED_MODELS"
  MODELS_DIR=$ANS_OPT_PATH
  ask_path_as "HuggingFace models (\"cache\", never wiped)" "$SEED_HF"
  HF_CACHE=$ANS_PATH

  subhdr "Host Cache Paths"
  if [[ $pcache_common -eq 1 ]]; then
    prose "*Caches will be stored at <base>/<box>." "$C_QTXT"
    ask_path_as "Program caches base path" "$SEED_PCACHE_BASE"
    PCACHE_ROOT=$ANS_PATH
    PCACHE_AUTO=1
  fi
  # Shared by every box (kernels are content-keyed), which is why it sits here
  # rather than inside either per-box root.
  ask_path_as "Compute caches (MIOpen/Triton/torch)" "$SEED_COMPUTE"
  COMPUTE_CACHE=$ANS_PATH
  # THE STALE-CACHE QUESTION, install-wide and last in its own block: it is
  # about the caches the answers above just placed, and it is asked ONLY when
  # there is something to clear. One YES settles every box; a NO hands the
  # decision to the boxes that have something, in their own sections. Default
  # YES — a stale cache is the box's most common cause of "it starts but
  # misbehaves", and nothing in one is authored.
  if stale_any; then
    ask_yn "Stale caches often cause malfunctions. Clear all old / stale caches" Y
    CLEAR_STALE_ALL=$ANS_YN
  fi
  # Close the section the way a per-box section and the Data Mapping one close,
  # so whatever follows (a rule, a banner) keeps the same two-line gap.
  say ""
  return 0
}

# ── Filesystem probe + overlay mitigation (the ecryptfs lesson) ──────────────
FSTYPE=""
probe_fstype() {  # dir → FSTYPE
  local d
  d=$(fs_path "$1")     # findmnt takes a path, not a spelling
  if [[ -n "${DROSTE_SETUP_FSTYPE:-}" ]]; then
    FSTYPE=$DROSTE_SETUP_FSTYPE
    return 0
  fi
  while [[ ! -e $d && $d != / ]]; do d=$(dirname "$d"); done
  FSTYPE=$(findmnt -n -o FSTYPE --target "$d" 2>/dev/null) \
    || FSTYPE=$(stat -f -c %T "$d" 2>/dev/null) || FSTYPE=unknown
  [[ -z $FSTYPE ]] && FSTYPE=unknown
  return 0
}

MIT_ALL=""        # ""=unset, else fuse|copy|ignore applied to all later paths
MIT_ASKED=0
MIT_MODE=""       # result of the last mitigate_path call ("" = nothing needed)

# One continuous block of prose, word-wrapped to the screen and indented two.
# The colour is a parameter because two voices use this same block: body text
# for the Data Mapping explainer, and the quieter question-text grey for a note
# that stands immediately above a prompt (nobase_note's voice).
prose() {   # text [colour]
  local w line col=${2:-$C_TEXT}
  w=$(( $(disp_width) - 2 ))
  while IFS= read -r line; do
    printf '  %s%s%s\n' "$col" "$line" "$RESET"
  done < <(printf '%s\n' "$1" | fold -s -w "$w" | sed 's/[[:space:]]*$//')
  return 0
}

# The Data Mapping section: shown for the FIRST writable path that lands on a
# filesystem kernel overlayfs will not take, and again later for any path still
# unaccounted for (the "apply to all" answer is what stops the repeats).
# "nested" = shown from inside a per-box section, which wants a blank line above.
data_mapping_menu() {  # dir [nested] → ANS_CH in {f,c,n,i}
  local dir=$1 nested=${2:-} letters="Fcni"
  [[ $nested == nested ]] && say ""
  section "Data Mapping"
  say ""
  prose "The filesystem for $dir is incompatible with droste's default tool, Linux's overlayfs. Note: if ignored, filesystem must be changed before any containers can load."
  sub "Select an option to address filesystem incompatibility."
  opt_row F "use overlay" \
    "(app files ~30% slower; models OK)" 16 "$(isdef F "$letters")"
  opt_row c "opied files" \
    "(approx. 10-20 GB more storage)" 16 "$(isdef c "$letters")"
  opt_row n "ew path" "(most efficient)" 16 "$(isdef n "$letters")"
  opt_row i "gnore" "(\"ostrich solution\"; will fail on start)" 16 "$(isdef i "$letters")"
  say ""
  ask_choice "Identify how to proceed [F/c/n/i]" "$letters"
  return 0
}

# Probe ONE path and settle its overlay mitigation.
#   MIT_MODE=""            the filesystem is fine (or the path is not writable)
#   MIT_MODE=fuse|copy|ignore
#   return 2               the user asked for a NEW PATH — the caller re-asks
# The first hostile path opens the menu; "Apply this decision to all paths" is
# offered exactly once and, when accepted, silences every later path.
mitigate_path() {  # dir [nested]
  local dir=$1 nested=${2:-}
  MIT_MODE=""
  probe_fstype "$dir"
  overlay_hostile_fs "$FSTYPE" || return 0
  if [[ -n $MIT_ALL ]]; then
    MIT_MODE=$MIT_ALL
    return 0
  fi
  data_mapping_menu "$dir" "$nested"
  case "$ANS_CH" in
    f) MIT_MODE=fuse ;;
    c) MIT_MODE=copy ;;
    i) MIT_MODE=ignore ;;
    n) return 2 ;;
  esac
  if [[ $MIT_ASKED -eq 0 ]]; then
    MIT_ASKED=1
    ask_yn "Apply this decision to all paths" Y
    [[ $ANS_YN -eq 1 ]] && MIT_ALL=$MIT_MODE
  fi
  return 0
}

# The paths that exist before any box section, most primary first. "Already
# answered for" is same_dir, not ==: a root typed as ~/droste and a resource
# path typed as /home/you/droste are one directory and one question.
mitigation_slot_path() {  # slot → path ("" when that slot is not in play)
  case "$1" in
    rc)      printf '%s' "$EMIT_DIR" ;;
    data)    [[ -n $DATA_ROOT ]] && ! same_dir "$DATA_ROOT" "$EMIT_DIR" \
               && printf '%s' "$DATA_ROOT" ;;
    # The program-cache root is where the venv upper lands, so it has to accept
    # an overlay upper in its own right (P0 choice C) — probed unless it is one
    # of the paths already answered for.
    pcache)  [[ -n $PCACHE_ROOT ]] && ! same_dir "$PCACHE_ROOT" "$EMIT_DIR" \
               && ! same_dir "$PCACHE_ROOT" "$(data_root)" \
               && printf '%s' "$PCACHE_ROOT" ;;
    compute) printf '%s' "$COMPUTE_CACHE" ;;
    hf)      printf '%s' "$HF_CACHE" ;;
  esac
  return 0
}

# Re-ask ONE of those paths (the "new path" answer) and take the new value.
reask_slot() {  # slot → 0 when re-asked
  case "$1" in
    rc)
      ask_path_as "Identify a path for droste resource storage" "$EMIT_DIR"
      # A root that merely tracked the resource path keeps tracking it.
      [[ $DATA_ROOT == "$EMIT_DIR/data" ]] && DATA_ROOT=""
      [[ $PCACHE_ROOT == "$EMIT_DIR/caches" ]] && PCACHE_ROOT=""
      EMIT_DIR=$ANS_PATH
      DEFAULT_ROOT=$EMIT_DIR
      # Everything the old resource path implied has to be re-derived: which
      # boxes already exist there, and what the user wants done about them.
      EX_INI=() EX_CTR=() EXD_PATH=()
      EXD_PORT=() EXD_BOXSV=() EXD_HSTSV=() EXD_MODE=()
      detect_existing
      existing_settings
      seed_globals
      ;;
    data)
      ask_path_as "Persistent data base path" "$(data_root)"
      DATA_ROOT=$ANS_PATH ;;
    pcache)
      ask_path_as "Program cache base path" "$(pcache_root)"
      PCACHE_ROOT=$ANS_PATH ;;
    compute)
      ask_path_as "Compute caches (MIOpen/Triton/torch)" "$COMPUTE_CACHE"
      COMPUTE_CACHE=$ANS_PATH ;;
    hf)
      ask_path_as "HuggingFace models (\"cache\" - never wiped)" "$HF_CACHE"
      HF_CACHE=$ANS_PATH ;;
    *) return 1 ;;
  esac
  return 0
}

# Data Mapping over the paths chosen BEFORE any box section. Only the FIRST /
# most primary hostile one opens the section (Jei's spec); whatever the user
# answers there either covers every path that follows ("apply to all") or leaves
# the remaining paths to raise it again where they arise, box paths included.
global_mitigation() {
  local slot dir rc
  while :; do
    dir=""
    for slot in rc data pcache compute hf; do
      dir=$(mitigation_slot_path "$slot")
      [[ -n $dir ]] || continue
      probe_fstype "$dir"
      overlay_hostile_fs "$FSTYPE" && break
      dir=""
    done
    [[ -z $dir ]] && return 0
    rc=0
    mitigate_path "$dir" || rc=$?
    if [[ $rc -ne 2 ]]; then
      # Close the section the way a per-box section closes, so the banner
      # below it keeps the same two-line gap as every other banner.
      say ""
      return 0
    fi
    reask_slot "$slot" || return 0
  done
}

