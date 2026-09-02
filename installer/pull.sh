# ── Image pull: podman REST API + one aggregated progress bar ────────────────
# `podman pull` draws its per-layer bars only on a tty, so ANY capture or filter
# of the CLI destroys exactly the progress that matters on multi-GB ROCm layers
# (and the old `grep -Ev 'skipped: already exists'` filter matched the tty
# wording, which is not what a piped pull emits — so it dropped nothing while
# silencing everything). The API reports byte counts regardless of tty: bring up
# a transient service, POST the Docker-compat /images/create, and aggregate the
# JSON stream into ONE line per image.
PULL_SOCK=""
PULL_SVC_PID=""

pull_service_stop() {
  [[ -n $PULL_SVC_PID ]] && kill "$PULL_SVC_PID" 2>/dev/null
  [[ -n $PULL_SOCK ]] && rm -f "$PULL_SOCK" 2>/dev/null
  PULL_SVC_PID="" PULL_SOCK=""
  return 0
}

# Unique socket per run, in the runtime dir (never /tmp when we can help it).
pull_service_start() {   # log → 0 once the socket is live
  local log=$1 i
  PULL_SOCK=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/droste-pull-$$.sock
  rm -f "$PULL_SOCK" 2>/dev/null || :
  "${RUNTIME:-podman}" system service --time=0 "unix://$PULL_SOCK" >>"$log" 2>&1 &
  PULL_SVC_PID=$!
  trap pull_service_stop EXIT
  for (( i = 0; i < 100; i = i + 1 )); do
    [[ -S $PULL_SOCK ]] && return 0
    # A service that died says so above this line, in its own words.
    if ! kill -0 "$PULL_SVC_PID" 2>/dev/null; then
      printf 'the API service exited before creating %s\n' "$PULL_SOCK" >>"$log"
      pull_service_stop
      return 1
    fi
    sleep 0.1
  done
  printf 'no API socket at %s after 10s\n' "$PULL_SOCK" >>"$log"
  pull_service_stop
  return 1
}

# Where the denominator comes from. A layer exists to the aggregator only once
# its first "Downloading" event arrives, and podman pulls about six of them at a
# time, so a total summed from what has been announced so far climbs every time
# another layer starts — the percentage sags backwards while the bytes go
# forwards. The stream never says how big the image is; the registry does. Ask
# it first and the total is known before the first byte lands.
#
# This runs on stdlib urllib alone: preflight promises bash, curl and python3
# and nothing else, so no skopeo, no jq, no second HTTP client. Every failure is
# deliberately silent — empty output means "no manifest", which the aggregator
# reads as "keep estimating" rather than as a reason to fail a pull that would
# otherwise have worked. The whole errand is on an 8s budget for the same
# reason: a registry that is slow to answer must not delay the download.
_pull_manifest_py() {
  cat <<'PY'
#@embed py/pull_manifest.py
PY
}

# The aggregator. Reads the /images/create JSON stream on stdin, sums every
# layer's progressDetail, and repaints ONE line; cached ("Already exists")
# layers count as complete and print nothing of their own. It leaves the cursor
# on that line WITHOUT a newline — the caller's status line overwrites it.
#
# The blob map from _pull_manifest_py arrives as a seventh argument and decides
# which of two modes it runs in: with one, the total is fixed for the life of
# the pull and the percentage only ever climbs; without one (or after the map
# turns out not to describe this stream), it falls back to the running sum and
# says so by printing the total with a "~".
#
# In --ascii there is no cursor to move, so the same two modes are drawn
# APPEND-ONLY instead (Jei's s39 spec): a header line, then either one "#" per
# percent across two 50-mark rows, or — when the manifest came back empty — one
# dot per elapsed minute, each row closing with its own (elapsed, bytes). That
# block stands in for the caller's status line, so it reports back the column it
# stopped on and the caller pads from there to the [OK] tag.
_pull_progress_py() {
  cat <<'PY'
#@embed py/pull_progress.py
PY
}

pull_image() {   # box → 0 on success (draws the bar; caller draws the status)
  local box=$1 img repo tag short log manifest colf col rc=0
  img="${IMAGE_PREFIX}${box}${IMAGE_SUFFIX}"
  repo=${img%:*} tag=${img##*:}
  # The bar is labelled with the image, not with the registry and owner that
  # every one of these images shares: the tail reserves 25 columns now that it
  # has to fit both a fixed total and an estimated one, and on an 80-column
  # terminal the difference between the full ref and this is the difference
  # between a bar and no bar. Stripping through the last slash keeps that true
  # for any prefix. The ref in full is in the step log, which is where anyone
  # asking WHICH registry is already looking.
  short=${repo##*/}
  log=$(step_log pull "$box")
  : > "$log"
  # Ask the registry how big this image is before asking podman to fetch it, so
  # the bar has a denominator that does not move. It is allowed to come back
  # empty (offline, private repo, a registry in a mood) — that is the estimating
  # mode, not an error — so its complaint goes to the log and its exit status is
  # ignored here as it is there.
  manifest=$(python3 -c "$(_pull_manifest_py)" "$repo" "$tag" 2>>"$log") \
    || manifest=""
  # Where the --ascii block reports the column it stopped on. Beside the step
  # log because that path is already per-box and already disposable.
  colf="$log.col"
  rm -f "$colf"
  # -N (--no-buffer): without it curl hands the JSON stream over in ~16 KB
  # blocks, so the aggregator below repaints in lurches no matter how often the
  # API reports. It is the whole "the bar only moves every few seconds" fix.
  curl -fsS -N --unix-socket "$PULL_SOCK" -X POST \
       "http://d/v1.40/images/create?fromImage=$repo&tag=$tag" 2>>"$log" \
    | python3 -c "$(_pull_progress_py)" \
        "$short..." "$(disp_width)" "$BAR_F" "$BAR_E" "$ASCII" "$manifest" \
        "${img%:*}..." "$STATUS_W" "$colf" \
        2>>"$log" \
    || rc=$?
  # --ascii drew its own block in place of the status line the caller would have
  # opened, and left the cursor mid-row: hand the tag the column it stopped on
  # (as a name-column offset, which is what status_head pads from) so [OK] still
  # lands in the tag column. No file means nothing was drawn — leave the line
  # closed and let status_head draw the head itself.
  if [[ $ASCII -eq 1 && -s $colf ]] && read -r col < "$colf"; then
    STATUS_COL=$(( col - 2 )); [[ $STATUS_COL -lt 0 ]] && STATUS_COL=0
    STATUS_NAME="$img..."
    STATUS_OPEN=1
  fi
  rm -f "$colf"
  return $rc
}

