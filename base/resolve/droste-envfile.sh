#!/usr/bin/env bash
# droste-envfile.sh — apply a box's ENV_FILE WITHOUT sourcing it into this shell.
#
# ⭐ WHY THIS FILE EXISTS (Jei, s53a). Every box's config surface is a shell file that
# both lanes used to `set -a; source; set +a` directly into the resolver's own process,
# which runs under `set -euo pipefail`. That makes the user's config file part of
# droste's control flow: a bare word on a line of its own is `command not found`, a
# reference to an unset variable is an unbound-variable abort, and either one takes the
# WHOLE BOX DOWN before the server is ever launched. Measured, not theorised — the s52
# `HF_TOKEN=$HF_TOKEN` line in llama.env did exactly that.
#
# ⭐ AND THE FIX IS NOT "STOP SOURCING". Jei corrected that twice:
#   "we should not be trying to make it easy to source or import"
#   "if sourcing solves the problem without sacrifice, that's great — but it is the
#    means; it is not the ends."
# So we keep bash's own parser (nobody wants a hand-rolled dotenv reader that disagrees
# with the shell about quoting) and move it OUT of our process:
#
#     source the file in a CHILD shell → diff `env -0` against a baseline →
#     validate the difference → apply it here.
#
# WHAT THAT BUYS, precisely:
#   · bash's parser and quoting rules, for free, byte-identical to what a user expects;
#   · `set -a` still carries every NATIVE variable (LLAMA_ARG_*, VLLM_*, HF_TOKEN …)
#     exactly as before, because the child exports them and we re-export the diff;
#   · a typo becomes a WARNING and a running box instead of a restart loop.
#
# WHAT IT COSTS, stated plainly so nobody rediscovers it as a bug:
#   · THE FILE'S SHELL STATE STOPS REACHING US. A `cd`, a function definition, a
#     `shopt`, a trap — all of it dies with the child. Only the VARIABLES the file
#     leaves behind come back. Arguably a gain: a config file is data, and treating it
#     as data is what makes the failure survivable.
#     🚨 BUT THAT IS SHELL STATE, NOT THE WORLD, AND THE DIFFERENCE MATTERS. The child
#     is a real shell with the same filesystem, network and credentials, so a config
#     file that writes a file still writes it. THIS IS NOT A SANDBOX and must never be
#     described as one. (It does not need to be: anyone who can edit this file can
#     already run anything as this box's user.) An earlier draft of this comment did
#     claim it, and g1lab/envfile.sh went red on the claim — the row is still there.
#   · The child inherits only the EXPORTED environment, so a config file can no longer
#     read a plain (unexported) shell variable belonging to the resolver. No shipped
#     template does; the only `$` on any template's right-hand side is vllm's
#     `${XDG_CACHE_HOME:-~/.cache}` form, which is unset-safe anyway.
#
# 🚨 THE CHILD RUNS `set -euo pipefail`, THE SAME AS PRODUCTION, ON PURPOSE. Loosening
# it would turn a typo'd `$LLAMA_ARG_MDOEL` into a silently empty value — a box that
# starts and is quietly misconfigured, which is worse than one that complains. We want
# the file to fail exactly where it always failed; we just no longer die with it.
#
# Sourced by droste-resolve.sh and droste-serve.sh right after droste-common.sh (both
# lanes, one behaviour — a build-spec must never have to ask which door it came in).
# Keep it free of side effects: definitions only.

# ── droste::load_env_file — the whole design, in one function ────────────────
# Usage:  droste::load_env_file "$ENV_FILE"
# Always returns 0. A config file must not be able to stop the box from starting; that
# is the entire point. Every failure path warns and leaves the environment untouched.
droste::load_env_file() {
    # ⚠️ BOTH LISTS ARE `local` ON PURPOSE, not file-level constants. serve::build_service
    # can run this a second time in the same process (the healthcheck's relaunch path),
    # and a file-level constant would by then be whatever the FIRST run exported — so a
    # config file could name its own escape hatch and turn the second run's guards off.
    #
    # Shell bookkeeping the child sets for itself. Not the user's input; never applied.
    local ignore="_ SHLVL PWD OLDPWD BASH_EXECUTION_STRING __DROSTE_ENVFILE_OK__"
    # Names a config file CAN set but almost certainly should not: they steer how every
    # later process in this box finds its code. We WARN and then apply anyway — the file
    # has always been able to set them and silently dropping a user's input is its own
    # defect ([[never-silently-ignore-user-input]]) — but an unexplained broken box is
    # worse than a noisy one.
    local loud="PATH LD_PRELOAD LD_LIBRARY_PATH BASH_ENV"
    # ── STALE DROSTE NAMES — the one thing this file CAN honestly call wrong ────
    # 🚨 THE FAILURE, MEASURED FROM THE TREE, NOT THEORISED. Every box's config file
    # is seeded `if_missing` (apply_templates.py, the `if os.path.exists(dest)`
    # skip), so a box created before a rename KEEPS its old file forever — a new
    # image never rewrites it. `5e57310` renamed every droste-owned setting from
    # <BOX>_DROSTE_* to DROSTE_<BOX>_*, so an older ds4.env says
    # `DS4_DROSTE_MODEL=/opt/models/mine.gguf` and the wiring reads
    # DROSTE_DS4_MODEL, finds nothing, and falls back to the default path in
    # targets/ds4/build-spec. Nothing is there, ds4-server exits, and
    # --health-on-failure=restart turns that into a restart loop the user does not
    # see for 90 minutes (droste-setup.sh's BOX_HEALTH_START for ds4).
    #
    # ⭐ AND THE FIX IS A WARNING, NOT A TRANSLATION. No backward compatibility is
    # owed here (Jei is the only user), so nothing renames, aliases or rewrites the
    # user's line. The deliverable is that a stale file ANNOUNCES ITSELF instead of
    # being dropped in silence — the same stance as ds4's "ds4.env no longer offers
    # either, but it is seeded if_missing" guard, and the same principle as the
    # SERVE -> STARTUP_ENABLED rename (droste-serve.sh's read_config): A RENAME MUST
    # NEVER BE SILENT. That one satisfies the principle by still working; this one
    # has to satisfy it by saying so, because working is off the table.
    #
    # 🚨 WHAT "UNRECOGNISED" MEANS HERE, AND WHY IT IS THE ONLY HONEST DEFINITION.
    # A config file is ALLOWED to carry names no droste table lists — every box
    # passes native upstream variables straight through (LLAMA_ARG_*, DS4_*, VLLM_*,
    # JUPYTER_*, HF_TOKEN …), and several boxes advertise that as a feature. So
    # "droste does not know this name" is NOT a defect and must never warn: a
    # warning that cries wolf trains the reader to ignore the channel.
    # The one claim that IS always true is about the WORD DROSTE. Droste owns it
    # outright — no upstream server, library or toolchain in these images has a
    # variable with DROSTE in its name — so a name that CONTAINS `DROSTE` and does
    # NOT START with `DROSTE_` is addressed to us, in a spelling we do not answer
    # to. That is exactly the shape of every pre-rename name and of nothing else.
    #
    # ⚠️ WHAT THIS DELIBERATELY DOES NOT CATCH: a typo INSIDE the namespace
    # (DROSTE_DS4_MODLE). Catching it needs a per-box registry of valid names, and
    # the obvious candidate — the shipped template — does not agree with the wiring
    # today: DROSTE_DS4_PORT is in ds4's value-flag table and appears nowhere in
    # ds4.env, so a template-driven check would warn about a setting that works.
    # A rule with a false positive is worse than no rule, so this arm is left out
    # until the two agree. Say it, do not silently half-implement it.
    local file=${1-}
    [ -n "$file" ] || return 0
    [ -f "$file" ] || return 0
    if [ ! -r "$file" ]; then
        serve::err "$file exists but cannot be read — starting with none of its settings applied."
        return 0
    fi

    # 1) SYNTAX, checked first because bash -n reports the LINE NUMBER and we would
    #    rather hand the user that than a generic "it did not load".
    local syntax
    if ! syntax=$(bash -n "$file" 2>&1); then
        serve::err "$file has a syntax error, so NONE of its settings were applied and this box is running on defaults. bash says: ${syntax:-(no message)}"
        return 0
    fi

    # 2) BASELINE and AFTER, from two children invoked the same way so that everything
    #    bash sets for itself cancels out of the difference.
    #    ⚠️ NEVER $( ) HERE: command substitution discards NUL bytes, and NUL is the
    #    separator that lets an env value contain a newline. Process substitution +
    #    mapfile -d '' keeps the records intact.
    local -a before=() after=()
    mapfile -d '' -t before < <(
        bash -c 'set -euo pipefail; env -0; printf "%s\0" "__DROSTE_ENVFILE_OK__=1"' \
             droste-envfile "$file" 2>/dev/null
    )
    mapfile -d '' -t after < <(
        bash -c 'set -euo pipefail; set -a; . "$1"; set +a; env -0; printf "%s\0" "__DROSTE_ENVFILE_OK__=1"' \
             droste-envfile "$file"
    )

    # ⭐ THE SENTINEL IS THE STATUS. A process substitution gives no exit code, and a
    # temp file would need a writable /tmp we have not proven. Instead the child prints
    # a final record only if it got past the source — so if the file aborted, `env -0`
    # never ran either and `after` is empty. Absence IS the failure signal, and it
    # cannot be faked by a file that merely failed halfway.
    local last=""
    [ ${#after[@]} -gt 0 ] && last=${after[$(( ${#after[@]} - 1 ))]}
    if [ "$last" != "__DROSTE_ENVFILE_OK__=1" ]; then
        serve::err "$file stopped part-way through, so NONE of its settings were applied and this box is running on defaults. The message just above (if any) is bash's own and names the line. Common causes: a bare flag name on a line of its own (it is read as a command), or a value referring to a variable that is not set."
        return 0
    fi
    if [ ${#before[@]} -eq 0 ]; then
        serve::err "could not read this box's own environment, so $file was not applied. This box is running on defaults."
        return 0
    fi

    # 3) DIFF.
    local -A base=() now=()
    local rec name
    for rec in "${before[@]}"; do
        name=${rec%%=*}
        [ -n "$name" ] && [ "$name" != "$rec" ] || continue
        base["$name"]=${rec#*=}
    done
    for rec in "${after[@]}"; do
        name=${rec%%=*}
        [ -n "$name" ] && [ "$name" != "$rec" ] || continue
        now["$name"]=${rec#*=}
    done

    # 4) VALIDATE + APPLY. `export NAME=VALUE` and never `eval`: the value came out of
    #    the child already fully expanded, so re-evaluating it here would expand a
    #    user's literal `$` a second time behind their back.
    local applied=0 removed=0
    # Where the CURRENT list of this box's settings lives, so the warning below can
    # point at it rather than describing it. The image bakes each port's templates
    # under one directory and the seeded copy keeps the template's own basename
    # (targets/*/templates/templates.yaml map <box>.env to /opt/data/<box>.env), so
    # the current example for this file is that name in the templates directory.
    # ⚠️ Mentioned ONLY if it is really there: a sentence pointing at a path that
    # does not exist is worse than the shorter sentence. The `!=` guard keeps a
    # caller who passed the template ITSELF (a test, a future dev tool) from being
    # told to go and read the file it just handed us.
    local ref="" tref
    tref=${RESOLVE_TEMPLATES_DIR:-/opt/resources/templates}/${file##*/}
    if [ -f "$tref" ] && [ "$tref" != "$file" ]; then
        ref=" This image's current example file is $tref, and it names every setting this box reads."
    fi
    for name in "${!now[@]}"; do
        case " $ignore " in *" $name "*) continue ;; esac
        if [[ ! $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            serve::warn "$file produced a variable named '$name', which is not a name a shell can carry — skipping it."
            continue
        fi
        # Unchanged from what this box already had: nothing to do, and saying so keeps
        # the applied count meaningful.
        if [ "${base[$name]+isset}" = isset ] && [ "${base[$name]}" = "${now[$name]}" ]; then
            continue
        fi
        # ⭐ HERE, AND NOT EARLIER, SO THE WARNING CAN NAME THE FILE HONESTLY. This
        # sits below the "unchanged" skip on purpose: `now` holds the child's WHOLE
        # environment, so a stale name inherited from the container's create-time
        # env — which this file did not write — reaches this loop too. Only a name
        # the file actually INTRODUCED or CHANGED gets here, which is the only kind
        # we may blame on $file.
        # ⚠️ EVERY ARM RETURNS 0. A `case` matches or does not and yields success
        # either way; nothing here may be a bare test. `[ -n … ] && …` returning
        # non-zero as the last command of a function is a measured box-killer in
        # this project (targets/vllm/build-spec, the `return 0` at the end of
        # vllm_env), and this function runs under `set -euo pipefail` in BOTH lanes.
        case $name in
            DROSTE_*) ;;
            *DROSTE*)
                serve::warn "$file sets $name, and nothing in this box reads it. Droste's own settings all START with DROSTE_ (they were spelled <BOX>_DROSTE_* in older files, e.g. DS4_DROSTE_MODEL is now DROSTE_DS4_MODEL). The value is being exported exactly as the file asks, but no droste setting is receiving it, so whatever this line was meant to change is running on its default.$ref"
                ;;
        esac
        case " $loud " in
            *" $name "*)
                serve::warn "$file changes $name, which decides where this box finds its programs and libraries. Applying it as asked — if the server stops starting, this line is the first thing to remove."
                ;;
        esac
        export "$name=${now[$name]}"
        applied=$(( applied + 1 ))
    done

    # A name the file explicitly `unset`s is a real instruction, not an omission: it is
    # the only way to take back a variable baked into the container's create-time env.
    # Sourcing in a child would normally lose that; diffing recovers it.
    for name in "${!base[@]}"; do
        case " $ignore " in *" $name "*) continue ;; esac
        [ "${now[$name]+isset}" = isset ] && continue
        [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        unset "$name"
        removed=$(( removed + 1 ))
    done

    [ "$applied" -eq 0 ] && [ "$removed" -eq 0 ] && return 0
    if [ "$removed" -gt 0 ]; then
        serve::info "applied $applied setting(s) from $file, and unset $removed the file asked to remove."
    else
        serve::info "applied $applied setting(s) from $file."
    fi
    return 0
}
