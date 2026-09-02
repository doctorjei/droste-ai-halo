# ── Executing-section output ─────────────────────────────────────────────────
# Every line the Executing section prints comes from one of these four helpers,
# and NOTHING a tool writes reaches the screen: podman's and distrobox's own
# chatter is captured to a log (see step_log) and only its tail is shown, and
# only on failure. The section is the one place the installer speaks while
# something slow is happening, so it stays a fixed, readable shape.

# Underlined bright-white group header; the blank line above it is part of it.
exec_hdr() { printf '\n  %s%s%s\n' "$C_EXH" "$1" "$RESET"; }

# One emitted file name, italic light grey.
exec_file() { printf '  %s%s%s\n' "$C_FILE" "$1" "$RESET"; }

# Width of the name column in [OK]/[ERROR] status lines: the longest name of
# the WHOLE Executing section plus a three-space gap, clamped so the tag still
# lands inside the terminal (a name longer than that simply pushes the tag
# right). Three, not five: it pulls the image lines back under 60 columns
# (Jei s34), and one width for every group aligns Creating Boxes with Pulling
# Images instead of letting each group find its own column.
STATUS_W=0
status_width() {   # name...
  local n max=0 w avail
  for n in "$@"; do [[ ${#n} -gt $max ]] && max=${#n}; done
  w=$(( max + 3 ))
  avail=$(( $(disp_width) - 2 - 7 ))    # indent + "[ERROR]"
  [[ $w -gt $avail ]] && w=$avail
  [[ $w -lt 1 ]] && w=1
  STATUS_W=$w
  return 0
}

# WHERE THE IN-PROGRESS TEXT SITS. It used to start in the tag column, so a
# frame like "removing old (999s)" ran 15 columns PAST the end of [OK] (Jei,
# live test). It now starts TICK_BACK columns left of the tag, which keeps the
# widest realistic frame inside the tag's own right edge:
#   tag column      = 2 + STATUS_W          ("  " indent + the name column)
#   [OK] ends at      2 + STATUS_W + 4      ([ERROR] is 3 wider)
#   widest frame    = "removing old (999s)" = 19
#   22 back         ⇒ ends 2 + STATUS_W - 3, i.e. 7 short of [OK]'s end.
# Two guards keep that true for every real name and terminal:
#   FLOOR — never left of the name + one space (the pad would stop working and
#           the frame would push RIGHT instead). Of the real names only
#           "droste-finetuning-halo-server..." (32) reaches it, and only by 2
#           columns: that one line ticks 20 back rather than 22.
#   CAP   — never so far right that the frame could pass [OK]'s end anyway (a
#           narrow terminal clamps STATUS_W, which moves the tag left).
# The column is the same for every phase (only the CAP looks at the text), so
# the phase words line up with each other as well as under the tag.
TICK_BACK=22
TICK_PHASE="removing old"    # the widest phase word: it sizes the shared column
tick_col() {   # phase elapsed → column, relative to the two-space indent
  local need col room floor
  need=$(( ${#1} + ${#2} + 4 ))          # "<phase> (<el>s)"
  col=$(( STATUS_W - TICK_BACK ))
  room=$(( STATUS_W + 4 - need ))        # right edge of the [OK] tag
  [[ $col -gt $room ]] && col=$room
  floor=$(( ${#STATUS_NAME} + 1 ))
  [[ $col -lt $floor ]] && col=$floor
  [[ $col -lt 0 ]] && col=0
  printf '%s' "$col"
}

# A STATUS LINE HAS A LIFETIME, not just an ending: it opens the moment the
# work starts (so a slow step can never be mistaken for a hang), is repainted
# while the work runs, and is completed in place by the [OK]/[ERROR] tag.
#
#   status_start <name>          "  <name>...            "   (no newline)
#   run_step <phase> <log> cmd…  "  <name>...   creating (7s)"  ~1/s
#   status_ok/status_err <name>  "  <name>...            [OK]"
#
# In --ascii there is no repaint plumbing (CR/EL are empty), so the line is
# closed at each transition instead: one line per phase as it begins, then the
# completion line. Never a per-second frame there — that would spam a log.
STATUS_OPEN=0     # 1 = a partial (unterminated) status line is on screen
STATUS_NAME=""    # what that line names, for the repaints
STATUS_COL=0      # how far that partial line was padded (the ticker column)

# The open line stops at the TICKER column, not the tag column: in --ascii
# there is no way back, so whatever prints next (a phase word, or the padding
# up to the tag) has to start from a column that leaves room for it.
status_start() {   # name
  STATUS_NAME=$1
  STATUS_COL=$(tick_col "$TICK_PHASE" "")
  printf '  %s%-*s%s' "$C_TEXT" "$STATUS_COL" "$1" "$RESET"
  STATUS_OPEN=1
  return 0
}

# The head of a completed line: repainted from column 0 when the terminal can
# do that; otherwise the open line is simply padded the rest of the way to the
# tag column (or drawn whole, when nothing opened it).
status_head() {   # name
  local n
  if [[ -n $CR ]]; then
    printf '%s  %s%-*s%s' "$CR" "$C_TEXT" "$STATUS_W" "$1" "$RESET"
  elif [[ $STATUS_OPEN -eq 1 ]]; then
    n=$(( STATUS_W - STATUS_COL )); [[ $n -lt 1 ]] && n=1
    printf '%*s' "$n" ""
  else
    printf '  %s%-*s%s' "$C_TEXT" "$STATUS_W" "$1" "$RESET"
  fi
  STATUS_OPEN=0
  return 0
}

# Both endings close with erase-to-EOL, which is what wipes the widest ticker
# frame (the elapsed count grows a digit) or a progress bar of any width.
status_ok() {   # name
  status_head "$1"
  printf '%s[%s%s%s]%s%s\n' \
    "$C_OKB" "$C_OK" "OK" "$C_OKB" "$RESET" "$EL"
}

# Failure: the tag, then the LAST THREE captured lines (enough to name the
# cause), then where the whole capture lives. Raw tool output is never streamed.
status_err() {   # name log-path
  local name=$1 log=$2 line
  status_head "$name"
  printf '%s[%s%s%s]%s%s\n' \
    "$C_BADB" "$C_ERR" "ERROR" "$C_BADB" "$RESET" "$EL"
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    printf '    %s%s%s\n' "$C_TEXT" "$line" "$RESET"
  done < <(tail -n 3 "$log" 2>/dev/null)
  printf '  %sfull log: %s%s\n' "$C_FILE" "$(emit_spelled "$log")" "$RESET"
  return 0
}

# ONE slow child, run under a live "<phase> (Ns)" ticker.
#   run_step <phase> <log> <command…>   → the command's exit status
# The child's stdout AND stderr go to <log> exactly as they did when these
# commands ran in the foreground; only the parent paints. Creation has no byte
# stream to measure, so the ticker says what is happening and how long it has
# been happening rather than pretending to know a percentage.
#
# Poll at 4 Hz, repaint at 1 Hz: the repaint rate is what the reader wants, the
# poll rate is how quickly the [OK] lands once the child is done. A step that
# finishes inside the first second never paints a frame at all — the completion
# simply overwrites the line status_start opened.
run_step() {   # phase log command...
  local phase=$1 log=$2 pid rc=0 t0 el shown=-1 col
  shift 2
  if [[ -z $CR ]]; then
    # --ascii: announce the phase on its own line, no ticker. Same column as
    # the repainting mode uses, so the two read alike.
    col=$(tick_col "$phase" "")
    if [[ $STATUS_OPEN -eq 1 ]]; then
      # status_start already padded to that column: the phase lands on it.
      printf '%s%s%s\n' "$C_SVC" "$phase" "$RESET"
      STATUS_OPEN=0
    else
      printf '  %s%-*s%s%s%s%s\n' "$C_TEXT" "$col" "$STATUS_NAME" "$RESET" \
        "$C_SVC" "$phase" "$RESET"
    fi
    "$@" >>"$log" 2>&1 || rc=$?
    return $rc
  fi
  "$@" >>"$log" 2>&1 &
  pid=$!
  t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    el=$(( SECONDS - t0 ))
    if [[ $el -gt $shown ]]; then
      shown=$el
      col=$(tick_col "$phase" "$el")
      printf '%s  %s%-*s%s%s%s (%ss)%s' "$CR" "$C_TEXT" "$col" "$STATUS_NAME" \
        "$RESET" "$C_SVC" "$phase" "$el" "$EL"
    fi
    sleep 0.25
  done
  wait "$pid" || rc=$?
  return $rc
}

# Per-step capture file under the resource path (whose stated purpose is
# "(re)creation records, logs, & data"). Falls back to the temp dir if that
# directory cannot be made, so a failed pull still has somewhere to say why.
# The log is the installer's OWN artifact and is opened by a dozen writers, so
# this hands back a RESOLVED path — the one place a stored spelling is
# deliberately left behind. emit_spelled puts the user's spelling of the
# resource path back on the front for the one line that shows one.
step_log() {   # step name → path
  local d
  d=$(fs_path "$EMIT_DIR")/logs
  mkdir -p "$d" 2>/dev/null || d=${TMPDIR:-/tmp}
  printf '%s/%s-%s.log' "$d" "$1" "$2"
}

emit_spelled() {   # resolved path under the resource dir → the user's spelling
  local p=$1 real
  real=$(fs_path "$EMIT_DIR")
  if [[ $p == "$real"/* ]]; then printf '%s/%s' "$EMIT_DIR" "${p#"$real"/}"
  else printf '%s' "$p"; fi
}

