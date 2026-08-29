#!/usr/bin/env bash
# droste-common.sh — helpers a build-spec may call in EITHER lane.
#
# ⭐ WHY THIS FILE EXISTS. A build-spec's PRE_LAUNCH runs in BOTH lanes:
# droste-resolve.sh (distrobox — what the installer builds) calls it, and so does
# droste-serve.sh (the server lane). But the two scripts share no code and neither
# sources the other, so anything a build-spec calls has to exist in both. Until
# s52 nothing did, and two build-specs were calling serve::* from PRE_LAUNCH.
#
# 🚨 WHAT THAT COST, MEASURED: in the distrobox lane `serve::err` is not defined,
# so the call is `command not found` (127). droste-resolve.sh runs PRE_LAUNCH
# unguarded under `set -euo pipefail`, so THE RESOLVER DIES AND THE BOX DOES NOT
# START. ds4's "this value is Metal-only, ignoring it" guard and comfyui's six
# invalid-value warnings — every one written to be FORGIVING — killed the box
# instead. Latent only because they fire on values nobody had set yet.
#
# Sourced near the top of droste-resolve.sh and droste-serve.sh. Keep it free of
# side effects: definitions only, no state, nothing that assumes a lane.

# ── message helpers, defined only if the sourcing lane has none ──────────────
# droste-serve.sh defines its own serve::* (with its own prefix) and those win.
# This is the fallback that makes a build-spec's serve::err call SAFE in the
# resolver lane rather than fatal.
if ! declare -F serve::err >/dev/null 2>&1; then
    serve::err()  { printf 'droste: ERROR: %s\n' "$*" >&2; }
fi
if ! declare -F serve::warn >/dev/null 2>&1; then
    serve::warn() { printf 'droste: WARN: %s\n' "$*" >&2; }
fi
if ! declare -F serve::info >/dev/null 2>&1; then
    serve::info() { printf 'droste: INFO: %s\n' "$*" >&2; }
fi

# ── droste::bool — the ONE answer to "what counts as off" ────────────────────
# Prints "on", "off", or "" (empty/unrecognised — the CALLER decides which).
#
# ⭐ WHY IT LIVES HERE AND NOT IN A BUILD-SPEC. It began as ds4_bool, and it has to
# be shared for the same reason the key-signature rules are shared: a box where
# `yes` works and a box where it does not is a broken promise, not a quirk. One
# Surface, Five Servers — the user-facing vocabulary is uniform and the mechanism
# differences are ours to absorb. ds4_bool now delegates here so the two cannot
# drift apart.
#
# 🚨 IT IS A WHITELIST, AND THAT IS THE WHOLE POINT. ds4's was once a BLACKLIST —
# anything outside ""|0|false|no|off emitted the flag — so `Off`, `FALSE` and
# `disabled` all turned a setting ON. That is the dangerous direction: a user
# trying to disable something enabled it. Measured, not theorised.
# Case-folded and space-stripped because `Off`, `OFF` and a stray trailing space
# are what people actually type.
droste::bool() {
    local v=${1:-}
    v=${v,,}; v=${v// /}
    case "$v" in
        1|true|yes|on)  printf 'on' ;;
        0|false|no|off) printf 'off' ;;
        "")             printf '' ;;   # unset/blank — same output as unrecognised,
        *)              printf '' ;;   # written apart to document the collapse
    esac
}

# ── droste::blank_is_unset — make a blank NATIVE line mean what the file says ─
# Usage:  droste::blank_is_unset QT_API IPYTHONDIR
#
# ⭐ THE PROBLEM IT SOLVES, AND IT IS NOT A TIDINESS ONE. Every config file in this
# project ships its settings COMMENTED OUT and promises that "the value shown is the
# default", so uncommenting a shown line must be a NO-OP. Dozens of lines are shown
# BLANK, with an annotation that says what blank means — `# IPYTHONDIR=  # unset:
# ~/.ipython`. Both resolvers source the file under `set -a`, so uncommenting that
# line hands the server `IPYTHONDIR=""`, and a reader that asks "IS IT SET" rather
# than "IS IT NON-EMPTY" then sees a VALUE. The file said unset; the wire said "".
#
# 🚨 IT IS NEVER A NO-OP WHEN IT BITES, AND THE FAILURES ARE NOT SUBTLE, all read
# from the PINNED sources:
#   IPYTHONDIR      IPython/paths.py:36 `env.get("IPYTHONDIR", None)` + `is None`
#                   ⇒ "" survives, normpath("") is ".", profiles land in the CWD
#   QT_API          qtpy/__init__.py `os.environ.get(QT_API, "pyqt5")` + a
#                   membership check ⇒ "" is not a binding name and the import
#                   RAISES PythonQtValueError
#   DS4_SERVER_DISABLE_THINK_TOOL_RECOVERY   ds4_server.c:10372 `getenv(..)==NULL`
#   DS4_MTP_SPEC_DISABLE                     ds4_server.c:10407 `getenv(..)==NULL`
#   DS4_METAL_GRAPH_DUMP_PREFIX              ds4.c:11230        `getenv(..)==NULL`
#                   ⇒ all three are PRESENCE tests, so a blank DISABLES the feature
#                   the file's own comment says only `1` disables.
#
# ⚠️ SCOPE — THIS IS A NARROW, NAMED LIST, NOT A POLICY. It unsets only the
# variables a caller names, because it was verified AT THE PIN that "" and unset
# differ for them. It must NOT become "unset every empty variable": for a
# DROSTE_-owned setting a blank is the user's deliberate opt-out (N1a: absent ⇒
# ours, set ⇒ theirs, blank ⇒ off) and erasing it would turn "I don't want one"
# back into "here, have one".
# ⚠️ A variable that is SET AND NON-EMPTY is never touched, and one that was never
# set is never created — this only ever deletes the empty case.
droste::blank_is_unset() {
    local v
    for v in "$@"; do
        # `${!v+set}` asks "does it EXIST", which is the same question the readers
        # above ask and the one `-z` alone cannot tell from "exists but empty".
        if [ -n "${!v+set}" ] && [ -z "${!v}" ]; then
            unset "$v"
        fi
    done
}

# ── droste::split_list — one user value into N arguments ─────────────────────
# Usage:  mapfile -d '' -t items < <(droste::split_list ';' "$value")
#
# ⭐ WHY THIS EXISTS. Several upstream options take ONE item per occurrence of the
# flag and are meant to be REPEATED — llama's --dry-sequence-breaker and
# --logit-bias are both like this. A user cannot be asked to repeat a flag inside
# an environment variable, so they give us a separated list and we do the
# repeating. Items are emitted NUL-separated so an item may contain anything,
# including the `"` that is one of llama's own default sequence breakers.
# Empty items are dropped; a wholly empty value produces nothing at all.
droste::split_list() {
    local sep=${1:?} s=${2-} item
    local -a out=()
    [ -n "$s" ] || return 0
    while IFS= read -r -d "$sep" item || [ -n "$item" ]; do
        [ -n "$item" ] && out+=( "$item" )
    done < <(printf '%s%s' "$s" "$sep")
    [ ${#out[@]} -eq 0 ] || printf '%s\0' "${out[@]}"
}

# ── droste::arg_value — read a flag's value out of an already-split argv ─────
# Usage:  v=$(droste::arg_value --api-prefix "${_extra[@]}")
# Honours both spellings a user may write, `--flag value` and `--flag=value`, and
# returns the LAST occurrence because that is what an argument parser keeps.
# Empty output means "not present" — a flag given an empty value is the same thing
# to every caller here.
droste::arg_value() {
    local want=$1; shift
    local out='' take=0 a
    for a in "$@"; do
        if [ "$take" = 1 ]; then out=$a; take=0; continue; fi
        case $a in
            "$want")   take=1 ;;
            "$want"=*) out=${a#*=} ;;
        esac
    done
    printf '%s' "$out"
}

# ── droste::set_health_prefix — tell the health probe where the routes moved ──
#
# 🚨 WHY THIS IS DECLARED AND NOT DETECTED, unlike the http/https scheme. A server
# that has been given a path prefix serves EVERY route under it — llama registers
# `api_prefix + path` for all of them (tools/server/server-http.cpp:529), so
# /health becomes /llama/health and NOTHING is left at the old path. The probe then
# gets 404, the box reads UNHEALTHY, and --health-on-failure=restart makes that a
# restart loop: the same failure as the hardcoded http:// and the same cause, us
# addressing the server by something the user moved.
# ⭐ But the FIX cannot be the same. The scheme has exactly two candidates, so one
# extra probe finds it. A prefix is an arbitrary string — there is nothing to probe
# for and the search space is unbounded. Detection is simply not available, so this
# one has to be declared by the side that knows: the box's own PRE_LAUNCH, which
# has already seen the config file by the time it runs.
#
# The value is stored VERBATIM and prepended VERBATIM, deliberately: our probe must
# compute the SAME string the server computed. If a user writes a prefix the server
# mangles (a trailing slash gives `/llama//health`), we mangle it identically and
# report unhealthy — which is CORRECT, because the server's routes really are at a
# path nothing can reach. Normalising here would make the probe pass while the box
# stayed unusable, which is the worse failure of the two.
#
# Lives in the state folder beside .SCHEME and .IS_ACTIVE, so it resets on every
# container start and a prefix that is removed simply stops applying.
droste::set_health_prefix() {
    local prefix=${1-}
    local dir=${DROSTE_SERVE_STATE_DIR:-${DROSTE_PCACHE_DIR:-/opt/program-cache}/state}
    mkdir -p "$dir" 2>/dev/null || return 0
    if [ -z "$prefix" ]; then
        rm -f "$dir/.PREFIX" 2>/dev/null
        return 0
    fi
    printf '%s\n' "$prefix" >"$dir/.PREFIX" 2>/dev/null || return 0
    serve::info "health probe will address this server under the path prefix '$prefix'."
}

# ── droste::split_args — split a catch-all setting into argv, honouring quotes ─
#
# Usage:  mapfile -d '' -t args < <(droste::split_args "${LLAMA_EXTRA_ARGS:-}")
#         SERVICE=( the-binary "${args[@]}" )
#
# 🚨 WHY NOT ${VAR:-} IN AN ARRAY, which is what all five ports used until s52:
#   1. It splits on IFS and NOTHING ELSE, so no value may contain a space. That
#      makes a whole class of upstream options UNREACHABLE through the catch-all
#      that is supposed to be the guarantee they stay reachable — llama's
#      --grammar, -j/--json-schema, -r/--reverse-prompt, --dry-sequence-breaker,
#      --override-kv, and any path with a space in it.
#   2. It also GLOB-EXPANDS. An unquoted * or ? or [..] in a value is matched
#      against the current directory, so a legitimate value silently becomes a
#      list of filenames, or silently does not.
#
# This walks the string once and honours the three quoting forms a user already
# expects from a shell: 'single' (literal), "double" (with \" and \\ escapes),
# and a backslash escape outside quotes. It performs NO variable expansion, NO
# command substitution and NO globbing — the value is data, not code. (The file
# it came from was sourced, so the user can already run anything; that is not a
# reason for a VALUE to be re-evaluated behind their back.)
#
# Output is NUL-separated so an argument may contain literally anything.
# ⚠️ An unterminated quote is reported and the partial word is kept. Refusing
# would take the box down over a typo in a config file, which is the failure mode
# this whole file exists to remove.
# shellcheck disable=SC1003  # '\' here is a LITERAL BACKSLASH being matched, not
# an attempt to escape a quote — the suggestion does not apply to this code.
droste::split_args() {
    local s=${1-} cur='' q='' c d i n=0
    local -a acc=()
    local have=0
    n=${#s}
    for (( i = 0; i < n; i++ )); do
        c=${s:i:1}
        if [ "$q" = "'" ]; then
            if [ "$c" = "'" ]; then q=''; else cur+=$c; fi
        elif [ "$q" = '"' ]; then
            if [ "$c" = '"' ]; then
                q=''
            elif [ "$c" = '\' ]; then
                i=$(( i + 1 )); d=${s:i:1}
                case $d in
                    '"'|'\') cur+=$d ;;
                    '')      cur+='\' ;;
                    *)       cur+='\'"$d" ;;   # POSIX: \ is literal before anything else
                esac
            else
                cur+=$c
            fi
        else
            case $c in
                "'")  q="'"; have=1 ;;
                '"')  q='"'; have=1 ;;
                '\')  i=$(( i + 1 )); d=${s:i:1}
                      if [ -n "$d" ]; then cur+=$d; else cur+='\'; fi
                      have=1 ;;
                ' '|$'\t'|$'\n')
                      if [ "$have" = 1 ]; then acc+=( "$cur" ); cur=''; have=0; fi ;;
                *)    cur+=$c; have=1 ;;
            esac
        fi
    done
    if [ -n "$q" ]; then
        serve::err "unterminated $q quote in an EXTRA_ARGS value — keeping the partial argument. Check the quoting in your config file."
    fi
    [ "$have" = 1 ] && acc+=( "$cur" )
    [ ${#acc[@]} -eq 0 ] || printf '%s\0' "${acc[@]}"
}
