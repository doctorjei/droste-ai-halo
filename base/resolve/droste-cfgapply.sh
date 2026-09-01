#!/usr/bin/env bash
# droste-cfgapply.sh — apply a box's CFG_FILE WITHOUT sourcing it into this shell.
#
# ⭐ ONE FILE, TWO READS, TWO VERBS. A box's `<box>.cfg` is read in exactly two ways, by
# two functions that must never be mistaken for one another:
#
#   droste::cfg_get    (droste-cfg.sh)  — PARSES one SERVE setting out of the file and
#                                         NEVER sources it.
#   droste::cfg_apply  (this file)      — APPLIES all of the box's APPLICATION settings,
#                                         via a CHILD shell.
#
# The serve settings decide whether and where this box serves at all, so they are read by
# a parser that no shell semantics in the file can steer. The application settings are
# handed to bash on purpose, because a user writing a config file expects bash's own
# quoting. Same file, two contracts — and conflating the two reads is the defect class
# this whole arrangement exists to prevent. That is also why the names say `cfg`: there is
# no "env file" here, only one config file read two ways.
#
# ⭐ WHY THIS FILE EXISTS (Jei, s53a). Every box's config surface is a shell file that
# both lanes used to `set -a; source; set +a` directly into the resolver's own process,
# which runs under `set -euo pipefail`. That makes the user's config file part of
# droste's control flow: a bare word on a line of its own is `command not found`, a
# reference to an unset variable is an unbound-variable abort, and either one takes the
# WHOLE BOX DOWN before the server is ever launched. Measured, not theorised — the s52
# `HF_TOKEN=$HF_TOKEN` line in llama.cfg did exactly that.
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
#     read a plain (unexported) shell variable belonging to the resolver.
#     ⭐ AND THE RULE FOR A TEMPLATE IS NOT "NO `$`" (Jei, s57: "there may be isolated
#     cases where the user wants to grab a value from another variable"). It is a
#     WHITELIST OF ONE SHAPE: a `$` on a right-hand side may only be written
#     `${NAME<op>…}`, where NAME is a plain variable name and <op> is one of `-`, `:-`,
#     `+`, `:+`, `=`, `:=` — the six that cannot abort a source under `set -u`; nesting
#     is allowed provided every level obeys the rule; nothing else is.
#     So `${OTHER-}`, `${OTHER:-x}` and `${OTHER+x}` are fine, while `$OTHER` and
#     `${OTHER}` are BOTH box-killers, because braces alone do not help.
#     🚨 IT IS A WHITELIST AND NOT THE PROPERTY IT USED TO BE ("every `$` carries a
#     fallback"), because that property had a HOLE and could not see one form at all:
#     `${!IND-}` CARRIES THE FALLBACK AND ABORTS ANYWAY — bash answers "invalid indirect
#     expansion" whether or not a `-` is there — and `$((OTHER+1))` aborts on a name that
#     carries no `$`, so nothing anchored on `$` could ever have looked at it. Under the
#     whitelist neither needs to be thought of: `!IND` is not a plain NAME and `$((` is
#     not `${`, so both simply are not the shape.
#     ⚠️ AND `${OTHER=x}` IS ACCEPTED, WITH A SIDE EFFECT WORTH KNOWING RATHER THAN
#     BANNING. `=` also ASSIGNS, so the child comes back holding OTHER, `set -a` has
#     exported it, and the diff below carries OTHER to the server's environment too —
#     one line setting two things. That is what `:=` is FOR, and the loader counts the
#     extra name in its "applied N setting(s)" line, so it is not even quiet. `${OTHER-x}`
#     is the form that substitutes and leaves nothing behind.
#     ⭐ IT WAS BRIEFLY REFUSED HERE, ON THE ARGUMENT THAT A USER "ACQUIRES A SETTING THEY
#     NEVER WROTE"; Jei overruled it and that argument is WITHDRAWN. The only property
#     this rule enforces is unset-safety; anything else is a semantic opinion wearing a
#     safety badge. Do not reintroduce it.
#     scripts/check-env-fallbacks.sh enforces exactly that over the shipped templates (it
#     carries the whole measured form table), and the last section of g1lab/envfile.sh is
#     its suite.
#     ⚠️ SO THE COST LANDS ON THE FALLBACK, NOT ON AN ERROR PATH. A cross-reference to a
#     name the resolver holds unexported — or to one PRE_LAUNCH only sets LATER, since
#     this file is sourced first — is not reported as anything. It quietly takes the
#     fallback and looks like it worked. Document that; do not forbid it.
#
# 🚨 THE CHILD RUNS `set -euo pipefail`, THE SAME AS PRODUCTION, ON PURPOSE. Loosening
# it would turn a typo'd `$LLAMA_ARG_MDOEL` into a silently empty value — a box that
# starts and is quietly misconfigured, which is worse than one that complains. We want
# the file to fail exactly where it always failed; we just no longer die with it.
#
# Sourced by droste-resolve.sh and droste-serve.sh right after droste-common.sh (both
# lanes, one behaviour — a build-spec must never have to ask which door it came in).
# Keep it free of side effects: definitions only.

# ── droste::cfg_apply — the whole design, in one function ────────────────────
# Usage:  droste::cfg_apply "$CFG_FILE"
# Always returns 0. A config file must not be able to stop the box from starting; that
# is the entire point. Every failure path warns and leaves the environment untouched.
droste::cfg_apply() {
    # ⚠️ BOTH LISTS ARE `local` ON PURPOSE, not file-level constants. serve::build_service
    # can run this a second time in the same process (the healthcheck's relaunch path),
    # and a file-level constant would by then be whatever the FIRST run exported — so a
    # config file could name its own escape hatch and turn the second run's guards off.
    #
    # Shell bookkeeping the child sets for itself. Not the user's input; never applied.
    local ignore="_ SHLVL PWD OLDPWD BASH_EXECUTION_STRING __DROSTE_ENVFILE_OK__"
    # Names a config file CAN set but almost certainly should not. We WARN and then apply
    # anyway — the file has always been able to set them and silently dropping a user's
    # input is its own defect ([[never-silently-ignore-user-input]]) — but an unexplained
    # broken box is worse than a noisy one. Jei ruled the XDG names in on exactly that
    # standard: a power user may reasonably want to set one, and may reasonably want to
    # read one, so the answer is not to forbid it — it is to make the consequence audible.
    #
    # 🚨 A CLASS IS A SYMPTOM, NOT A MECHANISM, AND THAT IS THE WHOLE POINT. One list with
    # one sentence was wrong for the second class in the direction that matters: it
    # promised a server that stops starting, and these names do not do that. ⭐ A warning
    # that names the WRONG SYMPTOM is worse than no warning — it sends the reader looking
    # for a failure that will never arrive, and when it never arrives they conclude the
    # channel is noise. So the lists are cut by WHAT THE USER WILL SEE, and there are
    # three things to see:
    #
    #   loud_code — where this box finds its CODE. ⇒ the server DOES NOT START, loudly
    #               and immediately.
    #   loud_conf — where programs find their SYSTEM CONFIGURATION. ⇒ everything starts
    #               and runs; the image's own baked settings are silently not found.
    #   loud_dirs — where programs WRITE. ⇒ everything starts and runs correctly; data
    #               lands outside a bind and is gone at the next recreate.
    #
    # ⭐ MOVING A NAME BETWEEN THEM IS A ONE-LINE EDIT, deliberately: which hazard a
    # variable carries is a FINDING, not a constant — and s58's survey moved three of
    # them within a day of the split being written.
    #
    # 🚨 THE WHOLE XDG FAMILY, BY RULING, NOT BY MEASUREMENT (Jei, s61): "overruled. All
    # XDG variables should be treated the same; it's too confusing to have varying
    # implementation." That deliberately OVERRIDES this file's earlier standard — each
    # name earning its place by a measured consequence in THESE images — for the XDG
    # family and nothing else. ⭐ UNIFORMITY OUTRANKS MINIMALITY HERE, and the price is
    # written down rather than hidden: on a name with nothing behind a bind, the
    # moved-value sentence warns about a loss that cannot happen. That is what was
    # bought, on purpose — a family a user can reason about without a table. Same
    # instinct as s58's "let's apply the same standard to XDG_*", applied a second time.
    # ⚠️ IT IS THE SEVEN THE SPECIFICATION DEFINES, checked both ways: the freedesktop
    # basedir spec's list and every XDG name this tree references are the SAME SET, so
    # there is no eighth name to forget and no name here that nothing reads.
    #
    # 🚨 XDG_CONFIG_DIRS IS THE ONE NAME NOT IN loud_dirs, AND THAT IS NOT AN EXEMPTION
    # FROM THE RULING. It is warned about like every other member; only the SENTENCE
    # differs, because its measured consequence is READ-side and loud_dirs' is
    # WRITE-side. With DROSTE_JUPYTER_PLATFORM_DIRS on, finetuning's SYSTEM_CONFIG_PATH
    # becomes platformdirs.site_config_dir, i.e. $XDG_CONFIG_DIRS/jupyter
    # (jupyter_core/paths.py); the image covers the DEFAULT with the /etc/xdg/jupyter
    # symlink in targets/Container.finetuning. Cost of setting it: all 39 baked trait
    # defaults silently dropped — nothing written outside a bind, nothing lost at
    # recreate. Sending that user to change their data mapping would point them at a
    # failure that will never arrive, which is the exact defect the class split was
    # written to fix. ❓ NOT DECIDED HERE, FLAGGED: if the sentence is to be uniform too,
    # this is the single line to move, and it costs the accuracy above. ⚠️ IT IS TWO
    # SENTENCES TO MOVE NOW, NOT ONE — this class grew a CLEARED arm of its own (s61,
    # below), for the same reason and on the same coupling as loud_dirs'.
    #
    # ⭐ WHAT EACH NAME ACTUALLY COSTS. Kept, because a ruling on POLICY does not erase
    # the measurements — and the next reader deciding a related question will want them.
    #   XDG_CACHE_HOME  — the only XDG name that strands anything droste keeps. llama's
    #                     own HF cache chain (common/hf-cache.cpp, rung 5 of 6, and this
    #                     image sets none of the four rungs above it); vLLM's
    #                     get_default_cache_root() behind the ~/.cache/vllm bind;
    #                     huggingface_hub's HF_HOME default behind the ~/.cache/huggingface
    #                     CRITICAL bind on ALL FIVE boxes; torch's _get_torch_home() behind
    #                     the ~/.cache/torch bind on comfyui and finetuning. vllm.cfg names
    #                     it on four lines of its own.
    #   XDG_CONFIG_HOME — no bind-backed consequence on any box: its only consumer is
    #                     VLLM_CONFIG_ROOT, and ~/.config/vllm is not a bind. ⚠️ The
    #                     ~/.config/miopen bind LOOKS like a second hit and is not one —
    #                     MIOpen resolves ~ from $HOME with no XDG rung at all
    #                     (src/expanduser.cpp), and Triton is the same (knobs.py).
    #   XDG_DATA_HOME   — its only consumer is jupyter_core's jupyter_data_dir()
    #                     (kernelspecs, Lab extensions, runtime files) and droste binds
    #                     NOTHING under ~/.local/share on any box, so nothing droste
    #                     persists moves. ⚠️ finetuning.cfg OFFERS it as a setting, so a
    #                     user setting it now gets warned about their own documented knob.
    #                     That reads as an argument against including it and is the
    #                     clearest case of what the ruling chose: predictability over a
    #                     per-name verdict the user cannot see.
    #   XDG_STATE_HOME  — no reader in these five images and droste keeps nothing under
    #                     ~/.local/state.
    #   XDG_RUNTIME_DIR — per-session and non-persistent BY SPECIFICATION, so there is
    #                     nothing here to lose at recreate. It is also the one XDG name
    #                     droste itself READS (droste-setup.sh, with a fallback) — but
    #                     that read is on the HOST, and this list is about what a box's
    #                     config file sets, so the two do not meet.
    #   XDG_DATA_DIRS   — a search LIST like XDG_CONFIG_DIRS, but no measured shadowing
    #                     case: the parallel site_data_dir path holds kernelspecs and
    #                     extensions, none of which droste bakes.
    #
    # ⚠️ SCOPE, STATED SO IT IS NOT ASSUMED WIDER. This function sees the box's .cfg file
    # and NOTHING ELSE. A create-time `--env` in additional_flags (the mechanism the
    # installer itself uses) and an `export XDG_CACHE_HOME=…` typed inside `distrobox
    # enter` before running a download both reach the server without passing here, and
    # neither warns. ⚠️ And even on the route it does cover it is POST-HOC:
    # resolve::apply_spec mounts at steps 2-3 and calls this at step 6, so it reports, it
    # does not prevent. ❓ UNKNOWN, and deliberately not asserted either way: whether
    # distrobox 2.x forwards a host XDG_CACHE_HOME into the box. If it does, that is a
    # fourth route and it fires with no user opt-in at all. Nobody has read it.
    local loud_code="PATH LD_PRELOAD LD_LIBRARY_PATH BASH_ENV"
    local loud_conf="XDG_CONFIG_DIRS"
    local loud_dirs="XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_RUNTIME_DIR XDG_DATA_DIRS"
    # ── STALE DROSTE NAMES — the one thing this file CAN honestly call wrong ────
    # 🚨 THE FAILURE, MEASURED FROM THE TREE, NOT THEORISED. Every box's config file
    # is seeded `if_missing` (apply_templates.py, the `if os.path.exists(dest)`
    # skip), so a box created before a rename KEEPS its old file forever — a new
    # image never rewrites it. `5e57310` renamed every droste-owned setting from
    # <BOX>_DROSTE_* to DROSTE_<BOX>_*, so an older ds4.cfg says
    # `DS4_DROSTE_MODEL=/opt/models/mine.gguf` and the wiring reads
    # DROSTE_DS4_MODEL, finds nothing, and falls back to the default path in
    # targets/ds4/build-spec. Nothing is there, ds4-server exits, and
    # --health-on-failure=restart turns that into a restart loop the user does not
    # see for 90 minutes (droste-setup.sh's BOX_HEALTH_START for ds4).
    #
    # ⭐ AND THE FIX IS A WARNING, NOT A TRANSLATION. No backward compatibility is
    # owed here (Jei is the only user), so nothing renames, aliases or rewrites the
    # user's line. The deliverable is that a stale file ANNOUNCES ITSELF instead of
    # being dropped in silence — the same stance as ds4's "ds4.cfg no longer offers
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
    # ds4.cfg, so a template-driven check would warn about a setting that works.
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
             droste-cfgapply "$file" 2>/dev/null
    )
    mapfile -d '' -t after < <(
        bash -c 'set -euo pipefail; set -a; . "$1"; set +a; env -0; printf "%s\0" "__DROSTE_ENVFILE_OK__=1"' \
             droste-cfgapply "$file"
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
    # (targets/*/templates/templates.yaml map <box>.cfg to /opt/data/<box>.cfg), so
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
        case " $loud_code " in
            *" $name "*)
                serve::warn "$file changes $name, which decides where this box finds its programs and libraries. Applying it as asked — if the server stops starting, this line is the first thing to remove."
                ;;
        esac
        # ⚠️ THIS ARM EXISTS BECAUSE loud_code's SENTENCE IS FALSE FOR XDG_CONFIG_DIRS ON
        # BOTH HALVES, checked rather than assumed (s58). It does not decide where code
        # comes from — it decides where system CONFIGURATION comes from; and "if the
        # server stops starting" never fires, because all 39 baked Jupyter traits are
        # behavioural and the server starts happily without a single one of them. Filing
        # it under loud_code would have reproduced the exact defect the split was written
        # to fix, one class along. Same mechanism as loud_code, different symptom, and
        # the symptom is what the message has to be true about.
        #
        # 🚨 AND IT NEEDS THE SAME TWO ARMS AS loud_dirs BELOW, ON THE SAME COUPLING —
        # THIS IS WHERE THE CLEARED-VALUE DEFECT SURVIVED AFTER loud_dirs WAS SPLIT.
        # XDG_CONFIG_DIRS is a member of the XDG family, so the per-box blank guard in
        # PRE_LAUNCH unsets it one step after this function runs (resolve::apply_spec
        # calls cfg_apply at step 6 and PRE_LAUNCH at step 7, and the guard is ONE loop
        # over all seven names — it does not stop at loud_dirs' six). A cfg line
        # `XDG_CONFIG_DIRS=` therefore leaves the box looking exactly where it always
        # looked: /etc/xdg, where targets/Container.finetuning puts its jupyter symlink.
        # ⭐ EVERY CLAUSE OF THE MOVED-VALUE SENTENCE IS FALSE FOR THAT FILE — nothing
        # points away from the standard location, nothing falls back to an upstream
        # default, and all 39 baked traits are found. A message naming the wrong symptom
        # is the exact defect the class split exists to prevent, so it is no more
        # acceptable here than it was one class along.
        # ⚠️ THE CLEARED SENTENCE IS THIS CLASS'S OWN AND NOT A COPY OF loud_dirs'. What
        # the user goes on getting here is the image's BAKED SETTINGS; there it is their
        # BOUND STORAGE. Borrowing the other arm's words would re-merge the two classes
        # in the one place the reader can actually see them — the wording.
        # ⚠️ AND LIKE loud_dirs' CLEARED ARM IT STATES DROSTE'S CONTRACT (a blank is an
        # absence, Jei s57) rather than a fact about the box, because the guard is a
        # per-box PRE_LAUNCH concern and cannot be seen from here. The two ship together
        # or this sentence is false in the other direction.
        case " $loud_conf " in
            *" $name "*)
                if [ -z "${now[$name]}" ]; then
                    serve::warn "$file has a line that clears $name — the name with nothing after it. Droste reads a blank as the setting being absent, so nothing is pointed away: programs in this box go on finding the settings this image bakes in at the standard location, and none of them is dropped. The box will start normally. But the line is having no effect at all, so if it was meant to send programs somewhere else, it has not — give it a value, or remove it."
                else
                    serve::warn "$file changes $name, which decides where this box looks for the system-wide configuration its programs read at startup. Applying it as asked, and the box will start normally — but the settings this image bakes in sit at the standard location this points away from, so a program that can no longer find them falls back to its own upstream defaults instead. Nothing announces that. If this box has quietly stopped behaving the way the image set it up to, this line is the first thing to remove."
                fi
                ;;
        esac
        # 🚨 TWO SENTENCES, BECAUSE CLEARING ONE OF THESE AND MOVING IT HAVE OPPOSITE
        # OUTCOMES, AND NO ONE MESSAGE IS TRUE OF BOTH. MEASURED, not reasoned: a cfg line
        # `XDG_CACHE_HOME=` leaves the name set-and-empty when this function returns
        # (resolve step 6), and the per-box blank guard inside PRE_LAUNCH (step 7 —
        # droste-resolve.sh calls cfg_apply then PRE_LAUNCH, in that order) unsets it, so a
        # program resolving ${XDG_CACHE_HOME:-~/.cache} lands back on the bound ~/.cache.
        # Nothing is redirected, nothing leaves a bind, nothing is gone at the next
        # recreate — EVERY clause of the moved-value sentence is false for that case, and a
        # warning naming the wrong symptom is precisely what this class split exists to
        # prevent.
        # ⚠️ THE CLEARED ARM IS COUPLED TO THAT GUARD EXISTING, on every box and for every
        # name in this list. The guard is a per-box PRE_LAUNCH concern and cannot be seen
        # from here, so this arm states droste's contract (a blank is an absence, Jei s57)
        # rather than a fact about the box. The two changes ship together or this sentence
        # is false in the other direction.
        # 🚨 AND THE COUPLING HAS TWO DEPENDANTS HERE, NOT ONE. loud_conf's cleared arm
        # above rests on the SAME guard, because that guard is one loop over all seven
        # XDG names while this list holds six. Whoever removes or narrows it has to fix
        # BOTH arms; finding only this one leaves the other lying.
        # ⚠️ AND IT WARNS RATHER THAN GOING SILENT. A line droste turns into an absence is
        # still a line the user wrote and did not get ([[never-silently-ignore-user-input]]);
        # silence would leave them believing it took effect, which is the failure mode the
        # no-fall-through rule is about. The warning is what makes the no-op audible.
        case " $loud_dirs " in
            *" $name "*)
                if [ -z "${now[$name]}" ]; then
                    serve::warn "$file has a line that clears $name — the name with nothing after it. Droste reads a blank as the setting being absent, so nothing is redirected: programs in this box go on writing to the standard location, which is where your host's storage is bound, and nothing is lost. The box will start normally. But the line is having no effect at all, so if it was meant to move something, it has not — give it a value, or remove it."
                else
                    serve::warn "$file changes $name, which decides where programs in this box write their caches and data. Applying it as asked, and the box will start normally — but droste binds your host's storage at the standard locations, and this points programs somewhere else. Whatever follows it out of a bind — the model cache above all — is written inside the container instead: it looks fine for as long as this box runs, and it is gone the next time the box is recreated. To move that data on your host, change the box's data mapping in the installer rather than redirecting it from here."
                fi
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
