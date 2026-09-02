# ── Where the two host roots live ────────────────────────────────────────────
# Both are settled up front in General Setup; the old "would you like this
# pattern applied to everything?" follow-up (PATTERN_ROOT) is retired with it.
DEFAULT_ROOT=""  # emit dir (default ~/droste)

# Base path for the PERSISTENT DATA family (the box's /opt/data, with
# input/output/workspace nested inside it) and for the PROGRAM CACHE family
# (venv, tmp, slots, kv-disk — everything the installer may wipe). The compute
# and HuggingFace caches are deliberately in neither: they are shared by every
# box, keyed by content, and were asked separately.
DATA_ROOT=""     # "" = <resource path>/data
DATA_AUTO=0      # 1 = every box's data dir is <base>/<box>, never asked
PCACHE_ROOT=""   # "" = <resource path>/caches
PCACHE_AUTO=0    # 1 = every box's program-cache dir is <base>/<box>, never asked
PORTS_DEFAULT=0  # 1 = every box takes the default host port, never asked
SERVE_MODE=n     # y|n|c — serve at box start, install-wide (c = ask per box)
HOST_MODE=n      # y|n|c — start at host boot, install-wide (c = ask per box)
CLEAR_STALE_ALL=0  # 1 = stale program caches are cleared for every box, never asked

data_root()   { printf '%s' "${DATA_ROOT:-$DEFAULT_ROOT/data}"; }
pcache_root() { printf '%s' "${PCACHE_ROOT:-$DEFAULT_ROOT/caches}"; }

# 1 when this label needs no question (General Setup already placed it).
# input/output/workspace nest INSIDE the box's data dir (Jei s38 K), so they
# ride on the data answer and are never asked on their own.
auto_label() {  # label
  if [[ $1 == pcache ]]; then [[ $PCACHE_AUTO -eq 1 ]]; else [[ $DATA_AUTO -eq 1 ]]; fi
}

# Where General Setup's roots PUT this label. Deliberately ignores a modify
# box's recorded path: the recorded value's job is to SEED the General Setup
# questions (family_base), not to override the answer given there. Letting it
# do both is what silently discarded a freshly typed base — the user was asked
# where the family goes, answered, and the box stayed where it was.
path_derived() {  # box label → derived path
  local box=$1 label=$2 root
  if [[ $label == pcache ]]; then
    printf '%s/%s' "$(pcache_root)" "$box"
  elif [[ $label == data ]]; then
    printf '%s/%s/%s' "$(data_root)" "$box" "$(leaf_dir data)"
  else
    # Every data-family bind hangs off THIS BOX'S DIRECTORY, as a SIBLING of the
    # others (s41: the old nesting was an oversight). That directory is the
    # PARENT of the program dir once one has been settled this run — so a
    # program path typed somewhere unexpected still takes input and output along
    # with it, which is what the old code did back when they lived inside it.
    if [[ -n "${PATHS["$box:data"]:-}" ]]; then
      root=${PATHS["$box:data"]%/*}
    else
      root=$(data_root)/$box
    fi
    printf '%s/%s' "$root" "$label"
  fi
}

# The DEFAULT a per-box prompt offers: a modify box's recorded path, else the
# derived placement. Only ever a prompt default — an auto-placed family takes
# path_derived instead, so an answer always beats a memory.
#
# Both branches hand back a spelling somebody chose: the recorded branch the
# user's own, the derived one the resource path's (path_derived hangs the box
# off a root that was itself typed or accepted). Nothing here needs a display
# conversion, and nothing here may be handed to the filesystem without fs_path.
path_default() {  # box label → default path (existing value > family base)
  local box=$1 label=$2
  if [[ ${ACTION[$box]} == modify && -n "${EXD_PATH["$box:$label"]:-}" ]]; then
    printf '%s' "${EXD_PATH["$box:$label"]}"
    return 0
  fi
  path_derived "$box" "$label"
}

# Which labels of a box ended up on an overlay-hostile filesystem, and the
# filesystem that triggered it (both feed the mitigation line under the box).
declare -A MIT_LABELS MIT_FS

# Settle ONE bind path of a box: pick it (automated, pattern-filled, or asked),
# make sure it exists, and answer its filesystem question. Sets PATHS[box:label]
# — plus CFG_FS/CFG_MODE when the label is the data dir, since /opt/data is the
# bind the in-box overlay is actually built on.
# $3 forces the PROMPT even for an auto-placed family. Its one caller is
# relocate_box's [c]hange, which is by ruling "the ordinary single-path settle
# route" and not a bespoke re-ask — so it re-enters this function rather than
# growing a second asker beside it.
set_bind_path() {  # box label [force-prompt]
  local box=$1 label=$2 def rc force=${3:-0}
  while :; do
    def=$(path_default "$box" "$label")
    if [[ $force -eq 0 ]] && auto_label "$label"; then
      # General Setup placed this family, and the answer given THERE wins — a
      # recorded path seeded that question, it does not get to overrule it.
      # (path_derived, not $def: $def is the per-box PROMPT default, which is
      # the recorded value on a modify box and would pin the box in place.)
      ANS_PATH=$(path_derived "$box" "$label")
      # Not created here when the move pass is going to offer to fill it: the
      # move creates what it needs, and a declined one leaves nothing behind.
      # Nor while a [c]hange is re-deriving the box's other binds: that path may
      # be abandoned by the very next answer, and relocate_box makes what is
      # left standing once the rounds are over.
      if [[ $RELOC_NO_CREATE -eq 0 ]] && ! relocatable "$box" "$label" "$ANS_PATH"; then
        ensure_dir "$ANS_PATH" || :
      fi
    else
      # No per-bind header: the prompt itself names the box + bind family —
      # unless the family writes its own prompt (BIND_PROMPT), which is how the
      # program-cache question gets its own wording without a second asker.
      #
      # ask_path_as is unrolled here for ONE reason: a path the move pass is
      # about to fill must not be confirmed into existence first. "Create
      # <path>?" exists so nothing is made silently — but this one is not
      # silent, it is named in the move question three lines further on, and
      # creating it before that question is asked leaves an empty directory
      # behind for a path the box does not use when the answer is no.
      while :; do
        ask_path_as_raw \
          "${BIND_PROMPT[$label]:-Path for ${BOX_NAME[$box]} ${BIND_TITLE[$label],,}}" "$def"
        relocatable "$box" "$label" "$ANS_PATH" && break
        ensure_dir "$ANS_PATH" && break
      done
    fi
    PATHS["$box:$label"]=$ANS_PATH
    # Modify with the SAME path keeps the mitigation already recorded for it
    # (re-prompts default to current values); a changed path is re-decided.
    # "The SAME path" is a question about DIRECTORIES, so it is asked with
    # same_dir: answering ~/appdata/comfyui where the ini said
    # /home/you/appdata/comfyui has not moved anything and must not re-open the
    # filesystem question.
    if [[ $label == data && ${ACTION[$box]} == modify && -n "${EXD_MODE[$box]:-}" ]] \
       && same_dir "$ANS_PATH" "${EXD_PATH["$box:data"]:-}"; then
      probe_fstype "$ANS_PATH"
      CFG_FS[$box]=$FSTYPE
      if overlay_hostile_fs "$FSTYPE"; then
        CFG_MODE[$box]=${EXD_MODE[$box]}
        MIT_LABELS[$box]="${MIT_LABELS[$box]:-} $label"
        MIT_FS[$box]=$FSTYPE
      fi
      return 0
    fi
    rc=0
    mitigate_path "$ANS_PATH" nested || rc=$?
    if [[ $rc -eq 2 ]]; then
      # "new path": this one gets asked explicitly, whatever settled it before.
      force=1
      continue
    fi
    break
  done
  [[ $label == data ]] && CFG_FS[$box]=$FSTYPE
  if [[ -n $MIT_MODE ]]; then
    [[ $label == data ]] && CFG_MODE[$box]=$MIT_MODE
    # ONE overlay mode per box (P0 choice C). The venv upper lives on the
    # PROGRAM-CACHE root now, so that root has to accept an overlay upper in its
    # own right: a hostile one sets the box's mode when the data dir did not
    # (the data dir, which carries comfyui's custom_nodes upper, still wins when
    # both objected — the two answers are the same menu answer anyway).
    #
    # It contributes no CATEGORY to the mitigation line: that sentence names the
    # binds the user was asked about by name ("using fuse for data, input, &
    # output"), and both s37/s38 mocks keep it to the data family, cache root
    # asked or not. Hence no MIT_LABELS/MIT_FS entry here — those two feed the
    # sentence and nothing else.
    if [[ $label == pcache ]]; then
      # `if`, not `[[ … ]] &&`: a false test as the last command of a branch is
      # the status of the whole compound, and this script runs under `set -e`.
      if [[ -z ${CFG_MODE[$box]:-} ]]; then CFG_MODE[$box]=$MIT_MODE; fi
    else
      MIT_LABELS[$box]="${MIT_LABELS[$box]:-} $label"
      MIT_FS[$box]=$FSTYPE
    fi
  elif [[ $label == data ]]; then
    CFG_MODE[$box]=""
  fi
  # A program cache that just moved leaves a directory behind. Asked HERE, not
  # in the box's move pass: caches are never offered a move (they regenerate),
  # so the only question they raise is what to do with the old directory — and
  # it is asked about the path this answer settled on, typed or derived alike.
  if [[ $label == pcache ]]; then relocate_pcache "$box" "$ANS_PATH"; fi
  return 0
}

# ── Stale program caches ─────────────────────────────────────────────────────
# A box's program-cache dir holds nothing but disposables: the venv upper and
# its work dir, tmp, slots, kv-disk, the seeded extra_model_paths.yaml, the
# serve pid. Nothing in it is authored and nothing in it is data — the taxonomy
# classifies BY LOCATION, which is exactly what makes this test cheap and
# honest: anything in there at all is a previous generation's leftovers, and an
# old stack layered under a new image is the failure that never names itself.
#
# SCOPE, ruled (Jei s38 D): the NEW layout only. An old-layout data/<box>/venv
# is not tested for — "not worth the complexity" — and is covered by the docs
# line naming the old paths safe to delete by hand. Compute caches are never
# tested and never cleared: they are content-keyed and shared by every box.
stale_pcache() { dir_has_content "$1"; }

# Is there anything in this directory at all? Dotfiles count — `.work` is the
# overlay bookkeeping and is exactly the kind of leftover the cache question is
# about, and a data dir holding nothing but a `.gitkeep` is still a data dir
# with something in it. A missing directory is not "empty": there is nothing
# there to clear and nothing there to move.
dir_has_content() {  # dir → 0 when it exists and holds anything at all
  local d=$1 p
  [[ -n $d ]] || return 1
  d=$(fs_path "$d")
  [[ -d $d ]] || return 1
  for p in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    [[ -e $p || -L $p ]] && return 0
  done
  return 1
}

# Does ANY box this run is about to configure have one? Asked at the path each
# box would take by default, since this runs before the per-box path questions;
# a box that is being KEPT is frozen and is not asked about here or anywhere.
stale_any() {
  local box
  for box in ${CONFIGURE[@]+"${CONFIGURE[@]}"}; do
    stale_pcache "$(path_default "$box" pcache)" && return 0
  done
  return 1
}

# A directory is cleared ONLY if it is this box's caches and nothing else. The
# answer to a question about caches is not consent to empty whatever else is at
# that path, and the one way the two can meet is a typed path: the prompt takes
# any directory, including the one the box keeps its DATA in. Everything this
# run has placed somewhere is checked by name — the two roots, the resource
# dir, the three shared paths, and every other bind of every box (another box's
# cache dir is not excluded: clearing a shared cache dir is what both of its
# answers asked for). $HOME and / are refused outright.
#
# EVERY COMPARISON HERE IS same_dir, NOT ==: two spellings of one directory are
# one directory, and a guard that only recognises its own spelling of a path is
# a guard that can be walked around by writing ~ instead of /home/you.
pcache_wipe_safe() {  # dir → 0 when nothing else in this install is that dir
  local dir=$1 key
  case "$(fs_path "$dir")" in /|"$HOME") return 1 ;; esac
  same_dir "$dir" "$EMIT_DIR" && return 1
  same_dir "$dir" "$(data_root)" && return 1
  same_dir "$dir" "$(pcache_root)" && return 1
  [[ -n $COMPUTE_CACHE ]] && same_dir "$dir" "$COMPUTE_CACHE" && return 1
  [[ -n $HF_CACHE ]] && same_dir "$dir" "$HF_CACHE" && return 1
  [[ -n $MODELS_DIR ]] && same_dir "$dir" "$MODELS_DIR" && return 1
  for key in "${!PATHS[@]}"; do
    [[ ${key##*:} == pcache ]] && continue
    same_dir "${PATHS[$key]}" "$dir" && return 1
  done
  return 0
}

# The test both halves of the consent share: this box has something stale, and
# clearing it would clear only caches. A path that fails the second half is
# reported once and then left out of the offer entirely — asking about it would
# be asking about the wrong directory.
stale_clearable() {  # box → 0 when the box has stale caches this may clear
  local box=$1
  local dir=${PATHS["$box:pcache"]:-}
  stale_pcache "$dir" || return 1
  pcache_wipe_safe "$dir" && return 0
  warn "$dir holds more than ${BOX_NAME[$box]}'s caches $EMD left alone"
  return 1
}

# Empty ONE box's program-cache dir: its CONTENTS, never the directory itself,
# and never a byte outside it — not the box's data, not the shared compute
# caches, not the HF cache. Silent on success (the summary box follows it
# immediately in the mock); the two ways it does NOT happen are reported.
#
# A RUNNING box is left alone: the venv upper is mounted under this dir,
# emptying it out from under the mount repairs nothing, and the box has to be
# restarted for any fix to take anyway.
clear_pcache() {  # box
  local box=$1
  local dir=${PATHS["$box:pcache"]:-} p real
  stale_clearable "$box" || return 0
  if [[ $(box_state "$box") == ACTIVE ]]; then
    subnote "$(box_ctr "$box") is running $EMD stop it, then re-run to clear its caches."
    return 0
  fi
  real=$(fs_path "$dir")
  for p in "$real"/* "$real"/.[!.]* "$real"/..?*; do
    [[ -e $p || -L $p ]] || continue
    rm -rf "$p" && continue
    warn "could not clear $dir $EMD empty it by hand, then re-run"
    return 0
  done
  return 0
}

# The per-box half of the consent. It is asked ONLY when the install-wide
# question did not already settle it AND this box actually has something stale
# at the path it just settled on — which is why it can fire even when the
# install-wide question never appeared: a path typed here may hold leftovers
# the default path did not. Nothing is ever cleared without one of the two
# answers, and the wipe happens the moment consent is given (s36 precedent),
# while the path it applies to is the one on screen.
stale_cache_offer() {  # box
  local box=$1
  stale_clearable "$box" || return 0
  if [[ $CLEAR_STALE_ALL -eq 0 ]]; then
    ask_yn_caution "Stale caches cause unpredictable behavior." "Clear stale caches" Y
    [[ $ANS_YN -eq 1 ]] || return 0
  fi
  clear_pcache "$box"
  return 0
}

# ── Moving existing data to a chosen base ────────────────────────────────────
# THE DEFECT THIS CLOSES (Jei, s40 Loaf run): answering YES to "store persistent
# data at a common base path" re-pointed every box's ini at <base>/<box> and
# LEFT THE BYTES WHERE THEY WERE, so the box came up bound to an empty
# directory, with nothing said. "Don't do what is being done and (somehow)
# ignore what the user says." — Jei. That the ANSWER WINS is s39's F8 fix; this
# is what happens to the data once it does.
#
# THE MOVER IS `mv` ITSELF, AND ITS BEHAVIOUR AND ITS ERRORS ARE OURS (Jei,
# s41): "mv copies across boundaries and removes the old. We should do the same,
# unless we know in advance that it will fail." coreutils already does
# rename(2), falls back to copy+unlink on EXDEV, preserves mode and timestamps,
# and leaves the SOURCE INTACT when a copy dies partway. So nothing here
# hand-rolls copy-verify-delete, and nothing here paraphrases what mv says: a
# refusal is printed in mv's own words.
#
# ⚠️ -T IS MANDATORY on every call: plain `mv src dst` onto an EXISTING
# directory moves src INSIDE it, which would silently produce <base>/<box>/<box>
# and then read as the user's own mistake.
#
# MEASURED (coreutils 9.7), because the whole flow is shaped by it:
#   dst missing            rename
#   dst an EMPTY dir       rename (mv rmdir's it first) — same across devices
#   dst a NON-EMPTY dir    REFUSED, both same-device ("cannot overwrite 'x':
#                          Directory not empty") and cross-device ("inter-device
#                          move failed: …; unable to remove target: …")
#   file onto file         overwritten, silently
#   dir onto file, or      REFUSED ("cannot overwrite non-directory 'x' with
#   file onto dir          directory 'y'", and its mirror)
#   dst a SYMLINK to a dir REFUSED — it is not a directory to mv
# The third line is why a non-empty destination has to be ASKED about rather
# than handed to mv, and the fourth is why "merge" means what it means below.

# KB → the shortest string that still says which order of magnitude it is.
hsize() {  # kb → "18K" | "4.2M" | "1.4G"
  local kb=$1 u=0 v=$1 t div=1
  local -a units=(K M G T P)
  [[ $kb =~ ^[0-9]+$ ]] || { printf '?'; return 0; }
  while [[ $v -ge 1024 && $u -lt 4 ]]; do
    v=$((v / 1024)); div=$((div * 1024)); u=$((u + 1))
  done
  if [[ $u -eq 0 ]]; then printf '%s%s' "$v" "${units[0]}"; return 0; fi
  # One decimal, taken at the chosen scale rather than from the truncated value
  # (1.4G, not 1G, when the difference is the point of printing it) and ROUNDED
  # rather than cut: these numbers are read side by side in the won't-fit
  # sentence, and 1.0G of free space against a 1.1G requirement is a sentence
  # the reader would have to be told twice.
  t=$(( (kb * 10 + div / 2) / div ))
  printf '%s.%s%s' "$((t / 10))" "$((t % 10))" "${units[$u]}"
}

dir_kb() {  # dir → size in KB (0 when it cannot be measured)
  local out kb
  out=$(du -sk -- "$(fs_path "$1")" 2>/dev/null) || out=""
  kb=${out%%[!0-9]*}
  [[ -n $kb ]] || kb=0
  printf '%s' "$kb"
}

# The closest ancestor that EXISTS — what a question about a not-yet-created
# destination is really asking about (which filesystem, and how much room).
nearest_existing() {  # resolved path → resolved path
  local d=$1
  while [[ ! -e $d && $d != / ]]; do d=$(dirname -- "$d"); done
  printf '%s' "$d"
}

avail_kb() {  # dir → KB free where it lives ("" when it cannot be measured)
  local d out fs blocks used avail
  d=$(nearest_existing "$(fs_path "$1")")
  # -P: POSIX output, one line per filesystem. Without it a long device name
  # wraps onto a second line and the field this reads is not there.
  out=$(df -Pk -- "$d" 2>/dev/null | tail -n1) || return 1
  read -r fs blocks used avail _ <<<"$out" || return 1
  : "$fs $blocks $used"
  [[ $avail =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$avail"
  return 0
}

# Would this be a rename or a copy? st_dev is what rename(2) itself compares, so
# this answers the same question the kernel will. UNKNOWABLE COUNTS AS CROSSING:
# a failed probe leads to the honest question ("this has to be copied") instead
# of a silent assumption that it will be instant.
same_device() {  # a b → 0 when both live on one filesystem
  local x y
  x=$(stat -c %d -- "$(nearest_existing "$(fs_path "$1")")" 2>/dev/null) || return 1
  y=$(stat -c %d -- "$(nearest_existing "$(fs_path "$2")")" 2>/dev/null) || return 1
  [[ $x == "$y" ]]
}

MV_ERR=""
run_mv() {  # src dst → 0 on success; MV_ERR = mv's own message
  local src dst
  src=$(fs_path "$1") dst=$(fs_path "$2")
  MV_ERR=""
  if MV_ERR=$(mv -T -- "$src" "$dst" 2>&1); then return 0; fi
  return 1
}

# mv's own words, indented under the answer that provoked them. NOT rephrased
# and NOT prefixed with WARNING: the error the user gets is the error the tool
# gives, which is the whole of the ruling.
mv_said() {
  local line
  [[ -n $MV_ERR ]] || return 0
  while IFS= read -r line; do
    printf '  %s `-> %s%s%s\n' "$C_ARROW" "$C_TEXT" "$line" "$RESET"
  done <<<"$MV_ERR"
  printf '\n'
  return 0
}

# MERGE is per-entry `mv -T`, because that is the only merge mv has. A file
# landing on a file is overwritten silently; a directory landing on a NON-EMPTY
# directory is REFUSED and stays where it is, named. That refusal is the
# behaviour, not a gap in it (Jei, s41: same behaviours and errors as mv) — the
# alternative, recursing into the collision and unioning it, is a thing mv will
# not do and is indistinguishable from "remove data at new path" for the files
# inside.
MERGE_MOVED=0
MERGE_KEPT=0
merge_into() {  # src dst → 0 when every entry landed
  local src=$1 dst=$2 p name real
  MERGE_MOVED=0 MERGE_KEPT=0
  real=$(fs_path "$src")
  for p in "$real"/* "$real"/.[!.]* "$real"/..?*; do
    [[ -e $p || -L $p ]] || continue
    name=${p##*/}
    if run_mv "$p" "$dst/$name"; then
      MERGE_MOVED=$((MERGE_MOVED + 1))
    else
      mv_said
      MERGE_KEPT=$((MERGE_KEPT + 1))
    fi
  done
  [[ $MERGE_KEPT -eq 0 ]] || return 1
  # mv removes a source directory once it has emptied it; a per-entry merge has
  # to take that last step itself, and only when nothing was left behind.
  rmdir -- "$real" 2>/dev/null || :
  return 0
}

# Where the family this bind belongs to was placed — the base for a root, the
# box's own data dir for a leaf that nests inside it. It is the second half of
# the sentence the move question opens with, so it names the place the user just
# chose, not the one this bind is being compared against.
family_place() {  # box label → path
  case "$2" in
    data)   data_root ;;
    pcache) pcache_root ;;
    *)      printf '%s' "${PATHS["$1:data"]:-$(data_root)/$1}" ;;
  esac
}

# The one question a re-pointed PROGRAM CACHE raises. True caches are moved
# nowhere and asked about nowhere — they regenerate, and re-pointing one costs
# the user nothing (Jei) — but the directory it VACATED is still on the disk,
# so: ask before deleting it, and if a running box blocks that, say so. This is
# the s38 consent-gated clear aimed at the old path, not a parallel flow: the
# same safety test decides whether the offer may be made at all.
#
# ⚠️ The HF cache is NOT one of these (Jei: "I'm not counting huggingface
# here") — it is the model store, and it takes the ordinary data move offer.
old_pcache_offer() {  # box old-dir
  local box=$1 old=$2 real
  dir_has_content "$old" || return 0
  if ! pcache_wipe_safe "$old"; then
    warn "$old holds more than ${BOX_NAME[$box]}'s caches $EMD left alone"
    return 0
  fi
  if [[ $(box_state "$box") == ACTIVE ]]; then
    subnote "$(box_ctr "$box") is running $EMD stop it, then re-run to remove $old."
    return 0
  fi
  say ""
  prose "${BOX_NAME[$box]}'s program caches are now at $(family_place "$box" pcache)/$box $EMD $old was left behind, and holds $(hsize "$(dir_kb "$old")") of caches." "$C_QTXT"
  ask_yn "Delete the old program cache dir" Y
  [[ $ANS_YN -eq 1 ]] || return 0
  real=$(fs_path "$old")
  rm -rf -- "$real" || warn "could not delete $old $EMD remove it by hand"
  return 0
}

# Is one directory inside another? Both sides are resolved, because this decides
# what a sentence CLAIMS about the disk, not how anything is spelled.
dir_within() {  # inner outer → 0 when inner is at or below outer
  local a b
  a=$(realpath -m -- "$(fs_path "$1")" 2>/dev/null) || return 1
  b=$(realpath -m -- "$(fs_path "$2")" 2>/dev/null) || return 1
  [[ $a == "$b" || $a == "$b"/* ]]
}

# A program cache that moved: no offer, no question about the DATA (it
# regenerates), only the one about the directory it vacated.
#
# ⭐ NO ACTION TEST (Jei s42, and the same reasoning as `relocatable`'s). s42
# dropped that gate from `relocatable` and `relocate_box` so a recreate gets the
# data questions; this function kept a private copy of it, which left a RECREATE
# box that re-points its program cache silently orphaning the old cache dir —
# offered the data move, but never the clear. The record is what earns the
# question, not which of K/m/r was chosen, and `EXD_PATH` is the record: a fresh
# create has none (line below returns), a keep box re-settles on the same
# directory (same_dir returns), so dropping the test reaches recreate and
# nothing else.
#
# ⚠️ The program cache's EXEMPTION is untouched: it is still silently
# re-pointed, still asked no move question and no [U]se/[c]hange question. The
# only thing this reaches is the s38 consent-gated clear, aimed at the VACATED
# directory, and old_pcache_offer still owns both of its safety rules —
# pcache_wipe_safe (never a directory another bind of this install also uses)
# and the running-box refusal.
relocate_pcache() {  # box new
  local box=$1 new=$2 old
  old=${EXD_PATH["$box:pcache"]:-}
  [[ -n $old ]] || return 0
  same_dir "$old" "$new" && return 0
  old_pcache_offer "$box" "$old"
  return 0
}

# ── Relocating a box's data (Jei's s41 flow) ─────────────────────────────────
# ONE PASS PER BOX, after every one of its paths is settled — not one question
# per bind as they are asked. That order is what his two examples show and it is
# the only order that works for both of them: when a common base places the
# family the paths are known before anything is asked, but when the base is
# DECLINED the new paths are the answers to the per-box prompts, so the moves
# cannot be discussed until those prompts are done.
#
# The shape of the pass:
#   1. what is being asked about, disclosed as a block (two forms, below)
#   2. one move question per bind, with two levels of "do this for all"
#   3. one collision block for the destinations that are not empty, with the
#      four courses of action and its own two levels of "apply this to all"
#   4. the moves themselves
#
# THE RULE BEHIND EVERY OUTCOME: the box is pointed where its data actually IS.
# Declined, refused, failed, or "keep old path as-is" all leave PATHS holding
# the recorded path; "use the data already at the new path" is the one answer
# that takes the new path without moving a byte.
#
# ⭐ TWO INDEPENDENT QUESTIONS (Jei s42). They were welded together until s42,
# both behind one `ACTION == modify` gate:
#
#   A  a recorded path holds content and the box will now read elsewhere
#      → "move it?"   Needs a RECORD, so: recreate and modify, never a fresh
#      create.
#   B  the path the box will now READ holds content
#      → "what should happen to what is there?"   Needs only a DESTINATION, so
#      it applies to a fresh create exactly as much as to a modify.
#
# B has two forms, chosen by whether data is landing on that destination:
#
#   form 1  [M]erge / [r]emove / [u]se / [k]eep — a move was accepted onto it.
#   form 2  [U]se / [c]hange                    — nothing is moving onto it: a
#           fresh create, or a path whose move was declined.
#
# ⭐ The disclosure above the question and the two batch questions below it are
# THE SAME in both forms, and Jei notes that is not an accident — only the
# middle changes. Declining a move therefore stops meaning "keep the old path"
# unconditionally: it means "do not carry the files over", and then an empty
# destination keeps the recorded path (the s41 invariant) while a destination
# with content earns form 2.
MOVE_ALL_BOXES=""     # y|n      — "Do this for all boxes" (the move question)
COLL_ALL_BOXES=""     # m|r|u|k  — "Apply this decision to all boxes" (form 1)
USE_ALL_BOXES=""      # u|c      — "Apply this decision to all boxes" (form 2)

# Set while relocate_box re-settles the binds a [c]hange unsettled: an
# AUTO-PLACED path is derived without a question, so creating it there would
# leave an empty directory behind every time the user changes their mind again.
# The paths that survive the last round are created by relocate_box itself, once
# nothing more can move. (Same reason set_bind_path already skips a destination
# the move pass is going to fill.)
RELOC_NO_CREATE=0

# Is this bind one the move pass is going to ask about? Both callers need the
# same answer: relocate_box, to build its list, and set_bind_path, which must
# NOT create the destination for one of them — the move makes what it needs,
# and a declined move would otherwise leave an empty directory behind at a path
# the box does not even use.
#
# ⭐ NO ACTION TEST (Jei s42, ruling 3). The question this answers is "is there
# recorded data somewhere other than where the box will now read?", and that is
# a question about a RECORD, not about which of K/m/r was chosen: a RECREATE box
# has the same ini behind it and the same bytes on the disk, so it earns the
# same question. `EXD_PATH` is the record, and detect_existing fills it for
# every box before any of that is asked — a fresh create simply has none, which
# is why ruling 2 ("A never applies to a fresh create") needs no test of its own.
# The one gate that stays is path_default's: THAT test is the recreate/modify
# divergence, and it is the whole of it.
relocatable() {  # box label new → 0 when the move pass will handle it
  local box=$1 label=$2 new=$3 old
  [[ $label != pcache ]] || return 1
  old=${EXD_PATH["$box:$label"]:-}
  [[ -n $old ]] || return 1
  same_dir "$old" "$new" && return 1
  dir_has_content "$old" || return 1
  # The pre-s41 case (new path inside the old one) counts as OWNED even though
  # it cannot be moved: the pass reports it and puts the bind back on its
  # recorded path, so the destination must not be created here either.
  return 0
}

box_labels() {  # box → its data-family labels, in bind order
  local box=$1 pair
  printf 'data'
  for pair in ${BOX_EXTRA_BINDS[$box]}; do printf ' %s' "${pair%%:*}"; done
  return 0
}

# A disclosure header: bold bright white, underlined, and NO leading blank line
# — it opens a block that sits directly under the subheader above it.
disc_hdr() { printf '  %s%s%s\n' "$C_HDR" "$1" "$RESET"; }

# The "<Box> Paths" subheader, printed by whichever of the two asks first: the
# path prompts when the family was not placed, this pass when it was. Called
# more than once per box on purpose — only the first call draws anything.
paths_hdr() {  # box
  if [[ ${PATHS_HDR:-0} -eq 0 ]]; then
    subhdr "${BOX_NAME[$1]} Paths"
    PATHS_HDR=1
  else
    say ""
  fi
  return 0
}
disc_row() { printf '  %s[%s%s%s]%s\n' "$C_TBRK" "$C_DETN" "$1" "$C_TBRK" "$RESET"; }

leaf_list() {  # label... → "program, output, input"
  local out="" l
  for l in "$@"; do
    if [[ -n $out ]]; then out+=", "; fi
    out+=$(leaf_dir "$l")
  done
  printf '%s' "$out"
  return 0
}

# Do these paths all live in ONE directory? A block that can name their shared
# parent says it once and then lists bind names; otherwise every line has to
# carry its own path. Both disclosures below take this fork, which is why the
# two forms exist at all — Jei drew both.
common_parent() {  # path... → the shared parent, or ""
  local p first="" d
  for p in "$@"; do
    d=${p%/*}
    [[ -n $d ]] || d=/
    if [[ -z $first ]]; then first=$d; continue; fi
    same_dir "$d" "$first" || return 0
  done
  printf '%s' "$first"
  return 0
}

# Put a bind back on the path its ini records — and, for the data dir, back on
# the filesystem answer that path already earned, since the probe that ran
# while it was pointed somewhere else was answering a different question.
revert_path() {  # box label old
  local box=$1 label=$2 old=$3
  PATHS["$box:$label"]=$old
  [[ $label == data ]] || return 0
  probe_fstype "$old"
  CFG_FS[$box]=$FSTYPE
  if [[ -n "${EXD_MODE[$box]:-}" ]] && overlay_hostile_fs "$FSTYPE"; then
    CFG_MODE[$box]=${EXD_MODE[$box]}
  fi
  return 0
}

# One accepted move, carried out. Returns 1 when the data did not (all) get
# there, which is the caller's signal to leave the box on its old path.
move_one() {  # box label old new mode(plain|m|r) → 0 = the box may take new
  local box=$1 label=$2 old=$3 new=$4 mode=$5
  local kb avail dstreal
  : "$box $label"
  # CROSSING A DEVICE: tell them, name both sides, ask (Jei). Priced BEFORE the
  # destructive step below, so a shortfall can never be discovered once the old
  # content is already gone.
  if ! same_device "$old" "$new"; then
    kb=$(dir_kb "$old")
    avail=$(avail_kb "$new") || avail=""
    # "remove data at new path" frees what it deletes, so the room that answer
    # really has is the free space PLUS the content it is about to remove.
    # Refusing on the pre-delete figure would decline a move that fits.
    if [[ -n $avail && $mode == r ]]; then
      avail=$(( avail + $(dir_kb "$new") ))
    fi
    if [[ -n $avail && $avail -lt $kb ]]; then
      prose "$new is on another filesystem with $(hsize "$avail") free, and $old holds $(hsize "$kb") $EMD left where it is." "$C_QTXT"
      say ""
      return 1
    fi
    prose "$old and $new are on different filesystems, so $(hsize "$kb") has to be copied across rather than renamed." "$C_QTXT"
    ask_yn "Copy it across" Y
    [[ $ANS_YN -eq 1 ]] || return 1
  fi
  dstreal=$(fs_path "$new")
  # The parent has to exist for a rename to land in it; creating it is implied
  # by the move that was just accepted, and by nothing else.
  mkdir -p -- "${dstreal%/*}" 2>/dev/null || :
  case "$mode" in
    m)
      merge_into "$old" "$new" || :
      # Nothing moved at all → the data is still where it was, and so is the
      # box. Anything moved → the box follows it, and whatever mv refused is
      # named along with the directory it is still in.
      [[ $MERGE_MOVED -eq 0 ]] && return 1
      [[ $MERGE_KEPT -eq 0 ]] || subnote "the rest is still in $old"
      return 0 ;;
    r)
      # The only destructive branch. $HOME and / are refused outright, the same
      # two the cache wipe refuses, and for the same reason.
      case "$dstreal" in
        /|"$HOME") subnote "refusing to remove the data at $new"; return 1 ;;
      esac
      if ! rm -rf -- "$dstreal"; then
        warn "could not empty $new $EMD left where it is"
        return 1
      fi ;;
  esac
  # An empty (or vacated) destination takes ONE whole-directory move.
  if ! run_mv "$old" "$new"; then
    mv_said
    return 1
  fi
  return 0
}

# ⭐ RE-ENTERABLE, not a straight-line pass (Jei s42). [c]hange drops a path
# back into the ordinary settle route, and path_derived hangs every other bind
# of the box off the parent of its program dir — so changing that one path
# UNSETTLES the rest, and they have to come back round for the same questions.
# Hence rounds: a round asks about the labels in scope, and a [c]hange puts what
# it unsettled into the next round's scope. Nothing accumulates per round (the
# re-derived paths are not created until the rounds are over — RELOC_NO_CREATE),
# and nothing MOVES until they are either, because a move executed in round 1
# could be aimed at a destination round 2 walks away from.
relocate_box() {  # box
  local box=$1 label old new i n parent ans first word askall ask_use in_scope in_chg
  local ask_coll carried_dec dec_i leaf
  local box_ans="" box_coll="" box_use=""   # this box's batched answers
  local -a labels=() olds=() news=() moving=() coll=() dec=()
  local -a scope=() nextscope=() chg=() b2=() bpaths=() mkq=()
  local -A COLL_AT=()   # index → 1 for the binds whose destination has files
  # Carried ACROSS rounds, keyed by label: the move answer and the two paths it
  # is about (M_*), form 1's course of action (M_DEC), form 2's [U]se (B_NEW),
  # and which labels the user has already changed once (CHANGED — a batched
  # [c]hange must never auto-answer a path it already changed, or "apply to all"
  # becomes a loop with no way out of it).
  local -A A_MOVE=() M_OLD=() M_NEW=() M_DEC=() B_NEW=() CHANGED=()
  local ask_moves=1
  for label in $(box_labels "$box"); do scope+=("$label"); done

 while [[ ${#scope[@]} -gt 0 ]]; do
  labels=() olds=() news=() moving=() coll=() dec=() b2=() nextscope=() COLL_AT=()
  # Which binds have their files somewhere other than where the box will now
  # read them from? Spelling never decides this: ~/appdata/comfyui and
  # /home/you/appdata/comfyui are one directory.
  for label in "${scope[@]}"; do
    old=${EXD_PATH["$box:$label"]:-}
    new=${PATHS["$box:$label"]:-}
    [[ -n $old && -n $new ]] || continue
    # THE PRE-s41 LAYOUT WALKS INTO THIS: a box whose data dir IS <base>/<box>
    # derives <base>/<box>/program, which is INSIDE it — and `mv` refuses to
    # move a directory into its own subdirectory (measured: "cannot move 'x' to
    # a subdirectory of itself"). Reported BEFORE any question, because the only
    # answer a question here could earn is an error message. What it actually
    # needs is a per-entry move that steps around the box's other binds, and
    # Jei ruled that out of scope: "I can manually fix my boxes."
    relocatable "$box" "$label" "$new" || continue
    if dir_within "$new" "$old"; then
      subnote "$new is inside $old $EMD left as it is (move it by hand to split them)."
      revert_path "$box" "$label" "$old"
      continue
    fi
    labels+=("$label") olds+=("$old") news+=("$new")
  done
  n=${#labels[@]}
  # A RUNNING box is refused with the reason — "same as cache" (Jei) — once, for
  # the whole box. Its data is under a live mount, and every fix needs the box
  # restarted anyway. Asked only when there is something to move: question B
  # moves no bytes, so a running box is no reason to withhold it.
  if [[ $n -gt 0 ]] && [[ $(box_state "$box") == ACTIVE ]]; then
    subnote "$(box_ctr "$box") is running $EMD stop it, then re-run to move its data."
    for (( i = 0; i < n; i = i + 1 )); do revert_path "$box" "${labels[i]}" "${olds[i]}"; done
    return 0
  fi

  # ── 1. Where those files are now ──────────────────────────────────────────
  # A box whose answer was settled by an earlier "Do this for all boxes" is
  # asked NOTHING here, and everything that block exists for goes with the
  # question: disclosing where the files are and explaining that a move is
  # needed are both setups for a decision this box does not get to make (Jei:
  # "if we are skipping because it's already answered, we really shouldn't be
  # showing any of that; it all becomes irrelevant"). What survives is a
  # RECEIPT — one line per bind, naming what moved and where — printed after
  # the questions that would have been asked, further down.
  # box_ans joins MOVE_ALL_BOXES here for the same reason and by the same rule:
  # in a LATER round (a [c]hange re-settled something) the box-wide batch has
  # already answered for whatever came back round, so the disclosure and the
  # sentence above it are setups for a question that will not be asked. It is
  # always empty on the first round, where this reads exactly as it always did.
  ask_moves=1
  [[ -z $MOVE_ALL_BOXES && -z $box_ans ]] || ask_moves=0
  if [[ $n -gt 0 && $ask_moves -eq 1 ]]; then
    paths_hdr "$box"
    parent=$(common_parent "${olds[@]}")
    if [[ -n $parent ]]; then
      disc_hdr "Current data file paths in $parent:"
      disc_row "$(leaf_list "${labels[@]}")"
    else
      disc_hdr "Current data file paths:"
      for (( i = 0; i < n; i = i + 1 )); do
        disc_row "$box $(leaf_word "${labels[i]}"): ${olds[i]}"
      done
    fi
    say ""
    prose "To use current, active data with new path(s), that data will need to be moved." "$C_QTXT"
  fi

  # ── 2. The move questions ─────────────────────────────────────────────────
  # The two batch questions are offered ONCE, straight after the first answer,
  # and they carry THAT answer — yes or no alike (Jei: "even a 'no' above
  # propagates"). "all boxes" is only reached when the box-wide one was taken.
  for (( i = 0; i < n; i = i + 1 )); do
    if [[ -n $box_ans ]]; then moving+=("$box_ans"); continue; fi
    if [[ -n $MOVE_ALL_BOXES ]]; then moving+=("$MOVE_ALL_BOXES"); continue; fi
    ask_yn "Move $(leaf_word "${labels[i]}") to new path (${news[i]})" Y
    ans=$ANS_YN
    moving+=("$ans")
    [[ $i -eq 0 ]] || continue
    if [[ $n -gt 1 ]]; then
      # A box with ONE data path has nothing to apply this to, so it is not
      # asked — the all-boxes question below is offered on its own instead.
      ask_yn "Do this for $(emphc "$C_EMPTH" "all data paths") for $box" Y
      [[ $ANS_YN -eq 1 ]] || continue
      box_ans=$ans
    fi
    # Jei marked "all boxes" up ONCE, on the collision batch, and this line
    # carries the identical phrase for the identical purpose — so it gets the
    # identical shade rather than a second, unnamed one.
    ask_yn "Do this for $(emphc "$C_EMBOX" "all boxes")" Y
    [[ $ANS_YN -eq 1 ]] && MOVE_ALL_BOXES=$ans
  done
  # Carried out of the round, because nothing is moved until every round is
  # over: a [c]hange in the block below can re-derive a destination this round
  # already asked about, and a move already made cannot be re-aimed.
  for (( i = 0; i < n; i = i + 1 )); do
    A_MOVE[${labels[i]}]=${moving[i]}
    M_OLD[${labels[i]}]=${olds[i]}
    M_NEW[${labels[i]}]=${news[i]}
  done

  # ── 3. FORM 1: destinations that are not empty, WITH data landing on them ──
  # The `moving` scope is the whole difference between the two forms — it is
  # what earns the four-way menu, because there are two sets of files to
  # reconcile. Everything it excludes is form 2's, below: a path with content
  # and nothing coming to meet it.
  #
  # Found HERE, ABOVE the receipt rather than down in the block it feeds: a
  # course of action that is ALREADY DECIDED changes what the receipt has to
  # say, and [u]se and [k]eep reverse the move outright.
  for (( i = 0; i < n; i = i + 1 )); do
    [[ ${moving[i]} -eq 1 ]] || continue
    if dir_has_content "${news[i]}"; then coll+=("$i"); COLL_AT[$i]=1; fi
  done
  # ⭐ THE BLOCK IS DRAWN IF, AND ONLY IF, A PROMPT WILL FOLLOW IT. Everything
  # in it — the disclosure, the Options list, the warning — exists to set up a
  # question, so when an earlier batch has already answered for every entry
  # there is nothing to set up and "it all becomes irrelevant" (Jei s41, ruling
  # on the move block; the collision batch could not carry a box yet when he
  # said it). Drawn anyway it is byte-identical to a live menu that then asks
  # nothing at all — the defect shipped in `f06118f`. Two cases, one code path:
  # a box carried by the MOVE batch is NOT decided here and must still be asked
  # (verified before this change: it always was), while a box carried by the
  # COLLISION batch is decided and gets the receipt below instead.
  ask_coll=1
  carried_dec=""
  if [[ ${#coll[@]} -gt 0 && ( -n $box_coll || -n $COLL_ALL_BOXES ) ]]; then
    ask_coll=0
    carried_dec=${box_coll:-$COLL_ALL_BOXES}
  fi

  # ── 3b. The receipt for whatever this box was not asked (Jei's line) ──────
  # One line per bind, naming the decision that was made for it:
  #   ask_moves 0 → the move answer came from an earlier box — what is moving
  #   ask_coll  0 → the course of action did too — what happens where it lands
  # A bind can be owed both, and a DECIDED course of action subsumes the move
  # line rather than following it: each of the four sentences below names the
  # old path itself, so printing "will be moved to <new>" above it would say
  # the same thing twice — and for [u]se / [k]eep it would be false outright,
  # since both reverse the move.
  #
  # ⭐ WORDING RULED BY JEI (s43), and the three things he cut are the point:
  #   no box name   — "there's a giant banner a few lines up" (the box header
  #                   is on screen, and paths_hdr repeats it directly above)
  #   no new path   — it is named in the summary box a few lines below, and in
  #                   the question itself for the box that was actually asked
  #   the leaf, not the display word — `program`, `output`, `input`, the same
  #                   tokens leaf_list uses in the disclosure this refers back
  #                   to. So it is leaf_dir here, NOT leaf_word ("program data"
  #                   would read "program data path").
  if [[ $ask_moves -eq 0 || $ask_coll -eq 0 ]]; then
    first=1
    for (( i = 0; i < n; i = i + 1 )); do
      [[ ${moving[i]} -eq 1 ]] || continue
      dec_i=${COLL_AT[$i]:+$carried_dec}
      # Nothing owed: the move question was asked and this destination is empty.
      [[ $ask_moves -eq 0 || -n $dec_i ]] || continue
      # The header once, above the first line — not between every pair of them.
      if [[ $first -eq 1 ]]; then first=0; paths_hdr "$box"; fi
      leaf=$(leaf_dir "${labels[i]}")
      # ⚠️ ask_choice hands back the LOWERCASE letter, "Mruk" default included:
      # the four decisions are m/r/u/k here, not M/r/u/k as the menu spells them.
      case "$dec_i" in
        m) prose "Merging current $leaf path [${olds[i]}] into new path." "$C_QTXT"
           continue ;;
        r) prose "Replacing new path with current $leaf path [${olds[i]}]." "$C_QTXT"
           continue ;;
        # ⚠️ [u]se is the ONE decision the move pass also reports on, with a
        # `-> <old> is left where it is` outcome line a few lines below. Naming
        # the path here too said it twice, so this clause stays generic and the
        # outcome line does the naming (Jei, s43).
        u) prose "Using data at new path for $leaf; leaving old path as-is." "$C_QTXT"
           continue ;;
        k) prose "Continuing to use current $leaf path [${olds[i]}] as-is." "$C_QTXT"
           continue ;;
      esac
      # Only the move was carried; the collision (if any) is still asked below.
      # This is the line Jei ruled in s41 and it is deliberately untouched.
      if [[ $ask_moves -eq 0 ]]; then
        word=$(leaf_word "${labels[i]}")
        prose "${word^} for $box will be moved to ${news[i]}." "$C_QTXT"
      fi
    done
  fi

  if [[ ${#coll[@]} -gt 0 ]]; then
   if [[ $ask_coll -eq 1 ]]; then
    local -a cpaths=() clabels=()
    for i in "${coll[@]}"; do cpaths+=("${news[i]}") clabels+=("${labels[i]}"); done
    say ""
    parent=$(common_parent "${cpaths[@]}")
    # "new BASE path" is only the right words for the directory the family was
    # actually placed at. Two typed paths can share a parent by accident —
    # /srv/input and /srv/output share /srv — and calling that a base path would
    # name something the user never chose (Jei's second example lists those two
    # separately). So the shared form is used only for the box's own directory.
    if [[ -n $parent ]] && same_dir "$parent" "$(data_root)/$box"; then
      disc_hdr "There are existing files at new base path $parent:"
      disc_row "$(leaf_list "${clabels[@]}")"
    else
      disc_hdr "There are existing files at new path(s):"
      for i in "${coll[@]}"; do
        disc_row "$box $(leaf_word "${labels[i]}"): ${news[i]}"
      done
    fi
    say ""
    # ⚠️ What is there may belong to ANOTHER BOX — asked about, never vetoed:
    # "that's the user's call" (Jei). The disclosure above IS the guard.
    disc_hdr "Options"
    opt_row M "erge existing, active data into new path (replace when overlapping)" "" 0 "$(isdef M Mruk)"
    opt_row r "emove data at new path, then move existing, active data to new path" "" 0 "$(isdef r Mruk)"
    opt_row u "se the data already at the new path (stop using existing data)" "" 0 "$(isdef u Mruk)"
    opt_row k "eep old path as-is" "" 0 "$(isdef k Mruk)"
    # Only when a base was elected is there a shared base to forgo (Jei).
    if [[ $DATA_AUTO -eq 1 ]]; then
      prose "*Warning: If you choose to keep the old path, this forgoes the shared base path." "$C_WARNI"
    fi
    say ""
   fi
    first=1
    for i in "${coll[@]}"; do
      if [[ -n $box_coll ]]; then dec[i]=$box_coll; continue; fi
      if [[ -n $COLL_ALL_BOXES ]]; then dec[i]=$COLL_ALL_BOXES; continue; fi
      ask_choice "Select a course of action for the $(emphc "$C_EMLBL" "$(leaf_word "${labels[i]}") path") [M/r/u/k]" "Mruk"
      dec[i]=$ANS_CH
      [[ $first -eq 1 ]] || continue
      first=0
      if [[ ${#coll[@]} -gt 1 ]]; then
        ask_yn "Apply this decision to all overlapping new $box paths" Y
        [[ $ANS_YN -eq 1 ]] || continue
        box_coll=${dec[i]}
      fi
      ask_yn "Apply this decision to $(emphc "$C_EMBOX" "all boxes")" Y
      [[ $ANS_YN -eq 1 ]] && COLL_ALL_BOXES=${dec[i]}
    done
    for i in "${coll[@]}"; do M_DEC[${labels[i]}]=${dec[i]}; done
  fi

  # ── 4. FORM 2: a path the box will now read that already holds data, with
  #       nothing moving onto it ────────────────────────────────────────────
  # Every settled path of the box is in view here, not just the ones a move was
  # accepted for — that scope is exactly what s41 got wrong. Three tests, in the
  # order they cost:
  #   · a move is landing on it → form 1 asked already (or the destination was
  #     empty, and there was nothing to ask)
  #   · the box already reads it → nothing is "new" about this path, and a keep
  #     box (whose PATHS are seeded straight from EXD_PATH) never gets past here
  #   · it has content → otherwise there is nothing to decide about
  for label in "${scope[@]}"; do
    new=${PATHS["$box:$label"]:-}
    [[ -n $new ]] || continue
    if [[ ${A_MOVE[$label]:-0} -eq 1 ]]; then continue; fi
    old=${EXD_PATH["$box:$label"]:-}
    if [[ -n $old ]] && same_dir "$old" "$new"; then continue; fi
    dir_has_content "$new" || continue
    b2+=("$label")
  done
  if [[ ${#b2[@]} -gt 0 ]]; then
    bpaths=()
    for label in "${b2[@]}"; do bpaths+=("${PATHS["$box:$label"]}"); done
    # ❓ OPEN IN THE PLAN, decided here the way a carried MOVE already goes and
    # FLAGGED FOR JEI: a box whose answer an earlier "all boxes" already gave is
    # asked nothing, so the block that sets that question up "all becomes
    # irrelevant" (his s41 words) and a one-line receipt per bind stands in for
    # it. A carried [c]hange prints none, exactly as a carried "no" to the move
    # question prints none — the path prompt that follows says it itself.
    # FORM 1 NOW AGREES: it draws its block on the same rule, below the same
    # kind of receipt.
    #
    # ⭐ THE RULE, stated as a property rather than as a list of cases: draw the
    # block if and only if a prompt will follow it. An entry is prompted when
    # the user CHANGED it once already (a batched answer must never re-answer
    # that, or a carried [c]hange loops with no way out) or when neither batch
    # holds an answer yet. `box_use` counts towards that and the earlier
    # USE_ALL_BOXES-only test missed it — a box-wide batch settled in an
    # earlier round could draw the block and then ask nothing, which is exactly
    # form 1's defect wearing form 2's clothes.
    ask_use=0
    for label in "${b2[@]}"; do
      if [[ -n ${CHANGED[$label]:-} ]]; then ask_use=1; continue; fi
      [[ -n $box_use || -n $USE_ALL_BOXES ]] || ask_use=1
    done
    if [[ $ask_use -eq 0 && ${box_use:-$USE_ALL_BOXES} == u ]]; then
      first=1
      for label in "${b2[@]}"; do
        if [[ $first -eq 1 ]]; then first=0; paths_hdr "$box"; fi
        # Form 1's [u]se sentence MINUS its trailing clause. Same decision, but
        # nothing is moving onto this destination, so there is no "current"
        # path being left behind to name — on a fresh create there is no old
        # path at all. ⚠️ NOT ruled: Jei's s43 wording was given for form 1.
        # The two forms are meant to read alike, so this follows it; the clause
        # is the one part that cannot be true here.
        leaf=$(leaf_dir "$label")
        prose "Using data at new path for $leaf." "$C_QTXT"
      done
    fi
    if [[ $ask_use -eq 1 ]]; then
      # ⭐ THE TOP AND THE BOTTOM ARE FORM 1'S, VERBATIM (Jei: "that is not an
      # accident"). Same two disclosure shapes on the same base-vs-parent test,
      # same Options header, same "Select a course of action for the <label>
      # path" line, same two batch questions. Only the menu between is new.
      paths_hdr "$box"
      parent=$(common_parent "${bpaths[@]}")
      if [[ -n $parent ]] && same_dir "$parent" "$(data_root)/$box"; then
        disc_hdr "There are existing files at new base path $parent:"
        disc_row "$(leaf_list "${b2[@]}")"
      else
        disc_hdr "There are existing files at new path(s):"
        for label in "${b2[@]}"; do
          disc_row "$box $(leaf_word "$label"): ${PATHS["$box:$label"]}"
        done
      fi
      say ""
      disc_hdr "Options"
      opt_row U "se this path anyway (data will be used / changed by the box)" "" 0 "$(isdef U Uc)"
      opt_row c "hange to a different path" "" 0 "$(isdef c Uc)"
      # Same rule as form 1's warning — only an ELECTED base can be forgone —
      # and only the clause naming the option that would forgo it differs.
      if [[ $DATA_AUTO -eq 1 ]]; then
        prose "*Warning: If you change to another path, this forgoes the shared base path." "$C_WARNI"
      fi
      say ""
    fi
    first=1
    for label in "${b2[@]}"; do
      ans=""
      # A batched answer never auto-answers a path THIS USER ALREADY CHANGED:
      # a carried [c]hange would otherwise re-ask that path for ever, with no
      # prompt left that could say "stop, use it".
      if [[ -z ${CHANGED[$label]:-} ]]; then
        if [[ -n $box_use ]]; then
          ans=$box_use
        elif [[ -n $USE_ALL_BOXES ]]; then
          ans=$USE_ALL_BOXES
        fi
      fi
      if [[ -z $ans ]]; then
        ask_choice "Select a course of action for the $(emphc "$C_EMLBL" "$(leaf_word "$label") path") [U/c]" "Uc"
        ans=$ANS_CH
        # ⚠️ NOT RULED BY JEI — ours (s42), flagged in the report for him.
        # "Change to a different path" cannot be applied to a SET: every path
        # needs its own new answer, and every box needs its own again. So
        # neither batch question is offered after a [c]hange. `first` is not
        # spent either — the offer moves to the first answer that CAN be
        # batched, rather than being lost because a [c]hange came first.
        if [[ $first -eq 1 && $ans != c ]]; then
          first=0
          askall=1
          if [[ ${#b2[@]} -gt 1 ]]; then
            ask_yn "Apply this decision to all overlapping new $box paths" Y
            if [[ $ANS_YN -eq 1 ]]; then box_use=$ans; else askall=0; fi
          fi
          if [[ $askall -eq 1 ]]; then
            ask_yn "Apply this decision to $(emphc "$C_EMBOX" "all boxes")" Y
            if [[ $ANS_YN -eq 1 ]]; then USE_ALL_BOXES=$ans; fi
          fi
        fi
      fi
      if [[ $ans == c ]]; then
        CHANGED[$label]=1
        nextscope+=("$label")
      else
        B_NEW[$label]=1
      fi
    done
  fi

  # ── 5. What a [c]hange unsettled ──────────────────────────────────────────
  # ⭐ "Paths", PLURAL, is load-bearing (Jei): path_derived hangs every other
  # bind of the box off the parent of its settled program dir, so changing the
  # program path re-derives input/output/workspace — they are unsettled too, and
  # every answer already given about them is about a path that no longer exists
  # as an answer. So they go back in scope with their state dropped.
  chg=(${nextscope[@]+"${nextscope[@]}"})   # the ones the user changed HIMSELF
  if [[ ${#nextscope[@]} -gt 0 ]]; then
    for word in "${chg[@]}"; do
      if [[ $word == data ]]; then
        nextscope=()
        for label in $(box_labels "$box"); do nextscope+=("$label"); done
        break
      fi
    done
    for label in "${nextscope[@]}"; do
      unset "A_MOVE[$label]" "M_OLD[$label]" "M_NEW[$label]" \
            "M_DEC[$label]" "B_NEW[$label]"
    done
    # Back through the ORDINARY settle route, in bind order — the changed path
    # forced to its prompt, the ones it dragged with it taking whatever that
    # route gives them (a re-derivation when the family was placed, a prompt of
    # their own when it was not). Nothing is created for a re-derived path yet:
    # the next round may walk away from it.
    for label in $(box_labels "$box"); do
      in_scope=0 in_chg=0
      for word in "${nextscope[@]}"; do
        if [[ $word == "$label" ]]; then in_scope=1; fi
      done
      [[ $in_scope -eq 1 ]] || continue
      for word in "${chg[@]}"; do
        if [[ $word == "$label" ]]; then in_chg=1; fi
      done
      if [[ $in_chg -eq 1 ]]; then
        set_bind_path "$box" "$label" 1
      else
        RELOC_NO_CREATE=1
        set_bind_path "$box" "$label"
        RELOC_NO_CREATE=0
        mkq+=("$label")
      fi
    done
  fi
  scope=(${nextscope[@]+"${nextscope[@]}"})
 done

  # ── 6. The moves ──────────────────────────────────────────────────────────
  # Deferred to here so that every path is final: a destination re-derived by a
  # [c]hange in a later round would otherwise be moved onto before it was known.
  for label in $(box_labels "$box"); do
    [[ -n ${M_OLD[$label]:-} ]] || continue
    old=${M_OLD[$label]} new=${M_NEW[$label]}
    if [[ ${A_MOVE[$label]:-0} -ne 1 ]]; then
      # ⭐ A DECLINED MOVE IS NO LONGER "keep the old path" UNCONDITIONALLY
      # (Jei s42): it means the files are not carried over. An empty destination
      # then keeps the recorded path, the s41 invariant; a [U]se from form 2
      # points the box at the new path and reads what is already there — and the
      # directory left behind is NAMED, for the same reason the `u` branch names
      # it below.
      if [[ -n ${B_NEW[$label]:-} ]]; then
        subnote "$old is left where it is $EMD nothing was moved."
      else
        revert_path "$box" "$label" "$old"
      fi
      continue
    fi
    case "${M_DEC[$label]:-plain}" in
      # Nothing moves. The box reads the directory that is already there — and
      # the directory it came from is NAMED, because a bind quietly pointed away
      # from a full data dir is the whole bug this feature exists to fix.
      u) subnote "$old is left where it is $EMD nothing was moved." ;;
      k) revert_path "$box" "$label" "$old" ;;
      *) move_one "$box" "$label" "$old" "$new" "${M_DEC[$label]:-plain}" \
           || revert_path "$box" "$label" "$old" ;;
    esac
  done
  # The directories a [c]hange re-derived and this pass held back: made only now
  # that no further answer can abandon them, and only where nothing else (a
  # move, or the path having been there all along) has already made them.
  for label in ${mkq[@]+"${mkq[@]}"}; do
    new=${PATHS["$box:$label"]:-}
    [[ -n $new ]] || continue
    [[ -d $(fs_path "$new") ]] && continue
    ensure_dir "$new" || :
  done
  return 0
}

