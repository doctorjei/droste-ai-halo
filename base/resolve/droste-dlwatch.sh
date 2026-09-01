#!/usr/bin/env bash
# droste-dlwatch.sh — announce every model download, loudly (N24, phase P1).
#
# ⭐ WHAT IT IS. A small polling daemon that watches the filesystem — not the logs —
# for the PARTIAL FILES every downloader on every box writes, and announces
# STARTED / RESUMED / RUNNING / FINISHED / STALLED / ABANDONED per REPOSITORY on a
# private fd that lands in `podman logs <box>`.
#
# 🚨 WHY THE FILESYSTEM AND NOT THE LOGS — this is not a preference, log-tailing is
# IMPOSSIBLE here (design §2a, all source-verified):
#   * llama prints NOTHING for -hf at the default verbosity (its one line is LOG_DBG),
#     and its progress bar is isatty(1)-gated against an fd droste redirects to a file.
#   * vLLM DELIBERATELY disables its bar (`tqdm_class=DisabledTqdm`).
#   * huggingface_hub's bars are TTY-gated the same way.
#   * ds4's `hf download` is run BY HAND in an interactive shell — its output never
#     enters the service log at all.
# But all four write one of exactly TWO partial suffixes into a small, derivable set
# of directories, and that one fact covers five boxes, two languages, four transports
# and both huggingface_hub majors:
#   *.incomplete            huggingface_hub, every version, every backend
#                           0.x: blobs/<etag>.incomplete            (resumable)
#                           1.x: blobs/<etag>.<uuid8>.incomplete    (never reused)
#   *.downloadInProgress    llama.cpp — the sole partial name in its tree
#
# ── THE CONTRACT (design §3.2), and it is the whole point of this file ────────
#   partial appears that was not there last tick       STARTED
#   partial existed at FIRST SIGHT, then grows         RESUMED
#   partial exists and NEVER grows                     silent          ← R6
#   size grew since the last report, ≥ report interval RUNNING         (rate-limited)
#   partial disappears and the blob now exists         FINISHED
#   partial disappears with no blob                    ABANDONED
#   no growth for the stall window                     STALLED, once
#
# 🚨 THE "NEVER GROWS ⇒ SILENT" ROW IS RULED (R6) AND IS NOT AN OPTIMISATION.
# huggingface_hub 1.x uses a unique per-attempt name and unlinks it in a `finally`,
# so a SIGKILL leaves an orphan `.incomplete` that is NEVER reused and never reaped.
# A cache with a year of history has a drawer full of them. Announcing those on every
# container start would be a false positive on EVERY box, every start — the loudest
# possible way to make a new signal worthless. The cost is stated and accepted: a
# genuinely resumed transfer is announced on its first GROWTH rather than on first
# sight, i.e. up to one tick late.
# ⚠️ AND WE DO NOT REAP THEM (also R6). A reaper is a new DESTRUCTIVE behaviour and
# must never be smuggled in under an announcement feature.
#
# ── WHAT THIS FILE DELIBERATELY DOES NOT KNOW ────────────────────────────────
# * WHICH DIRECTORIES TO WATCH. Roots are passed in with repeatable `--root DIR`.
#   The CALLERS resolve which home applies (DROSTE_USER_HOME in the distrobox lane,
#   /root in the server lane — the split resolve::_lane_dest already encodes). Lane
#   knowledge stays in the doors; this stays pure and stays drivable from a lab.
# * WHETHER IT SHOULD RUN AT ALL. R8 put an on/off knob in the box's <box>.cfg and
#   "off" means DO NOT RUN THE DAEMON — so the decision belongs to the launch site,
#   which is after resolve::apply_spec, i.e. after the config file has been applied.
#   A daemon that reads its own kill switch would have to be started to read it.
# * ANY PERCENTAGE. Nothing writes the expected total to disk: hub knows it in memory
#   only and llama's .downloadInProgress carries no sidecar. The line reports BYTES SO
#   FAR and a RATE, which are true, instead of a percentage, which would be invented.
#   A total needs the in-process shim (R4, phase P4).
# * THE WIRE RATE. What we measure is DISK GROWTH. With xet or hf_transfer the two
#   differ (chunked reconstruction, parallel ranges), so no line here says "network".
#
# ── SOURCING IS SAFE ─────────────────────────────────────────────────────────
# Sourcing defines functions and nothing else: no scan, no daemon, no output. The
# main loop runs only when this file is EXECUTED (the guard at the bottom). The only
# file-scope effects are `: "${NAME:=default}"` on the five tunables and the empty
# state arrays, both guarded so a re-source cannot clobber a running instance.
# ⚠️ ERREXIT IS OFF ON PURPOSE — `set -uo pipefail`, matching droste-healthcheck.sh.
# This is a long-lived watcher over files that are BEING DELETED WHILE IT LOOKS AT
# THEM: a partial vanishing between the glob and the stat is not an error, it is the
# FINISHED signal. A daemon that exits on the race it was written to detect would go
# quiet exactly when it mattered, and it would do so silently.
#
# Run:  droste-dlwatch.sh --fd 9 --root /root/.cache/huggingface --root /root/.cache/llama.cpp
# Test: bash ~/workspace/g1lab/dlwatch.sh
set -uo pipefail

# Helpers a caller may already have defined; sourced UNCONDITIONALLY, exactly as both
# doors do, so serve::err/warn/info exist in either lane. droste-common.sh defines its
# fallbacks only `if ! declare -F`, so a real serve::err always wins.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/droste-common.sh"

# ── Tunables (R2: 5 s tick, RUNNING at most 1/60 s per repo, STALLED after 2 m) ──
# ⚠️ THESE NUMBERS ARE JUDGEMENT, NOT DATA. Nothing in N24 has run on hardware, and the
# standing ruling is that it does not yet. Revisit them the first time anyone watches a
# real download (design R2, §5.7).
: "${DLWATCH_INTERVAL:=5}"          # seconds between scans
: "${DLWATCH_REPORT_INTERVAL:=60}"  # seconds between RUNNING lines, per repository
: "${DLWATCH_STALL_WINDOW:=120}"    # seconds of no growth before STALLED, once
: "${DLWATCH_FD:=2}"                # the fd every line goes to; the caller opens it
: "${DLWATCH_PREFIX:=droste-download}"

# ── Per-process state, in memory (design §3.2) ───────────────────────────────
# One process, so no state file is needed for correctness. A container restart
# legitimately re-announces what is still in flight (§5.4) — that is a property of
# the ruling, not a defect: the box really did just start watching again.
# Guarded so re-sourcing this file cannot wipe a running instance's memory.
if ! declare -p _DLW_SIZE >/dev/null 2>&1; then
    declare -gA _DLW_SIZE=()      # path -> last observed size
    declare -gA _DLW_PRE=()       # path -> 1 if present at FIRST SIGHT (orphan candidate)
    declare -gA _DLW_GROUP=()     # path -> group key (kept so a VANISHED path still maps)
    declare -gA _DLW_G_STATE=()   # group -> "" | started | resumed
    declare -gA _DLW_G_T0=()      # group -> time we first announced it
    declare -gA _DLW_G_LASTREP=() # group -> time of the last STARTED/RESUMED/RUNNING line
    declare -gA _DLW_G_REPBYTES=() # group -> aggregate bytes at that line
    declare -gA _DLW_G_LASTGROW=() # group -> time we last saw any of its files grow
    declare -gA _DLW_G_STALLED=() # group -> 1 once STALLED has been said for this episode
    declare -gA _DLW_G_BYTES=()   # group -> last aggregate bytes seen live
    declare -gA _DLW_G_DONEN=()   # group -> files that vanished WITH a blob
    declare -gA _DLW_G_DONEB=()   # group -> bytes those blobs actually hold
    declare -gA _DLW_G_LOSTN=()   # group -> files that vanished WITHOUT one
    declare -g  _DLW_FIRST=1      # 1 until the first tick has been taken
    declare -g  _DLW_DEAD=0       # 1 once a write to the log fd has failed
fi

# ── dlwatch::reset — forget everything (the lab drives this between scenarios) ──
dlwatch::reset() {
    _DLW_SIZE=(); _DLW_PRE=(); _DLW_GROUP=()
    _DLW_G_STATE=(); _DLW_G_T0=(); _DLW_G_LASTREP=(); _DLW_G_REPBYTES=()
    _DLW_G_LASTGROW=(); _DLW_G_STALLED=(); _DLW_G_BYTES=()
    _DLW_G_DONEN=(); _DLW_G_DONEB=(); _DLW_G_LOSTN=()
    _DLW_FIRST=1
    _DLW_DEAD=0
}

# ─────────────────────────────────────────────────────────────────────────────
# THE WORDS (design §4)
# ─────────────────────────────────────────────────────────────────────────────
# Terse, prefixed, ONE line, no ANSI, no \r. They compete with server startup noise,
# so the verb comes first and is fixed-width (9 = len("ABANDONED")).
#
# 🚨 THE PREFIX IS NOT COSMETIC — IT IS WHAT KEEPS US OUT OF distrobox's GRAMMAR.
# distrobox-enter parses the container log line by line while a container is starting
# and treats a line beginning "Error:" as fatal, aborting the user's `distrobox enter`.
# "Warning:", "distrobox:", "+" and "container_setup_done" are the other reserved
# openings. Every line here begins "droste-download: ", so none of them can be hit.
#
# 🚨 R9: THE WORDING IS JEI'S TO APPROVE. The verbs, the prefix and the field order
# below are §4 reproduced byte-for-byte; they have NOT been signed off. Change them
# only with his answer in hand, and change them HERE — everything else formats through
# these six functions precisely so the wording lives in one place.
dlwatch::_line() { printf '%s: %-9s %s' "$DLWATCH_PREFIX" "$1" "$2"; }
dlwatch::_files() { if [ "${1:-0}" = 1 ]; then printf '1 file'; else printf '%d files' "${1:-0}"; fi; }

dlwatch::fmt_started()   { dlwatch::_line STARTED   "$(printf '%s  %-8s (%s)' "$1" "$(dlwatch::_files "$2")" "$3")"; }
dlwatch::fmt_resumed()   { dlwatch::_line RESUMED   "$(printf '%s  at %s, %s' "$1" "$(dlwatch::human "$2")" "$(dlwatch::_files "$3")")"; }
dlwatch::fmt_running()   { dlwatch::_line RUNNING   "$(printf '%s  %s  (+%s/s, %s)' "$1" "$(dlwatch::human "$2")" "$(dlwatch::human "$3")" "$(dlwatch::_files "$4")")"; }
dlwatch::fmt_finished()  { dlwatch::_line FINISHED  "$(printf '%s  %s in %s' "$1" "$(dlwatch::human "$2")" "$(dlwatch::duration "$3")")"; }
dlwatch::fmt_stalled()   { dlwatch::_line STALLED   "$(printf '%s  %s, no growth for %s' "$1" "$(dlwatch::human "$2")" "$(dlwatch::duration "$3")")"; }
dlwatch::fmt_abandoned() { dlwatch::_line ABANDONED "$(printf '%s  %s — partial file removed' "$1" "$(dlwatch::human "$2")")"; }

# ── dlwatch::human — bytes a person can read ────────────────────────────────
# ONE DECIMAL AT GiB AND ABOVE, INTEGER BELOW. That is not arbitrary: it is the rule
# that reproduces all four numbers §4 shows (12.4 GiB, 18.1 GiB, 32.5 GiB, 71 MiB/s).
# Integer arithmetic throughout — this runs in bash and there is no float.
dlwatch::human() {
    local b=${1:-0}
    case $b in ''|*[!0-9]*) b=0 ;; esac
    if [ "$b" -lt 1024 ];    then printf '%d B' "$b"; return 0; fi
    if [ "$b" -lt 1048576 ]; then printf '%d KiB' $(( b / 1024 )); return 0; fi
    if [ "$b" -lt 1073741824 ]; then printf '%d MiB' $(( b / 1048576 )); return 0; fi
    local u=1073741824 name=GiB
    if [ "$b" -ge 1125899906842624 ]; then u=1125899906842624; name=PiB
    elif [ "$b" -ge 1099511627776 ];  then u=1099511627776;  name=TiB
    fi
    printf '%d.%d %s' $(( b / u )) $(( (b % u) * 10 / u )) "$name"
}

# ── dlwatch::duration — elapsed time a person can read ──────────────────────
# 41s · 7m41s · 2m (a whole number of minutes drops the seconds) · 1h · 1h07m.
dlwatch::duration() {
    local s=${1:-0}
    case $s in ''|*[!0-9]*) s=0 ;; esac
    if [ "$s" -lt 60 ]; then printf '%ds' "$s"; return 0; fi
    local m=$(( s / 60 )) r=$(( s % 60 ))
    if [ "$m" -lt 60 ]; then
        if [ "$r" -eq 0 ]; then printf '%dm' "$m"; else printf '%dm%02ds' "$m" "$r"; fi
        return 0
    fi
    local h=$(( m / 60 )) mm=$(( m % 60 ))
    if [ "$mm" -eq 0 ]; then printf '%dh' "$h"; else printf '%dh%02dm' "$h" "$mm"; fi
}

# ─────────────────────────────────────────────────────────────────────────────
# NAMING: path -> repository
# ─────────────────────────────────────────────────────────────────────────────
# ⭐ AGGREGATE BY REPOSITORY, NOT BY FILE, and this is not cosmetic. llama fans out
# one thread per shard, so a split GGUF produces SEVERAL concurrent partials, and
# hub's snapshot_download produces many. One line per repository per interval, with
# the file count as a FIELD on the line, is the difference between a signal and a
# flood. The group KEY is the repository directory (or, for the flat shapes, the
# containing directory); the DISPLAYED name is derived from it.

# dlwatch::group_for <partial-path> — the stable identity a line is emitted for.
dlwatch::group_for() {
    local p=$1 d b
    case $p in
        */blobs/*)
            d=${p%/blobs/*}          # everything before the LAST /blobs/
            b=${d##*/}
            case $b in models--*|datasets--*) printf '%s' "$d"; return 0 ;; esac
            ;;
    esac
    printf '%s' "${p%/*}"
}

# dlwatch::repo_name <group-key> — what the user reads.
#   models--Qwen--Qwen3-30B-A3B  ->  Qwen/Qwen3-30B-A3B
#   models--gpt2                 ->  gpt2
#   datasets--squad              ->  datasets/squad      (the Hub's own URL spelling
#                                    for a dataset id — NOT a word we invented, and it
#                                    is what keeps a model repo and a dataset repo of
#                                    the same name from printing as one line)
#   a flat directory             ->  ~/ds4-gguf          (§4's own example)
dlwatch::repo_name() {
    local key=$1 b=${1##*/} id
    case $b in
        models--*)   id=${b#models--};   printf '%s' "${id//--//}"; return 0 ;;
        datasets--*) id=${b#datasets--}; printf 'datasets/%s' "${id//--//}"; return 0 ;;
    esac
    # A flat shape. hub's --local-dir mode hides its partials one level down, under
    # <dir>/.cache/huggingface/download/ — the user's directory is <dir>, so say that.
    key=${key%/.cache/huggingface/download}
    dlwatch::disp_dir "$key"
}

# dlwatch::disp_dir <dir> — collapse the user's home to ~, exactly as §4 prints it.
# ⚠️ DROSTE_USER_HOME FIRST, $HOME SECOND. The daemon runs as root, so $HOME is /root
# in the server lane and the box user's home is what the distrobox lane means.
# shellcheck disable=SC2088  # the ~ is a LITERAL the user is meant to read, not a path
# we are about to open. §4 prints `~/ds4-gguf`; expanding it here would print the
# daemon's own /root and name a directory that is not the one downloading.
dlwatch::disp_dir() {
    local d=$1 h=${DROSTE_USER_HOME:-${HOME:-}}
    if [ -n "$h" ] && [ "$d" = "$h" ]; then printf '~'; return 0; fi
    if [ -n "$h" ] && [ "${d#"$h"/}" != "$d" ]; then printf '~/%s' "${d#"$h"/}"; return 0; fi
    printf '%s' "$d"
}

# dlwatch::source_tag <group-key> — the parenthetical on the STARTED line.
# ⚠️ ONLY THE TWO TAGS §4 SHOWS. "hf cache" covers models AND datasets (both really
# are the hub cache); "flat directory" covers hub's --local-dir download folder AND
# llama's second cache at ~/.cache/llama.cpp, because both are a directory with no
# repository structure to read a name out of. Inventing a third word here would be
# inventing wording R9 reserved for Jei.
dlwatch::source_tag() {
    case ${1##*/} in
        models--*|datasets--*) printf 'hf cache' ;;
        *)                     printf 'flat directory' ;;
    esac
}

# ── dlwatch::blob_for <partial-path> — where the finished file lands ─────────
# Prints the destination and returns 0; returns 1 when the destination is NOT
# derivable. That third answer is real, not a hedge:
#   hub cache   blobs/<etag>.incomplete           -> blobs/<etag>          (0.x)
#               blobs/<etag>.<uuid8>.incomplete   -> blobs/<etag>          (1.x)
#   llama       <path>.downloadInProgress         -> <path>                (std::rename)
#   --local-dir <dir>/.cache/huggingface/download/<short_hash>.<etag>.incomplete
#                                                 -> NOT DERIVABLE
# 🚨 THE LOCAL-DIR CASE IS A GENUINE GAP AND IT IS UPSTREAM'S DOING, not ours. The
# leading component is `_short_hash(name)` = urlsafe-base64(sha1(filename.metadata))
# (_local_folder.py:508-509 at hub 1.29.0, read first-hand), and a hash is not a path.
# So for the flat shape we cannot tell FINISHED from ABANDONED, and the tick treats a
# disappearance there as FINISHED — see the note at that branch for why that is the
# less-wrong of the two, and my report flags it as a design question.
dlwatch::blob_for() {
    local p=$1 rest
    case $p in
        *.downloadInProgress) printf '%s' "${p%.downloadInProgress}"; return 0 ;;
        *.incomplete)
            case $p in
                */blobs/*)
                    rest=${p%.incomplete}
                    # hub 1.x appends a per-attempt 8-hex suffix. An etag contains no
                    # dot, so this can only ever strip the uuid.
                    if [[ $rest =~ \.[0-9a-fA-F]{8}$ ]]; then rest=${rest%.*}; fi
                    printf '%s' "$rest"; return 0 ;;
            esac
            return 1 ;;
    esac
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# SCANNING
# ─────────────────────────────────────────────────────────────────────────────
# ⭐ BOUNDED, BY CONSTRUCTION. Five globs per root, one readdir per repository — never
# a `find`, never a walk. The scan cost is proportional to the REPOSITORY COUNT, not
# to the cache size, which is what makes a 5 s tick defensible over a 400 GB cache.
# (§5.7: that has still never been measured on a populated box. Measure it in P3
# before defending the interval.)
#
# Output is one `<size>\t<path>` line per partial. One `stat` for the whole root, not
# one per file. A file that vanishes between the glob and the stat is simply absent
# from the output, which is exactly right — it has finished or been abandoned, and the
# tick decides which.
dlwatch::scan_root() {
    local root=$1
    local -a files=()
    local ng=0
    shopt -q nullglob && ng=1
    shopt -s nullglob
    files+=( "$root"/hub/models--*/blobs/*.incomplete )
    files+=( "$root"/hub/models--*/blobs/*.downloadInProgress )
    files+=( "$root"/hub/datasets--*/blobs/*.incomplete )
    files+=( "$root"/hub/datasets--*/blobs/*.downloadInProgress )
    files+=( "$root"/*.downloadInProgress )                          # llama's 2nd cache
    files+=( "$root"/.cache/huggingface/download/*.incomplete )      # hub --local-dir
    [ "$ng" = 1 ] || shopt -u nullglob
    [ ${#files[@]} -gt 0 ] || return 0
    stat -c '%s	%n' -- "${files[@]}" 2>/dev/null
    return 0
}

# dlwatch::scan — every root in DLWATCH_ROOTS. Roots that do not exist cost one failed
# glob each and are silent: a box whose user never set DS4_GGUF_DIR should not be told
# about it every five seconds.
dlwatch::scan() {
    local r
    for r in ${DLWATCH_ROOTS[@]+"${DLWATCH_ROOTS[@]}"}; do
        [ -n "$r" ] || continue
        dlwatch::scan_root "$r"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# EMISSION
# ─────────────────────────────────────────────────────────────────────────────
# ⚠️ ONE printf PER LINE, AND THE LINE STAYS SHORT. In the server lane this fd and the
# service's own fd 2 are THE SAME PIPE, so two writers share one stream; a single write
# under PIPE_BUF (4096) is atomic and cannot be interleaved. Do not build a line from
# two printfs.
# ⚠️ A FAILED WRITE IS THE EXIT CONDITION, not an error to report — it is what happens
# when the container goes down and takes conmon's pipe with it. There is no heartbeat
# cap: unlike hook::heartbeat this is meant to live as long as the box.
# ⚠️ THE REDIRECTION ORDER IS LOAD-BEARING, AND IT IS MEASURED. Redirections are applied
# LEFT TO RIGHT, so `>&"$FD" 2>/dev/null` on a CLOSED fd fails at the dup — before the
# stderr redirection exists — and bash prints `"$FD": Bad file descriptor` on the real
# stderr. In the server lane that stderr IS the container log, so the one event we handle
# gracefully would print a shell diagnostic into the very stream we were trying to stop
# writing to, once per line, forever. Silencing stderr FIRST makes the failure quiet.
# shellcheck disable=SC2261  # the two redirections do not compete: `>&$FD` is stdout
dlwatch::emit() {
    [ "$_DLW_DEAD" = 0 ] || return 1
    if ! printf '%s\n' "$1" 2>/dev/null >&"$DLWATCH_FD"; then
        _DLW_DEAD=1
        return 1
    fi
    return 0
}

# ── dlwatch::_grew <old-size> <new-size> — THE GROWTH TEST ──────────────────
# STRICTLY greater, and this one comparison is the entire difference between a
# feature and a false positive on every container start (R6): it is what separates
# a live transfer from a stale orphan sitting in the cache since some SIGKILL in
# March. It is a named function rather than an inline `[ -gt ]` for two reasons —
# it can be asserted on directly, and it gives the lab's MUTATION RUN a stable
# anchor. `dlwatch::_grew() { return 0; }` is the mutation; g1lab/dlwatch.sh
# records which rows it reddens.
dlwatch::_grew() { [ "${2:-0}" -gt "${1:-0}" ]; }

# ─────────────────────────────────────────────────────────────────────────────
# THE TICK — the behavioural contract, in one function
# ─────────────────────────────────────────────────────────────────────────────
# Usage: dlwatch::tick <unix-seconds>
# The clock is an ARGUMENT so the lab can drive an hour of behaviour in a millisecond.
# Nothing in here reads the wall clock.
dlwatch::tick() {
    local now=${1:-0}
    local -A cur=() gbytes=() gcount=() gnew=() ggrew=()
    local -A gdone=() gdoneb=() glost=()
    local p sz key blob bs st delta elapsed rate
    local -a keys=()

    # ── observe ─────────────────────────────────────────────────────────────
    while IFS=$'\t' read -r sz p; do
        [ -n "$p" ] || continue
        case $sz in ''|*[!0-9]*) continue ;; esac
        cur[$p]=$sz
    done < <(dlwatch::scan)

    for p in ${cur[@]+"${!cur[@]}"}; do
        key=$(dlwatch::group_for "$p")
        _DLW_GROUP[$p]=$key
        gbytes[$key]=$(( ${gbytes[$key]:-0} + ${cur[$p]} ))
        gcount[$key]=$(( ${gcount[$key]:-0} + 1 ))
        if [ -z "${_DLW_SIZE[$p]+x}" ]; then
            _DLW_SIZE[$p]=${cur[$p]}
            if [ "$_DLW_FIRST" = 1 ]; then
                # PRESENT AT FIRST SIGHT. Indistinguishable from a stale orphan, so it
                # says nothing until it grows (R6). This is the one line that stands
                # between the feature and a false positive on every container start.
                _DLW_PRE[$p]=1
            else
                _DLW_PRE[$p]=0
                gnew[$key]=1
            fi
        else
            if dlwatch::_grew "${_DLW_SIZE[$p]}" "${cur[$p]}"; then ggrew[$key]=1; fi
            _DLW_SIZE[$p]=${cur[$p]}
        fi
    done

    # ── files that vanished since the last tick ─────────────────────────────
    for p in ${_DLW_SIZE[@]+"${!_DLW_SIZE[@]}"}; do
        [ -z "${cur[$p]+x}" ] || continue
        key=${_DLW_GROUP[$p]:-}
        if [ -n "$key" ]; then
            if blob=$(dlwatch::blob_for "$p"); then
                if [ -e "$blob" ]; then
                    bs=$(stat -c '%s' -- "$blob" 2>/dev/null) || bs=''
                    case $bs in ''|*[!0-9]*) bs=${_DLW_SIZE[$p]} ;; esac
                    gdone[$key]=$(( ${gdone[$key]:-0} + 1 ))
                    gdoneb[$key]=$(( ${gdoneb[$key]:-0} + bs ))
                else
                    glost[$key]=$(( ${glost[$key]:-0} + 1 ))
                fi
            else
                # Destination not derivable — the --local-dir shape (see blob_for).
                # Counted as COMPLETED at its last observed size. ⚠️ THIS IS A CHOICE,
                # and the alternative is worse: reporting ABANDONED would tell every ds4
                # user that a download they just watched succeed had failed, on every
                # successful fetch. Getting this right needs the destination name, which
                # needs the in-process shim (P4).
                gdone[$key]=$(( ${gdone[$key]:-0} + 1 ))
                gdoneb[$key]=$(( ${gdoneb[$key]:-0} + ${_DLW_SIZE[$p]} ))
            fi
        fi
        unset '_DLW_SIZE[$p]' '_DLW_PRE[$p]' '_DLW_GROUP[$p]'
    done

    # fold this tick's terminals into the group's running totals
    for key in ${gdone[@]+"${!gdone[@]}"}; do
        _DLW_G_DONEN[$key]=$(( ${_DLW_G_DONEN[$key]:-0} + ${gdone[$key]} ))
        _DLW_G_DONEB[$key]=$(( ${_DLW_G_DONEB[$key]:-0} + ${gdoneb[$key]} ))
    done
    for key in ${glost[@]+"${!glost[@]}"}; do
        _DLW_G_LOSTN[$key]=$(( ${_DLW_G_LOSTN[$key]:-0} + ${glost[$key]} ))
    done

    # ── announce, for groups that still have files ──────────────────────────
    # Sorted, so the output of a tick is deterministic. A lab that cannot predict the
    # order of two lines cannot assert either of them.
    # ⚠️ The one-group case is short-circuited rather than sorted. It is also the common
    # case — one repository at a time is what a download normally is — and sorting it
    # would fork a subshell and a `sort` on every tick to order a single element. Same
    # reasoning as the read -t: work proportional to nothing, five seconds apart, forever.
    if [ ${#gbytes[@]} -gt 1 ]; then
        mapfile -t keys < <(printf '%s\n' "${!gbytes[@]}" | LC_ALL=C sort)
    elif [ ${#gbytes[@]} -eq 1 ]; then
        keys=( "${!gbytes[@]}" )
    else
        keys=()
    fi
    for key in ${keys[@]+"${keys[@]}"}; do
        st=${_DLW_G_STATE[$key]:-}
        if [ -z "$st" ]; then
            if [ -n "${gnew[$key]:-}" ]; then
                # A partial that was NOT there last tick. Creation strictly precedes the
                # GET body in both implementations, so this really is the starting edge.
                dlwatch::emit "$(dlwatch::fmt_started \
                    "$(dlwatch::repo_name "$key")" "${gcount[$key]}" "$(dlwatch::source_tag "$key")")"
                st=started
            elif [ -n "${ggrew[$key]:-}" ]; then
                # Present at first sight AND growing: a transfer that began before we
                # started watching, or a real cross-process resume (llama, hub 0.x).
                dlwatch::emit "$(dlwatch::fmt_resumed \
                    "$(dlwatch::repo_name "$key")" "${gbytes[$key]}" "${gcount[$key]}")"
                st=resumed
            fi
            if [ -n "$st" ]; then
                _DLW_G_STATE[$key]=$st
                _DLW_G_T0[$key]=$now
                _DLW_G_LASTREP[$key]=$now
                _DLW_G_REPBYTES[$key]=${gbytes[$key]}
                _DLW_G_LASTGROW[$key]=$now
                _DLW_G_STALLED[$key]=0
            fi
        else
            if [ -n "${ggrew[$key]:-}" ]; then
                _DLW_G_LASTGROW[$key]=$now
                # A new stall EPISODE may be announced. STALLED is "once" per episode,
                # not once per lifetime: a transfer that stalls, recovers and stalls
                # again has stalled twice and the user wants to know both times.
                _DLW_G_STALLED[$key]=0
            fi
            elapsed=$(( now - ${_DLW_G_LASTREP[$key]:-$now} ))
            delta=$(( ${gbytes[$key]} - ${_DLW_G_REPBYTES[$key]:-0} ))
            if [ "$delta" -gt 0 ] && [ "$elapsed" -ge "$DLWATCH_REPORT_INTERVAL" ]; then
                rate=0
                [ "$elapsed" -gt 0 ] && rate=$(( delta / elapsed ))
                dlwatch::emit "$(dlwatch::fmt_running \
                    "$(dlwatch::repo_name "$key")" "${gbytes[$key]}" "$rate" "${gcount[$key]}")"
                _DLW_G_LASTREP[$key]=$now
                _DLW_G_REPBYTES[$key]=${gbytes[$key]}
            elif [ "${_DLW_G_STALLED[$key]:-0}" != 1 ] &&
                 [ $(( now - ${_DLW_G_LASTGROW[$key]:-$now} )) -ge "$DLWATCH_STALL_WINDOW" ]; then
                dlwatch::emit "$(dlwatch::fmt_stalled \
                    "$(dlwatch::repo_name "$key")" "${gbytes[$key]}" \
                    "$(( now - ${_DLW_G_LASTGROW[$key]:-$now} ))")"
                _DLW_G_STALLED[$key]=1
            fi
        fi
        _DLW_G_BYTES[$key]=${gbytes[$key]}
    done

    # ── terminals: a group with no files left ───────────────────────────────
    # Emitted after the live groups so a tick reads chronologically, and only for a
    # group we actually ANNOUNCED. A stale orphan that a user finally deletes must not
    # produce an ABANDONED line for a download nobody was told about (R6 again — the
    # silence has to hold at BOTH ends or the false positive just moves).
    if [ ${#_DLW_G_STATE[@]} -gt 1 ]; then
        mapfile -t keys < <(printf '%s\n' "${!_DLW_G_STATE[@]}" | LC_ALL=C sort)
    elif [ ${#_DLW_G_STATE[@]} -eq 1 ]; then
        keys=( "${!_DLW_G_STATE[@]}" )
    else
        keys=()
    fi
    for key in ${keys[@]+"${keys[@]}"}; do
        [ -z "${gbytes[$key]+x}" ] || continue          # still has live partials
        if [ -n "${_DLW_G_STATE[$key]:-}" ]; then
            if [ "${_DLW_G_DONEN[$key]:-0}" -gt 0 ]; then
                dlwatch::emit "$(dlwatch::fmt_finished \
                    "$(dlwatch::repo_name "$key")" "${_DLW_G_DONEB[$key]:-0}" \
                    "$(( now - ${_DLW_G_T0[$key]:-$now} ))")"
            else
                dlwatch::emit "$(dlwatch::fmt_abandoned \
                    "$(dlwatch::repo_name "$key")" "${_DLW_G_BYTES[$key]:-0}")"
            fi
        fi
        dlwatch::_forget_group "$key"
    done
    # Groups that were never announced and are now empty leave no trace either.
    for key in ${_DLW_G_DONEN[@]+"${!_DLW_G_DONEN[@]}"}; do
        [ -z "${gbytes[$key]+x}" ] && [ -z "${_DLW_G_STATE[$key]+x}" ] && dlwatch::_forget_group "$key"
    done
    for key in ${_DLW_G_LOSTN[@]+"${!_DLW_G_LOSTN[@]}"}; do
        [ -z "${gbytes[$key]+x}" ] && [ -z "${_DLW_G_STATE[$key]+x}" ] && dlwatch::_forget_group "$key"
    done

    _DLW_FIRST=0
    return 0
}

dlwatch::_forget_group() {
    local key=$1
    unset '_DLW_G_STATE[$key]' '_DLW_G_T0[$key]' '_DLW_G_LASTREP[$key]' \
          '_DLW_G_REPBYTES[$key]' '_DLW_G_LASTGROW[$key]' '_DLW_G_STALLED[$key]' \
          '_DLW_G_BYTES[$key]' '_DLW_G_DONEN[$key]' '_DLW_G_DONEB[$key]' '_DLW_G_LOSTN[$key]'
}

# ─────────────────────────────────────────────────────────────────────────────
# SINGLE INSTANCE
# ─────────────────────────────────────────────────────────────────────────────
# The init hook runs on EVERY container start and every healthcheck-driven restart, so
# without this a restart loop would accumulate watchers, all writing the same lines to
# the same pipe.
# ⚠️ A PID ALONE IS NOT EVIDENCE — pids are recycled, and a stale pidfile that happens
# to name a live unrelated process would silence the watcher for the life of the box.
# The cmdline is checked too, and an unreadable/absent /proc entry means "stale", never
# "held".
dlwatch::pidfile() {
    printf '%s/.DLWATCH_PID' \
        "${DROSTE_SERVE_STATE_DIR:-${DROSTE_PCACHE_DIR:-/opt/program-cache}/state}"
}

dlwatch::claim_pidfile() {
    local pf=${1:-$(dlwatch::pidfile)} old dir
    dir=${pf%/*}
    if ! mkdir -p "$dir" 2>/dev/null; then
        # ⚠️ WE STILL RUN. A missing program cache is not a reason to go silent about a
        # 400 GB download; it is a reason to lose the duplicate guard, which is the
        # cheaper of the two losses.
        serve::warn "download watcher: cannot create $dir — running without a single-instance guard."
        return 0
    fi
    if [ -r "$pf" ]; then
        old=$(cat "$pf" 2>/dev/null)
        case $old in
            ''|*[!0-9]*) old='' ;;
        esac
        if [ -n "$old" ] && [ "$old" != "$$" ] && dlwatch::_pid_is_watcher "$old"; then
            return 1
        fi
    fi
    printf '%s\n' "$$" >"$pf" 2>/dev/null || return 0
    return 0
}

dlwatch::_pid_is_watcher() {
    local pid=$1
    [ -d "/proc/$pid" ] || return 1
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'droste-dlwatch'
}

# ─────────────────────────────────────────────────────────────────────────────
# THE DAEMON
# ─────────────────────────────────────────────────────────────────────────────
dlwatch::usage() {
    cat <<'EOF'
Usage: droste-dlwatch.sh --fd N --root DIR [--root DIR ...] [options]

Announces model downloads by watching for partial files. One line per repository.

  --root DIR             a directory to watch. REPEATABLE. Callers resolve which
                         home applies; this script never guesses one.
  --fd N                 the already-open fd every line is written to (default 2).
  --interval SEC         seconds between scans (default 5)
  --report-interval SEC  seconds between RUNNING lines, per repository (default 60)
  --stall-window SEC     seconds of no growth before STALLED (default 120)
  --once                 take a single tick and exit (for wiring checks)
  --no-pidfile           skip the single-instance guard
  -h, --help             this text

Typical roots:
  <home>/.cache/huggingface        the CRITICAL bind every box declares
  <home>/.cache/llama.cpp          llama's second cache, for -mu/-dr (R10)
  a --local-dir target             e.g. ds4's DS4_GGUF_DIR
EOF
}

dlwatch::main() {
    local once=0 pidguard=1
    DLWATCH_ROOTS=()
    while [ $# -gt 0 ]; do
        case $1 in
            --root)            DLWATCH_ROOTS+=( "${2-}" ); shift 2 ;;
            --root=*)          DLWATCH_ROOTS+=( "${1#*=}" ); shift ;;
            --fd)              DLWATCH_FD=${2-2}; shift 2 ;;
            --fd=*)            DLWATCH_FD=${1#*=}; shift ;;
            --interval)        DLWATCH_INTERVAL=${2-5}; shift 2 ;;
            --interval=*)      DLWATCH_INTERVAL=${1#*=}; shift ;;
            --report-interval) DLWATCH_REPORT_INTERVAL=${2-60}; shift 2 ;;
            --report-interval=*) DLWATCH_REPORT_INTERVAL=${1#*=}; shift ;;
            --stall-window)    DLWATCH_STALL_WINDOW=${2-120}; shift 2 ;;
            --stall-window=*)  DLWATCH_STALL_WINDOW=${1#*=}; shift ;;
            --once)            once=1; shift ;;
            --no-pidfile)      pidguard=0; shift ;;
            -h|--help)         dlwatch::usage; return 0 ;;
            *)                 serve::err "download watcher: unknown option '$1'"; dlwatch::usage >&2; return 2 ;;
        esac
    done

    if [ ${#DLWATCH_ROOTS[@]} -eq 0 ]; then
        serve::err "download watcher: no --root given; nothing to watch."
        return 2
    fi
    case $DLWATCH_FD in ''|*[!0-9]*) serve::err "download watcher: --fd must be a number"; return 2 ;; esac

    if [ "$pidguard" = 1 ]; then
        dlwatch::claim_pidfile || return 0     # another live watcher owns this box
    fi

    dlwatch::reset
    dlwatch::_arm_timer

    while :; do
        dlwatch::tick "$(printf '%(%s)T' -1)"
        [ "$_DLW_DEAD" = 0 ] || return 0       # the log fd died: the container is going
        [ "$once" = 0 ] || return 0
        dlwatch::_wait "$DLWATCH_INTERVAL"
    done
}

# ── the sleepless wait ──────────────────────────────────────────────────────
# ⭐ A `read -t` ON AN FD THAT NEVER DELIVERS, not `sleep`. At a 5 s tick a sleep-loop
# forks 17,280 processes a day per box for nothing. A fifo opened read-write never
# reaches EOF and nothing ever writes to it, so the read can only time out.
# ⚠️ The fifo is unlinked immediately: the open fd keeps it alive, and nothing is left
# in the filesystem if we are killed.
dlwatch::_arm_timer() {
    local fifo
    _DLW_TIMER=0
    fifo=$(mktemp -u "${TMPDIR:-/tmp}/.dlwatch.XXXXXX") || return 0
    mkfifo -m 600 "$fifo" 2>/dev/null || return 0
    if exec 8<>"$fifo" 2>/dev/null; then _DLW_TIMER=1; fi
    rm -f "$fifo" 2>/dev/null
    return 0
}

dlwatch::_wait() {
    if [ "${_DLW_TIMER:-0}" = 1 ]; then
        read -r -t "$1" -u 8 _ 2>/dev/null
        return 0
    fi
    sleep "$1"
    return 0
}

# ── executed, not sourced? ──────────────────────────────────────────────────
# Sourcing this file defines functions and nothing else. Everything above is a
# definition; only this line runs anything, and only when the file is the program.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    dlwatch::main "$@"
    exit $?
fi
