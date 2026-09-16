# ── Box selection ────────────────────────────────────────────────────────────
# The answer is parsed ROBUSTLY: punctuation is a separator, so "1,2 3",
# "comfyui/llama" and "[1] [2]" all work. Tokens we cannot place are named back
# rather than silently dropped, and the prompt repeats.
# ⚠️ THIS COMMENT USED TO SAY "anything that is not an ASCII letter or digit",
# and believing it is what hid a crash for a whole release. `[!a-zA-Z0-9]` is a
# bracket RANGE and ranges COLLATE IN THE USER'S LOCALE — under en_US.UTF-8 a
# full-width `１` is INSIDE it and survives as a token. That is deliberate now:
# surviving is what lets the loop below NAME IT BACK. What must never happen is
# a survivor reaching arithmetic, and the dispatch below is where that is
# enforced. ⭐ Describe a bracket expression by what it MEASURABLY admits in the
# caller's locale, never by what its characters look like.
select_boxes() {
  local box tok idx clean bad dw
  declare -A want=()
  if [[ ${#ARG_BOXES[@]} -gt 0 ]]; then
    for tok in "${ARG_BOXES[@]}"; do
      [[ -n "${BOX_HOST_PORT[$tok]:-}" ]] || die "unknown box: $tok"
      want[$tok]=1
    done
  else
    say ""
    # Columns land at 2 / 8 / 21 / 34 / 69. Each column carries its own color
    # THROUGH its padding, so the row reads as four colored fields, and the
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
        # 🚨 A DIGIT IS VOUCHED FOR BEFORE IT EVER REACHES $(( )). This was
        # `case [1-5]`, and a bracket RANGE COLLATES IN THE USER'S LOCALE: under
        # en_US.UTF-8 a full-width `１` MATCHED it, and `$((tok-1))` then died
        # with "operand expected" and took the whole installer with it — no
        # message, no re-prompt. One IME toggle away on a Japanese desktop.
        # ⭐ POSIX pins [[:digit:]] to 0-9 in EVERY locale, which is what makes it
        # the right instrument. ⚠️ [[:alnum:]] does NOT — it re-admits the very
        # character this guards against. Measured under C, en_US and ja_JP.
        # ⭐ The bound is DERIVED from BOXES, so the drawn menu and this dispatch
        # cannot drift apart; the "All" index follows the list instead of being
        # a hardcoded 6 that a sixth box would silently collide with.
        if [[ ${tok,,} == all ]]; then
          for box in "${BOXES[@]}"; do want[$box]=1; done
        elif [[ $tok =~ ^[[:digit:]]{1,3}$ ]]; then
          # 10# so a typed 08 is eight rather than a base error; the {1,3} cap
          # keeps the value far below any overflow.
          idx=$((10#$tok))
          if   (( idx >= 1 && idx <= ${#BOXES[@]} )); then want[${BOXES[$((idx-1))]}]=1
          elif (( idx == ${#BOXES[@]} + 1 )); then for box in "${BOXES[@]}"; do want[$box]=1; done
          else bad="$bad $tok"; fi
        elif [[ -n "${BOX_HOST_PORT[${tok,,}]:-}" ]]; then
          want[${tok,,}]=1
        else
          bad="$bad $tok"
        fi
      done
      if [[ -n $bad ]]; then
        subnote "Unrecognized:$bad $EMD use the names or numbers above."
        continue
      fi
      # ⚠️ AN ANSWER THAT SURVIVES AS NOTHING STILL HAS TO BE ANSWERED. If every
      # character was a separator (`!!!`), or the locale folded a multibyte
      # answer away before it could be named back, the loop used to re-prompt in
      # SILENCE — the user sees their input vanish and is told nothing, which is
      # the one outcome this installer never gets to have.
      if [[ ${#want[@]} -eq 0 ]]; then
        subnote "Unrecognized: $ANS $EMD use the names or numbers above."
        continue
      fi
      break
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
  [[ -n "${EXD_PATH["$box:program"]:-}" ]] && PATHS["$box:program"]=${EXD_PATH["$box:program"]}
  # The program-cache root gets the same treatment as the program one: it is not a
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
# EVERY question except the config-path one (which has to come first — until
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
# (<base>/<box>/<config|program|user|input|output|workspace>), and since s79 the
# leaf's directory name IS its label.
#
# READ TOLERANTLY, WRITE STRICTLY: a program path recorded as <base>/<box> is the
# pre-s41 layout, from before the program dir became a `program` sibling of the
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
  d=$leaf
  if [[ $p == */"$box"/"$d" ]]; then printf '%s' "${p%/"$box"/"$d"}"; return 0; fi
  if [[ $leaf == program && $p == */"$box" ]]; then printf '%s' "${p%/"$box"}"; return 0; fi
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

# The label as the note says it out loud, DERIVED from BIND_TITLE: a leaf is
# named once (contract.sh) and its mid-sentence form is that name, lowercased.
# "pcache" is this script's word for them, not the reader's.
#
# ⚠️ THE ARMS BELOW ARE THE EXCEPTIONS, and they are listed so they READ as
# exceptions rather than as three more copies of a name:
#   pcache  has no title at all — its prompt is written out (BIND_PROMPT), so
#           there is nothing to lowercase and the word is given here.
#   input   "input files" / "output files" name a CATEGORY at a prompt and read
#   output  as clutter in a sentence ("Input for comfyui will be moved to …").
# Anything else is its title in lower case, and a leaf with no title is a bug
# that `set -u` reports rather than papering over with the label.
leaf_word() {  # label → display word
  local title
  case "$1" in
    pcache) printf 'program cache'; return 0 ;;
    input)  printf 'input';         return 0 ;;
    output) printf 'output';        return 0 ;;
  esac
  title=${BIND_TITLE[$1]}
  printf '%s' "${title,,}"
}

# 🗑️ `leaf_dir` LIVED HERE AND WAS DELETED IN s79. It translated exactly one
# label — `data` into a `program` directory — while both of that label's
# user-facing strings already read "Program Data". The label was renamed to
# `program` instead, so the leaf IS the label and there is nothing to translate.
# ⭐ RULED (Jei, s41): THE NESTING WAS AN OVERSIGHT, and that layout is unchanged.
# The box's data dir used to BE <base>/<box>, with input/output living INSIDE it;
# they are siblings now, under a box directory that is not itself a bind:
#
#     <data base>/<box>/config    → /opt/config      (s79)
#     <data base>/<box>/program   → /opt/program     (was /opt/data)
#     <data base>/<box>/user      → /opt/ComfyUI/user (s79, comfyui)
#     <data base>/<box>/input     → /opt/ComfyUI/input
#     <data base>/<box>/output    → /opt/ComfyUI/output
#
# NO MIGRATION for the leaf layout: existing boxes keep the paths their ini
# records (Jei: "I can manually fix my boxes"), and only new placements take the
# new shape. ⚠️ THE CONFIG SPLIT IS NOT COVERED BY THAT, because the CONTAINER
# side moved too and an old box's config files sit where the box can no longer
# read them — see report_retired_configs and cfg_write_seeds' retired-path guard.

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
  # what the user chose, which is what every later line shows. (An XDG variable
  # that IS set is already absolute and is used as it stands — see factory_root.)
  # shellcheck disable=SC2088  # a LITERAL ~, resolved by fs_path at use
  SEED_HF="~/.cache/huggingface"
  # The compute cache is SHARED by every box (kernels are content-keyed), so it
  # sits beside the per-box program caches rather than inside any of them.
  SEED_COMPUTE=$(factory_root compute)
  # No model collection until a path is typed (s38): the prompt's default is
  # the word "None", not a directory the installer would go and create.
  SEED_MODELS=""
  # ⭐ THE TWO HOST ROOTS NO LONGER HANG OFF THE CONFIG PATH (0.7.0). Each has
  # its own XDG variable and its own factory spelling, so a config path typed
  # somewhere unusual leaves the data and the caches exactly where they were.
  SEED_DATA_BASE=$(factory_root data)
  SEED_PCACHE_BASE=$(factory_root pcache)
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
  base=$(family_base program config user input output workspace)
  if [[ -n $base ]]; then
    if [[ $base == "-" ]]; then
      SEED_DATA_Q=N
      SEED_NOBASE_DATA=$(family_example program config user input output workspace)
      # `if`, not `[[ … ]] &&`: a false test as the last command of a branch is
      # the status of the whole compound, and this script runs under `set -e`.
      base=$(family_dominant program config user input output workspace)
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

# ── THE FIVE PATH QUESTIONS — ONE ASKER EACH ─────────────────────────────────
# 🚨 EVERY ONE OF THEM WAS AUTHORED TWICE AND THAT WAS THE DEFECT (Jei: "it's not
# asking twice, it should just be a single question. why would there be a second
# copy of the same question?"). Each prompt stood once where it is first asked and
# again inside the Data Mapping "new path" re-ask — a later pass, since deleted —
# differing only in the default it offered. One question, two authorings, nothing
# keeping them in step: the G11 shape.
#
# 🚨 AND TWO OF THE FIVE HAD ALREADY DRIFTED, IN THE TREE, UNNOTICED:
#
#   initial ask                                   re-ask copy
#   HuggingFace models ("cache", never wiped)     …("cache" - never wiped)
#   Program caches base path                      Program cache base path
#
# ⭐ NOBODY SAW IT BECAUSE THE SECOND COPY ONLY EVER RENDERS ON AN OVERLAY-HOSTILE
# FILESYSTEM — a screen almost no run reaches, which is exactly the kind of copy
# that rots silently. THE INITIAL ASK'S WORDING IS THE SURVIVOR in both cases: it
# is the one every user sees, and a third spelling invented here would be one more
# thing to keep in step.
# 🗄️ The config prompt had already paid the same toll the other way — relabelling
# it from "droste resource storage" to "droste config" had to be done twice, and a
# reader who found one copy had no reason to look for the other.
#
# ⭐ ONE RULE FOR THE DEFAULT, AND IT NEEDS NO MODE FLAG: THE VALUE ALREADY IN
# HAND, ELSE THE SEED. `${HF_CACHE:-$SEED_HF}` is the whole of it — the variable is
# empty until the question is answered and holds the answer forever after, so the
# STATE says which call this is and no caller has to be trusted to. That is the
# same shape as port_default / path_default: one prompt, a default that varies with
# where in the run it is asked.
# ⭐ THE RE-ASK OBEYS THE SAME RULE FROM INSIDE ask_path_settled, which carries the
# answer forward as the next default — the variable here is not written until the
# path has settled, so the loop is the only thing that can know the value in hand.
# ⚠️ THE SEEDS ARE NOT DEFAULTED WITH `:-` HERE. An unset SEED_* is a bug (it
# means a prompt ran before seed_globals), and `set -u` reporting it is worth more
# than a prompt that quietly offers an empty bracket.
#
# ⚠️ WHAT AN ASKER OWNS IS THE QUESTION AND ITS ANSWER — the prompt text, the
# default, and the one variable the answer lands in. It does NOT own what the
# answer IMPLIES: DATA_AUTO / PCACHE_AUTO stay at the election that sets them
# (the "common base path" yes/no), because that is a different question with a
# different answer.
#
# 🏁 THE PROBE NOW HAPPENS AT THE MOMENT THE PATH IS ANSWERED (Jei: "if a question
# is to be re-asked, we should re-ask it AS SOON AS we get the first answer. We
# should check right then and there, and never need to again."). Each of these
# asks through ask_path_settled — ONE routine, below, beside the probe it calls —
# so the re-ask happens in place and no later pass exists to need a second copy of
# anything. ⚠️ Do not fold these back into their call sites: what each one owns is
# a question, and ask_path_settled owns what happens to the answer.

# ⭐ THE CONFIG ROOT IS THE ONE WITH A SECOND WAY TO BE ANSWERED, and the rule
# lives in its asker for the same reason the prompt text does — the one call site
# inherits it, and so would a second.
# ⭐ IT IS ALSO THE ONE THAT DOES NOT SETTLE A FILESYSTEM, because nothing droste
# overlays can land in it — see THE FOUR SETTLED PATHS, below.
# 🚨 DROSTE_CONFIG PINS THE ROOT, SO THE PROMPT DOES NOT FIRE (Jei: "if
# DROSTE_CONFIG is set already at load, we need to skip the prompt for the config
# directory" · "check if DROSTE_CONFIG is set, and if not, ask the question"). The
# environment has already named where droste's definition files live; asking for a
# path on top of that offers a choice the user made elsewhere and leaves one root
# with two answers.
#
# ⭐ THIS IS ALSO WHAT MAKES step_log_root's LITERAL READING OF THE VARIABLE
# COHERENT, and the two only make sense together: you cannot TYPE a config root
# when the prompt does not fire, so in every run where DROSTE_CONFIG has a value,
# $EMIT_DIR is that value and "the variable" and "the answer" cannot disagree.
#
# ⚠️ A BLANK IS ABSENT, AND THAT IS THE PROJECT'S STANDING RULE RATHER THAN A
# COURTESY HERE: DROSTE_CONFIG= asks the question, with the factory default in the
# bracket, exactly as an unset variable does. `factory_root config` already reads
# it that way, so this tests the same `-n` and keeps no second copy of the rule.
#
# 🚨 SKIPPING A QUESTION IS NOT GOING SILENT. The run still says which root it is
# using and that the environment is what chose it — a reader who never saw the
# path cannot tell where droste is reading, and a root pinned by a variable set
# months ago in a startup file is the case where they are LEAST likely to know.
#
# ⭐ THE CREATE CONFIRMATION STAYS — FOR TYPED PATHS. Skipping the prompt settles
# WHICH directory; making one that is not there yet is a mutation, and this
# installer confirms mutations — the same ensure_dir, and the same "Create <path>?"
# ⚠️ THE PINNED ROOT IS THE ONE EXCEPTION (Jei, s87): when DROSTE_CONFIG names the
# directory, the variable already answered and nothing is asked — ask_config_root
# creates it through ensure_dir's no-question arm instead. A typed path is a
# proposal; a pinned one is a decision.
# ⚠️ THE PROMPT BELOW FIRES ONLY WITH THE VARIABLE UNSET. Since s87 a pinned root
# is created without asking and an unusable one errors the run out, so reaching
# ask_path_as means the environment named nothing — and typing a directory there
# is a real way forward, not a contradiction. (Its own loop still confirms each
# create: a typed path is a proposal; a pinned one was the decision.)
#
# 🗄️ IT TOOK AN open|reask MODE UNTIL 0.7.0, because Data Mapping could re-ask the
# config root and a pinned root had to refuse there. Neither exists now: this root
# is not probed, so there is one call and one behavior. ALWAYS returns 0 — one way
# or another this call leaves EMIT_DIR holding a root.
ask_config_root() {   # → EMIT_DIR
  local def
  def=${EMIT_DIR:-$(factory_root config)}
  if [[ -n ${DROSTE_CONFIG:-} ]]; then
    # abs_path for the reason every other path input gets it: a RELATIVE spelling
    # cannot be resolved later without the directory it was written against. An
    # absolute or ~ spelling comes through exactly as the environment wrote it.
    def=$(abs_path "$DROSTE_CONFIG")
    prose "DROSTE_CONFIG is set, so that is the config path and it is not asked for:" \
      "$C_QTXT"
    printf '    %s%s%s\n' "$C_FILE" "$def" "$RESET"
    # ⭐ A PINNED ROOT IS CREATED, NOT CONFIRMED (Jei, s87): the variable IS the
    # answer, so "Create <path>?" would be asking what the environment already
    # said. CREATE_ALL=1 takes ensure_dir's no-question arm — still through
    # UI_MKDIR, so a dry run models it rather than making it.
    # 🚨 UNCREATABLE OR UNWRITABLE IS FATAL (Jei, s87) — it errors the run out,
    # it does not fall through to the prompt. A pinned root the box cannot use
    # is a setting that cannot be honored, and the s60 table says what that
    # gets: refuse, loudly, naming the line to fix. The prompt below is then
    # reachable only with the variable UNSET, where typing another directory is
    # a real way forward rather than a contradiction of the environment.
    if CREATE_ALL=1 ensure_dir "$def"; then
      EMIT_DIR=$def
      if ! dry::on; then
        # A real probe, not `[ -w ]`: that test lies under root, and this runs
        # as whoever invoked the installer. Removed as soon as it answers — the
        # run's own writes are the lasting proof, this is only the early one.
        if ! touch "$def/.droste-write-test" 2>/dev/null; then
          die "DROSTE_CONFIG names $def, which is not writable — fix the variable or unset it to be asked."
        fi
        rm -f "$def/.droste-write-test" 2>/dev/null || true
      fi
      return 0
    fi
    die "DROSTE_CONFIG names $def, which could not be created — fix the variable or unset it to be asked."
  fi
  ask_path_as "Identify a path for droste config" "$def"
  EMIT_DIR=$ANS_PATH
  return 0
}

ask_data_root() {   # → DATA_ROOT
  ask_path_settled "Persistent data base path" "${DATA_ROOT:-$SEED_DATA_BASE}"
  DATA_ROOT=$ANS_PATH
  return 0
}

ask_pcache_root() {   # → PCACHE_ROOT
  ask_path_settled "Program caches base path" "${PCACHE_ROOT:-$SEED_PCACHE_BASE}"
  PCACHE_ROOT=$ANS_PATH
  return 0
}

ask_compute_cache() {   # → COMPUTE_CACHE
  ask_path_settled "Compute caches (MIOpen/Triton/torch)" "${COMPUTE_CACHE:-$SEED_COMPUTE}"
  COMPUTE_CACHE=$ANS_PATH
  return 0
}

ask_hf_cache() {   # → HF_CACHE
  ask_path_settled "HuggingFace models (\"cache\", never wiped)" "${HF_CACHE:-$SEED_HF}"
  HF_CACHE=$ANS_PATH
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
    ask_data_root
    DATA_AUTO=1
  fi
  # The optional read-only model share — a path-or-None prompt, so the bind and
  # its location are one answer instead of a toggle plus a follow-up — and the
  # HF cache, which is a MODEL STORE and never wiped, whatever its name says.
  ask_path_or_none "Path to bind as read-only share /opt/models" "$SEED_MODELS"
  MODELS_DIR=$ANS_OPT_PATH
  ask_hf_cache

  subhdr "Host Cache Paths"
  if [[ $pcache_common -eq 1 ]]; then
    prose "*Caches will be stored at <base>/<box>." "$C_QTXT"
    ask_pcache_root
    PCACHE_AUTO=1
  fi
  # Shared by every box (kernels are content-keyed), which is why it sits here
  # rather than inside either per-box root.
  ask_compute_cache
  # THE STALE-CACHE QUESTION, install-wide and last in its own block: it is
  # about the caches the answers above just placed, and it is asked ONLY when
  # there is something to clear. One YES settles every box; a NO hands the
  # decision to the boxes that have something, in their own sections. Default
  # YES — a stale cache is the box's most common cause of "it starts but
  # misbehaves", and nothing in one is authored.
  if stale_any; then
    # The same disclosure the per-box offer makes, for the same reason: this one
    # answer authorizes the clear for every box, so it authorizes bouncing every
    # box that is running, and it has to say so before it is answered (Jei, s79).
    prose "*A box that is running will be stopped, cleared, and started again." "$C_QTXT"
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
# Directories already settled, in the spelling they were answered in. A user who
# answers two questions with ONE directory is asked about it once.
MIT_SEEN=()

# One continuous block of prose, word-wrapped to the screen and indented two.
# The color is a parameter because two voices use this same block: body text
# for the Data Mapping explainer, and the quieter question-text gray for a note
# that stands immediately above a prompt (nobase_note's voice).
prose() {   # text [color]
  local w line col=${2:-$C_TEXT}
  w=$(( $(disp_width) - 2 ))
  while IFS= read -r line; do
    printf '  %s%s%s\n' "$col" "$line" "$RESET"
  done < <(printf '%s\n' "$1" | fold -s -w "$w" | sed 's/[[:space:]]*$//')
  return 0
}

# The Data Mapping section: shown for a writable path that lands on a filesystem
# kernel overlayfs will not take, at the moment that path is answered, and again
# for the next such path (the "apply to all" answer is what stops the repeats).
# 🗄️ IT TOOK A "nested" FLAG for the blank line above, back when one caller stood
# between sections and the other inside one. Every caller is inside a section now,
# so the line is unconditional — a flag two callers always pass is not a choice.
data_mapping_menu() {  # dir → ANS_CH in {f,c,n,i}
  local dir=$1 letters="Fcni"
  say ""
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
mitigate_path() {  # dir
  local dir=$1
  MIT_MODE=""
  probe_fstype "$dir"
  overlay_hostile_fs "$FSTYPE" || return 0
  if [[ -n $MIT_ALL ]]; then
    MIT_MODE=$MIT_ALL
    return 0
  fi
  data_mapping_menu "$dir"
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

# ── THE FOUR SETTLED PATHS ───────────────────────────────────────────────────
# Every path that can carry an overlay upper, or sit under one, settles its
# filesystem AT THE MOMENT IT IS ANSWERED: the data root and the program-cache
# root (where the uppers and their work dirs land), the compute cache and the HF
# cache. Each asks through ask_path_settled, so a "new path" answer re-asks the
# question that was just asked, in place, in the same words.
#
# 🚨 THE CONFIG ROOT IS NOT ONE OF THEM, AND THAT IS A 0.7.0 CONSEQUENCE (ruled
# s83). It was probed while it was the PARENT the data and cache roots defaulted
# under — a hostile filesystem there placed every overlay droste mounts. The three
# roots are independent now, and this one holds the inis, NOTES.md and, in one
# branch, the installer's own logs: text files, on whatever filesystem the user
# keeps their config on. ⭐ Nothing droste overlays can land in it, so there is
# nothing for overlayfs to refuse, and a Data Mapping menu over a directory of
# text files is a question with no consequence.
# ⚠️ WHAT WOULD PUT IT BACK: a bind whose source lands under the config root. The
# test is not "is it ours", it is "can an overlay upper land there".
#
# ⭐ AND THE PRIORITY LIST DISSOLVED WITH THE LATER PASS. `rc data pcache compute
# hf` decided which path "opened the section" while the probe ran after every
# answer was already in. Checking at the answer makes FIRST mean first answered,
# which is the ask order — no list has to say so.
#
# 🚨 EVERY HOSTILE PATH RAISES IT, NOT JUST ONE (Jei, s83: "what if someone never
# answers 'do the same'? Wouldn't it re-ask in that case? And if not, then yes,
# that's a bug."). The old pass returned after a single settled answer, so a user
# who declined "apply to all" was never asked about the rest — and the compute
# cache and the HF cache are not per-box binds, so no box section brought them
# back either: they were raised once in the run or not at all. ⭐ "Apply this
# decision to all paths" is what stops the repeats; declining it is a request to
# decide path by path.

mit_seen() {  # dir → 0 when a directory already settled is this same directory
  local d
  # `if`, not `[[ … ]] &&`: an empty list is the ORDINARY case at the first path,
  # and this script runs under `set -e`.
  if [[ ${#MIT_SEEN[@]} -eq 0 ]]; then return 1; fi
  for d in "${MIT_SEEN[@]}"; do
    same_dir "$d" "$1" && return 0
  done
  return 1
}

# ⭐ THE DE-DUPLICATION IS STILL SAME_DIR, AND IT IS STILL EARNING ITS KEEP
# (0.7.0). The roots no longer NEST — the old defaults put data and caches inside
# the resource path, and the new ones put them under three unrelated XDG
# directories — so it fires far less often than it used to. What it catches is
# unchanged and is the only thing it ever caught: a user who ANSWERS two of the
# questions with one directory. That still costs one probe and one mitigation
# question instead of two, and a `==` would still miss it the moment the two
# answers were spelled differently.
# ⭐ A LIST, NOT A RULE PER PATH. The old form asked, by hand, whether the program
# cache was the config root and whether it was the data root — one comparison per
# pair, and none at all for the two paths nobody had written a rule for. What has
# already settled answers it for every path, including those two.
mit_settle() {  # dir → 0 settled · 2 the user asked for a new path
  local rc=0
  mit_seen "$1" && return 0
  mitigate_path "$1" || rc=$?
  if [[ $rc -eq 2 ]]; then return 2; fi
  MIT_SEEN+=("$1")
  return 0
}

# ⭐ ONE ROUTINE, NOT A LOOP IN EVERY ASKER (Jei, s83: "why not make that a
# routine?"). What an asker owns is the QUESTION — its wording, its default, and
# the variable the answer lands in. What happens to an ANSWER is the same for all
# four, so it is written once, here, beside the probe it calls.
# ⚠️ THE RE-ASK OFFERS THE PATH JUST REJECTED AS ITS DEFAULT, deliberately: it is
# the value in hand, which is the rule every one of these prompts already follows,
# and a user correcting one component of a long path should not retype the rest.
ask_path_settled() {  # "prompt label" default → ANS_PATH (settled)
  local prompt=$1 def=$2 rc
  while :; do
    ask_path_as "$prompt" "$def"
    rc=0
    mit_settle "$ANS_PATH" || rc=$?
    if [[ $rc -ne 2 ]]; then return 0; fi
    def=$ANS_PATH
  done
}

# 🗄️ WHAT STOOD HERE, AND WHY IT IS GONE (0.7.0, s83): reask_slot carried a second
# authoring of all five path prompts, and global_mitigation walked a priority list
# after the interview to decide which one to raise. Both existed only because the
# check ran LATER than the answer.
# ⭐⭐ NONE OF THE THREE ENCODED A DECISION. They re-identified a value that had
# left the place which knew what it was — a slot name standing in for a path, a
# priority list standing in for "which answer came first", a second copy of a
# prompt standing in for the question that had already been asked. Ask at the
# moment of the answer and every one of them has nothing left to do.
# 🗄️ AND TWO THINGS WENT WITH THEM, both of which only ever existed to serve the
# later pass: the pinned-config-root refusal (a root DROSTE_CONFIG names could not
# be re-asked, so the run explained itself instead of offering a prompt whose
# answer it would discard), and the detect_existing / existing_settings /
# seed_globals re-run that a moved config root forced — the config root is
# answered before anything has been detected, so there is nothing to invalidate.


# ── Remembering the config root (the DROSTE_CONFIG export) ───────────────────
# 🚨 THIS IS THE ONE PLACE THIS INSTALLER WRITES INTO A FILE IT DID NOT AUTHOR,
# AND IT IS LICENSED BY THREE THINGS AT ONCE. It is CONSENTED — a yes/no whose
# "no" is a real answer and a complete, non-silent outcome. It is ADDITIVE — on
# a first run not one existing byte is read back and written out again. And it
# is SHOWN IN FULL before it is offered, file and lines both. Remove any one of
# those and this becomes the thing the project forbids outright: WE DO NOT
# REWRITE THE USER'S FILES.
#
# ⭐ THE MARKED BLOCK IS WHAT KEEPS THE SECOND RUN HONEST, and the precedent is
# the ini's own `# droste-setup: spelled="…"` line. We own what lies BETWEEN our
# two markers and nothing else, so a re-run UPDATES that block instead of
# appending a second export — and that is not a rewrite of the user's file,
# because those three lines were never theirs. Everything outside the markers is
# carried through untouched and is never parsed for meaning.
# ⚠️ WHICH IS ALSO WHY A DAMAGED BLOCK IS REFUSED RATHER THAN REPAIRED. One
# marker without its partner, or an END above its BEGIN, means the boundary this
# whole licence rests on is not where it claims to be — and "delete from the
# marker to the end of the file" is how a startup file gets truncated. Detect
# and report; never guess at the shape.
#
# 🚨 THE FILE CASCADE IS PER-FAMILY, BECAUSE zsh DOES NOT READ ~/.profile. A flat
# "fall back to .profile" rule would write a real file for a zsh user and have no
# effect whatsoever — silent, and the worst of both outcomes, since we would have
# touched their file AND left the problem unsolved. zsh's last resort is
# ~/.zprofile.
#
#   $SHELL recognized, its interactive rc exists  → that rc (~/.bashrc, ~/.zshrc)
#   recognized, rc missing                        → that family's login file
#                                                   (~/.profile, ~/.zprofile)
#   unrecognized or unset                         → ~/.profile, NAMED ON SCREEN
#
# ⚠️ RECOGNITION IS BY BASENAME, never by whether $SHELL names a binary this host
# can read. A machine whose $SHELL says zsh belongs to a zsh user whatever is
# installed where this script happens to be running, and testing the file would
# quietly demote them to ~/.profile — the exact failure the per-family cascade
# exists to prevent.
SHRC_BEGIN='# droste-setup: begin DROSTE_CONFIG'
SHRC_END='# droste-setup: end DROSTE_CONFIG'
SHRC_FILE=""        # startup file the export would go into (the SPELLING)
SHRC_GUESSED=0      # 1 when $SHELL named nothing we know and the file is a guess
SHRC_KEEP=""        # every line of that file that is NOT inside our block
SHRC_NB=0           # BEGIN markers the last scan saw
SHRC_NE=0           # END markers the last scan saw
SHRC_CONFLICT=""    # DROSTE_CONFIG assignments found OUTSIDE our block

# Quote for a shell line, and only when it needs it: an ordinary path reads
# better bare, and anything else is single-quoted with embedded quotes spliced
# the POSIX way ('\'').
sh_quote() {   # text → the same text, safe to paste into a shell line
  if [[ -z $1 || $1 == *[!A-Za-z0-9_./:+@%-]* ]]; then
    printf "'%s'" "${1//\'/\'\\\'\'}"
  else
    printf '%s' "$1"
  fi
}

shrc_target() {   # → SHRC_FILE (spelled), SHRC_GUESSED
  local sh=${SHELL:-} rc="" login=""
  SHRC_GUESSED=0
  # shellcheck disable=SC2088  # LITERAL ~, resolved by fs_path at use
  case "${sh##*/}" in
    bash)    rc='~/.bashrc'; login='~/.profile'  ;;
    zsh)     rc='~/.zshrc';  login='~/.zprofile' ;;
    sh|dash) login='~/.profile' ;;
    *)       login='~/.profile'; SHRC_GUESSED=1 ;;
  esac
  if [[ -n $rc && -f $(fs_path "$rc") ]]; then SHRC_FILE=$rc
  else SHRC_FILE=$login; fi
  return 0
}

# The exact line — produced ONCE, so what is shown and what is written cannot
# disagree. ⚠️ A `~` CANNOT BE BOTH EXPANDED AND SAFE IN A SHELL FILE (a quoted
# tilde does not expand; a bare one cannot carry a space), so a home-relative
# answer is written as "$HOME" plus its tail. That is not the ini rule's
# forbidden `$VAR in a volume= source`: podman expands nothing and a shell
# startup file expands everything, and this spelling FOLLOWS A MOVED HOME, which
# is what the stored spelling was promising in the first place.
shrc_export_line() {   # spelled config root → the export line
  local p=$1
  # shellcheck disable=SC2088  # matching a LITERAL leading ~ is the point
  case "$p" in
    "~")   printf 'export DROSTE_CONFIG="$HOME"' ;;
    "~/"*) printf 'export DROSTE_CONFIG="$HOME"/%s' "$(sh_quote "${p#\~/}")" ;;
    *)     printf 'export DROSTE_CONFIG=%s' "$(sh_quote "$p")" ;;
  esac
}

# ONE PASS, and it answers every question the offer needs: what is outside our
# block (so an update can put it back byte for byte), whether the block is
# whole, and whether the user has a DROSTE_CONFIG line of their own.
# ⚠️ It sets globals rather than printing, deliberately: a `$( )` around it would
# put the counters in a subshell and lose them, and then three separate reads of
# one file would have to agree with each other.
shrc_scan() {   # resolved file → SHRC_KEEP / SHRC_NB / SHRC_NE / SHRC_CONFLICT
  local line inblock=0
  SHRC_KEEP="" SHRC_NB=0 SHRC_NE=0 SHRC_CONFLICT=""
  [[ -f $1 ]] || return 0
  # `|| [[ -n $line ]]` so a final line with no newline is still seen; it comes
  # back with one, which is the only byte this ever normalizes.
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == "$SHRC_BEGIN" ]]; then SHRC_NB=$((SHRC_NB + 1)); inblock=1; continue; fi
    if [[ $line == "$SHRC_END" ]];   then SHRC_NE=$((SHRC_NE + 1)); inblock=0; continue; fi
    if [[ $inblock -eq 0 ]]; then
      # A commented-out line is not an assignment: the pattern is anchored, so
      # `#export DROSTE_CONFIG=…` does not match and is not reported as theirs.
      if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?DROSTE_CONFIG= ]]; then
        SHRC_CONFLICT+="$line"$'\n'
      fi
      SHRC_KEEP+="$line"$'\n'
    fi
  done < "$1"
  return 0
}

shrc_write() {   # spelled resolved line → 0 when the file now carries the block
  local spelled=$1 real=$2 line=$3
  # 🚨 EVERY MUTATION BELOW THIS GUARD, AND THE ORDERING IS THE CLAIM
  # check-installer-dryrun.sh CHECKS. dry::skip rather than dry::fs for exactly
  # the reason dryrun.sh gives for it: the write IS this function — a rebuild
  # and a redirect, with no single command a wrapper could stand in front of.
  # Same shape as emit_ini, write_notes and the .cfg merge.
  dry::skip "add the DROSTE_CONFIG export to $spelled" && return 0
  if [[ $SHRC_NB -eq 1 ]]; then
    # UPDATE. Composed in full and written in one redirect; the user's lines
    # come back exactly as they were read.
    {
      printf '%s' "$SHRC_KEEP"
      printf '%s\n%s\n%s\n' "$SHRC_BEGIN" "$line" "$SHRC_END"
    } > "$real" || return 1
  else
    # APPEND — the first-run case, which never rewrites a single existing byte.
    if [[ -s $real ]]; then
      # A file that does not end in a newline would otherwise have our marker
      # glued onto its last line; the blank line is separation, either way.
      if [[ $(tail -c1 -- "$real"; printf x) != $'\n'x ]]; then printf '\n' >> "$real"; fi
      printf '\n' >> "$real" || return 1
    fi
    printf '%s\n%s\n%s\n' "$SHRC_BEGIN" "$line" "$SHRC_END" >> "$real" || return 1
  fi
  return 0
}

# ⚠️ THIS IS NOT step_log_root's TEST, AND THE DIFFERENCE IS THE WHOLE POINT OF
# HAVING TWO. That one asks "does the config root lie WITHIN the XDG config
# tree" — a question about what KIND of directory this is, because it is deciding
# where droste's own logs belong. This one asks "would the NEXT run find this
# root by itself" — so it compares, for EQUALITY, against what factory_root
# offers RIGHT NOW, environment and all. A user whose $DROSTE_CONFIG or
# $XDG_CONFIG_HOME already names this directory is not asked to write an export
# that would only repeat what their environment says; a user who TYPED a path
# that nothing in the environment names is.
# ⭐ Same input, two honest answers, because they are two different questions.
# Collapsing them would silently break one of the two — and the two now differ in
# their COMPARISON as well as their subject (within vs. equals), so a helper
# shared between them could not serve both.
# 📐 MEASURED, on one configuration: $DROSTE_CONFIG=/srv/cfg sends the step logs
# to /srv/cfg/sys_logs (that root is outside the XDG config tree) while this
# predicate stays SILENT (the environment already names it, so the next run finds
# it). One input, two opposite and correct answers.
config_root_needs_export() {   # → 0 when a later run would NOT find this root
  [[ -n ${EMIT_DIR:-} ]] || return 1
  # 🚨 A SET DROSTE_CONFIG SILENCES THE OFFER OUTRIGHT (Jei, s83: "We should only
  # ask this if DROSTE_CONFIG was not set at the beginning"). The equality test
  # below already covered the ordinary case — factory_root returns $DROSTE_CONFIG
  # when it has a value, so a pinned root equals itself and nothing is asked.
  # ⭐ SIMPLER SINCE s87: a pinned root is CREATED, never declined, so the set
  # case always means the run's root IS the variable's root — the struck paragraph
  # below described the one branch where they parted, and that branch is gone.
  # (Struck, not deleted, because the s83 ruling it records still stands.)
  # ── [STRUCK s87] ~~but it left ONE branch asking: DROSTE_CONFIG names a
  # directory, the user DECLINES to create it, and the fall-through prompt takes
  # a different path. There the typed root differs from the variable, so the old
  # test said "they would not find this next time" and offered to write an
  # export.~~
  # ⭐ HIS RULE IS THE SAFER READING AND IT IS ALSO SIMPLER: a user whose
  # environment already names a config root has an answer to this question, and
  # ours would contradict theirs. Silence is not a degraded outcome — it is
  # declining to overrule a decision made outside this run.
  # ⚠️ THE ACCEPTED COST, stated so nobody rediscovers it as a bug: an unusable
  # pinned root ENDS THE RUN. A mistyped DROSTE_CONFIG costs a fix-and-rerun
  # rather than a mid-run correction — weighed against silently continuing
  # somewhere the environment did not name, and the silence lost.
  # 📐 NO FLAG IS KEPT FOR "at the beginning" ON PURPOSE — nothing in this
  # installer ever assigns DROSTE_CONFIG (measured s83: the only occurrences are
  # text we PRINT and a pattern we MATCH), so reading it here reads the value the
  # run started with. A captured copy would be a second source for one fact.
  # ⚠️ BLANK IS ABSENT, as everywhere else: DROSTE_CONFIG= asks the question.
  [[ -n ${DROSTE_CONFIG:-} ]] && return 1
  ! same_dir "$EMIT_DIR" "$(factory_root config)"
}

offer_config_export() {
  local spelled real line cline
  # ⭐ THE OFFER ONLY EXISTS BECAUSE THE ANSWER IS NOT DISCOVERABLE. A config
  # root the next run computes for itself needs no export, so there is nothing to
  # remember and nothing to ask — no question, no screen, no note.
  config_root_needs_export || return 0

  shrc_target
  spelled=$SHRC_FILE
  real=$(fs_path "$spelled")
  line=$(shrc_export_line "$EMIT_DIR")
  shrc_scan "$real"

  section "Remembering Your Config Path"
  # ⚠️ NAMES ONLY THE TOOL THAT EXISTS. The reader this really buys is the
  # standalone settings tool ruled in s82, and it has not shipped; a screen that
  # tells a user to run something that is not there is its own small defect.
  prose "Your config path is not the one droste looks in by default, so a later\
 droste-setup.sh run will not find it unless DROSTE_CONFIG is set in the\
 environment. This can record it in a shell startup file for you." \
    "$C_QTXT"

  # 🚨 NEVER SILENTLY OVERRIDE THE USER'S OWN LINE. A DROSTE_CONFIG assignment
  # outside our markers is theirs, whatever it says, so this refuses and NAMES
  # it rather than adding a second one further down the file — where ours would
  # win by position while the user was reading the line above it.
  # ⚠️ IT DOES NOT TRY TO DECIDE WHETHER THEIR LINE AGREES WITH THIS RUN.
  # Working out what a shell assignment evaluates to means guessing at quoting,
  # expansion and whatever ran before it, and a wrong guess here writes into a
  # file we do not own. The line is printed instead, beside the one this run
  # would have written, so the person who wrote it can see both.
  if [[ -n $SHRC_CONFLICT ]]; then
    say ""
    prose "$spelled already sets DROSTE_CONFIG itself, so nothing was written $EMD that line is yours:" "$C_NOTB"
    while IFS= read -r cline; do
      [[ -n $cline ]] || continue
      printf '    %s%s%s\n' "$C_CMD" "$cline" "$RESET"
    done <<<"$SHRC_CONFLICT"
    prose "Edit it by hand if you want this run's path instead:" "$C_TEXT"
    printf '    %s%s%s\n' "$C_CMD" "$line" "$RESET"
    say ""
    return 0
  fi
  # Our own markers, not in the shape we write them. Reported, never repaired.
  if [[ $SHRC_NB -ne $SHRC_NE || $SHRC_NB -gt 1 ]]; then
    say ""
    prose "$spelled carries a droste-setup block that is not in the shape this installer writes, so nothing was written. Tidy these two marker lines by hand and re-run:" "$C_NOTB"
    printf '    %s%s%s\n' "$C_QTXT" "$SHRC_BEGIN" "$RESET"
    printf '    %s%s%s\n' "$C_QTXT" "$SHRC_END" "$RESET"
    say ""
    return 0
  fi

  if [[ $SHRC_GUESSED -eq 1 ]]; then
    prose "\$SHELL does not name a shell this installer knows, so the file below is the portable choice $EMD check that your shell actually reads it." "$C_NOTB"
  fi
  say ""
  printf '  %sFile:%s %s%s%s\n' "$C_TEXT" "$RESET" "$C_FILE" "$spelled" "$RESET"
  printf '  %s%s:%s\n' "$C_TEXT" "$([[ $SHRC_NB -eq 1 ]] && printf 'Replacing its droste-setup block with' || printf 'Lines to add')" "$RESET"
  printf '    %s%s%s\n' "$C_QTXT" "$SHRC_BEGIN" "$RESET"
  printf '    %s%s%s\n' "$C_CMD" "$line" "$RESET"
  printf '    %s%s%s\n' "$C_QTXT" "$SHRC_END" "$RESET"
  say ""
  ask_yn "Write those three lines to $spelled" Y
  if [[ $ANS_YN -ne 1 ]]; then
    # ⭐ DECLINING IS A SUPPORTED OUTCOME AND SAYS SO. Silence after a "no" reads
    # as a failure; this says what the user owns instead.
    subnote "Not written $EMD set DROSTE_CONFIG yourself before your next run."
    return 0
  fi
  if ! shrc_write "$spelled" "$real" "$line"; then
    prose "Could not write $spelled $EMD add the three lines above by hand." "$C_NOTB"
    say ""
    return 0
  fi
  # The WOULD DO line dry::skip has already printed is the whole report in a dry
  # run; a "Written." beside it would claim both.
  dry::on && return 0
  # 🚨 SAY THAT IT DOES NOT REACH THIS SHELL. Without this line the next
  # droste-settings.sh run in the SAME terminal reads DROSTE_CONFIG as unset and
  # the user concludes the write silently failed.
  # ⚠️ prose(), not subnote(): subnote does not fold, and this sentence is the
  # one that must be read.
  subnote "Written to $spelled."
  prose "It does NOT affect the shell you are in now $EMD open a new one, or run that export line, before your next droste command." "$C_NOTB"
  say ""
  return 0
}
