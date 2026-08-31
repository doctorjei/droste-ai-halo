#!/usr/bin/env bash
# droste-cfg.sh — read ONE serve setting out of an `<box>.cfg` WITHOUT SOURCING IT.
#
# ⭐ WHY THIS FILE EXISTS (case 2, s59). `server.env` is deleted and the five serve
# settings move into the box's own `<box>.cfg`, which is ALSO the file both resolvers
# source (under `set -a`) to hand the app its native settings. ONE FILE, TWO READS, TWO
# VERBS — and the names say which is which:
#   • `droste::cfg_apply` (droste-cfgapply.sh) APPLIES all of the APP settings, by
#     SOURCING the file in a child shell — that is what makes it a config surface;
#   • `droste::cfg_get` (this file) PARSES one SERVE setting, by SCANNING, and NEVER
#     sources.
# They must not be the same read, because the second one runs somewhere the first is not
# allowed to fail: the healthcheck fires every 30 s, and `--health-on-failure=restart`
# turns any abort there into a container restart loop that ejects every interactive shell
# in the box. A user's typo in their own config file must never be able to do that. That
# property is why `serve::read_config` uses a discarding subshell today; "parse, never
# source" is what preserves it once the settings move.
#
# ⭐ IT IS A CONFIG FILE, AND THAT DECIDES EVERY RULE BELOW (Jei, s60: "i do not want to
# mimic sourcing. this is a config file"). The same file IS sourced a few milliseconds
# later for the app settings, so what bash does with a given shape is EVIDENCE about what
# the person who typed it probably meant — never the authority. An earlier draft of this
# header asserted the opposite ("the parser must agree with the shell") and left several
# rules standing on that reason. The rules were right; the reason was not, and a rule
# standing on a retired reason is the next reader's trap. ⚠️ Where a comment in this file
# states a principle it names WHOSE principle it is, or it does not state one.
#
# So no rule below is justified by "bash does it this way". Each stands on its own, and
# where this parser and `source` differ the difference is stated at the rule:
#   • the LAST active assignment wins — later-overrides-earlier is what a config file means;
#   • `export NAME=v` is honoured — users write it in files like this, and dropping it
#     would discard their input;
#   • an unquoted value's interior spaces are kept WHOLE — a config file does not
#     word-split; the value is the text;
#   • text after a CLOSING quote is dropped — the value is the quoted span, full stop;
#   • `NAME= 8188` reads as `8188`, where bash would leave the variable unset entirely.
#
# 🚨 TWO IMPLEMENTATIONS, UNAVOIDABLE. `droste-setup.sh` is a standalone `curl | bash`
# script on the HOST and cannot source a file that lives inside an image, so it carries its
# own `cfg_get` implementing this identical rule. A differential harness over one fixture
# corpus is therefore MANDATORY — a rule that lives in two places needs a test that they
# agree, or it is one rule pretending. Local unit coverage: `~/workspace/g1lab/cfgparse.sh`.
#
# Sourced by droste-healthcheck.sh, droste-serve.sh and droste-resolve.sh, all of which run
# under `set -euo pipefail`. Keep it free of side effects: definitions only, no state
# outside the one memo variable below, nothing that assumes a lane.

# ── THE FIVE SETTINGS ────────────────────────────────────────────────────────
# Documentation only — `droste::cfg_get` is parameterised by NAME and does not police the
# list. The five-name restriction belongs to the CALLER, because the parser is also what
# the differential harness drives against arbitrary fixture names.
#
# 🚨 THE PREFIX IS PER BOX — `DROSTE_<APP>_`, THE APPLICATION, NOT THE BOX. The names
# below were written `DROSTE_SERVE_*` while this file was being built; that prefix was
# retired before it ever shipped (Jei, s59: *"DROSTE_<APP>_PORT and DROSTE_<APP>_HOST I
# think are the right calls here… for all of these, to avoid confusion"*) and it now
# exists NOWHERE in the tree. Corrected s60.
# ⚠️ finetuning's are `DROSTE_JUPYTER_*` — the APPLICATION, not the box; it is the only
# one of the five where the distinction is observable, which is what settles it.
# The caller supplies the prefix (`SERVE_CFG_PREFIX`); this parser never builds a name.
#
#   DROSTE_<APP>_STARTUP_ENABLED   start this box's server when the BOX starts
#   DROSTE_<APP>_HOST              address the server BINDS
#   DROSTE_<APP>_PORT              port it BINDS (host networking: nothing is remapped)
#   DROSTE_<APP>_TLS_CERT          PEM certificate path
#   DROSTE_<APP>_TLS_KEY           PEM private key path
#
# ⭐ TLS IS ON IFF BOTH CERT AND KEY ARE SET — derived by the caller, never declared here.
# One set and not the other is a CONFIG ERROR to be reported, not silently half-applied.
# ⭐ `STARTUP_ENABLED` (user, persistent, lives here) and `state/.IS_ACTIVE` (machine,
# reset at every container start) MUST NOT RE-MERGE. Their conflation is the bug
# serve-lifecycle-s44 exists to remove. A file is a location; a lifetime is a contract —
# only the location moved.

# ── droste::_cfg_note — one human message, at most once per process ──────────
#
# Rule 6 requires an unreadable file to yield "absent" for every name PLUS a human message:
# silence there would turn a permissions mistake into a box that mysteriously ignores its
# own config. But `cfg_get` is called once per NAME, so a naive warn gives five identical
# lines for one broken file; the memo collapses them.
#
# ⚠️ THE MEMO IS BEST-EFFORT AND CANNOT BE ANYTHING ELSE. The normal call shape is
# `v=$(droste::cfg_get NAME)`, i.e. a command substitution, and a subshell's assignment to
# `_DROSTE_CFG_SEEN` dies with the subshell. So the dedup works for in-shell callers and
# quietly does nothing for substitution callers. That is the correct trade: the alternative
# is persisting state to disk, and a PARSER MUST NOT WRITE ANYTHING — it is the one thing
# that runs on a box whose filesystem may be exactly what is broken.
#
# Delegates to serve::warn when the sourcing lane has one, so the message carries that
# lane's prefix. It does NOT define serve::warn — droste-common.sh owns that conditional
# definition and two files racing to provide it is how prefixes go wrong.
_DROSTE_CFG_SEEN=${_DROSTE_CFG_SEEN:-}
droste::_cfg_note() {
    local key=${1-} msg=${2-}
    case $'\n'"$_DROSTE_CFG_SEEN"$'\n' in
        *$'\n'"$key"$'\n'*) return 0 ;;
    esac
    _DROSTE_CFG_SEEN="${_DROSTE_CFG_SEEN}${_DROSTE_CFG_SEEN:+$'\n'}${key}"
    if declare -F serve::warn >/dev/null 2>&1; then
        serve::warn "$msg"
    else
        printf 'droste: WARN: %s\n' "$msg" >&2
    fi
    return 0
}

# ── droste::_cfg_unquote — everything after the `=` becomes a value ──────────
# Usage: droste::_cfg_unquote RAW [NAME]   (NAME only names the setting in a warning)
#
# Writes its answer into `_droste_cfg_v`, which the caller declares `local`. Bash's dynamic
# scoping makes that visible here, and it buys a fork per matching line back — worth it in
# a function the healthcheck runs every 30 s.
#
# 🚨 THE ORDER OF THE FIRST TWO STEPS IS LOAD-BEARING (ruled s60, and the contract says so
# in capitals because two implementations of it will otherwise drift apart):
#   1. strip LEADING whitespace from the raw text after the `=`. This is where `NAME= 8188`
#      becomes `8188`, and it is the one place this reader takes a line bash would refuse
#      outright (it would leave the variable unset). There is no reading of a CONFIG FILE
#      under which the user meant anything else by it;
#   2. THEN ask whether the value is quoted — i.e. whether the first character is NOW a
#      quote. `NAME= "a b"` is a QUOTED value whose answer is `a b`. Asking first and
#      stripping second classifies it as unquoted and hands back the literal text `"a b"`,
#      quote marks and all;
#   3. quoted ⇒ the value is the span up to the first matching closing quote, and NOTHING
#      INSIDE IT IS EVER STRIPPED. `NAME="   "` is three spaces and it is a real VALUE —
#      "   " is a legal file name on Linux (Jei, s60), which is also why the TLS checks
#      elsewhere test a path's EXISTENCE and never its plausibility;
#   4. unquoted ⇒ cut the inline comment, then strip TRAILING whitespace.
# ⭐ The single discriminator is THE QUOTE, which is the user's own declaration of where
# the value ends. It decides this section and the continuation rule in `cfg_get` alike. It
# is not a guess about what the value looks like, and no value-shaped test belongs here.
#
# 🚨 INLINE COMMENTS ARE STRIPPED, AND THIS IS NOT OPTIONAL. Every template in this project
# documents its settings on the assignment line itself — measured at the tip: 152 such lines
# in llama.cfg, 119 in vllm.cfg, 22 in ds4.cfg, 17 in finetuning.cfg, 2 in comfyui.cfg. The
# user turns a setting on by DELETING THE LEADING `#`, which leaves
# `DROSTE_LLAMA_PORT=8188        # port it binds`. A parser that took the rest of the line
# would read that port as `8188        # port it binds`, i.e. it would hand the user's
# DOCUMENTATION to the server as part of its configuration. The cut is at the first `#`
# that begins the value or follows whitespace (`FOO=a#b` keeps the `#`; `FOO=a #b` does
# not) — that is the convention every one of these files is written in, and users already
# read it that way.
#
# ⚠️ AN UNQUOTED VALUE'S INTERIOR SPACES ARE KEPT WHOLE. A config file does not word-split:
# the value is the text the user typed. `DROSTE_LLAMA_TLS_CERT=/opt/my certs/a.pem` comes
# back entire, so an error message names the exact string they wrote rather than a path
# they never wrote. (The templates still tell users to quote values containing spaces —
# unquoted leaves them at the mercy of the comment cut and the trailing strip.)
#
# ⚠️ TEXT AFTER A CLOSING QUOTE IS DROPPED. The value is the quoted span, full stop: once
# the user has declared where the value ends, what follows is not part of it. In practice
# what follows is `DROSTE_LLAMA_EXTRA_ARGS="…"   # example only`, a trailing comment.
#
# ⚠️ AN UNTERMINATED QUOTE WARNS AND FALLS THROUGH TO THE UNQUOTED PATH BELOW. State the
# return exactly, because it is not "the line as typed" and an earlier version of the
# warning said it was (§2c, corrected s60): the OPENING QUOTE IS KEPT — there was no pair
# to strip — and then the inline-comment cut and the trailing-whitespace strip apply, so
# `NAME="a #b` returns `"a`. Any continuation the text asked for has already happened, and
# the `\` that asked for it is gone (`NAME="a\` at EOF is `"a`).
# ⭐ RE-READING A LINE WE HAVE ALREADY DECLARED MALFORMED WOULD ADD A RULE WITHOUT ADDING
# VALUE, which is why the fall-through stays and only the sentence changed. The message's
# job is to say what is wrong with the user's FILE, not to narrate our return value — so it
# no longer describes it at all. Refusing to answer instead would take the box down over a
# config-file typo, which is the failure this whole file exists to remove.
# ⚠️ Read the fall-through below literally: an unterminated quote is then processed by the
# UNQUOTED path, so the inline-comment cut and the trailing-whitespace strip still apply to
# it. Both implementations of this contract have always done that and they agree; it is
# recorded here so it is not "fixed" by one of them alone.
#
# ⚠️ AN UNQUOTED VALUE ENDING IN `\` WARNS. Continuation works inside quotes only, so that
# backslash is a byte of the value — but a user who typed it at the end of a line was
# almost certainly reaching for the continuation, and silently keeping it would leave them
# with a path that has a stray backslash on the end and no idea why.
#
# NO ESCAPE PROCESSING AND NO EXPANSION, in either quoting form: a `$` in the value comes
# back verbatim and is the caller's problem, never the parser's. The value is DATA. (The
# file is sourced elsewhere, so the user can already run anything they like — that is not a
# reason for this read to re-evaluate a value behind their back.)
droste::_cfg_unquote() {
    local raw=${1-} name=${2-} q rest quoted=''
    _droste_cfg_v=''

    # STEP 1 — leading whitespace, BEFORE anything is asked about quoting. `cfg_get` has
    # already done this (it needs the quoted/unquoted answer for its continuation test);
    # the strip is idempotent, and repeating it here keeps this function correct for a
    # caller that drives it directly, which the differential harness does.
    while [ -n "$raw" ] && [ "$raw" != "${raw#[[:space:]]}" ]; do
        raw=${raw#[[:space:]]}
    done

    # STEP 2 — quoted?  Asked only now.
    case $raw in
        '"'*|"'"*)
            quoted=1
            q=${raw:0:1}
            rest=${raw:1}
            case $rest in
                *"$q"*)
                    # `%%` removes the LONGEST matching suffix, i.e. it cuts at the FIRST
                    # closing quote — which is the one that matches the opening quote.
                    _droste_cfg_v=${rest%%"$q"*}
                    return 0
                    ;;
            esac
            droste::_cfg_note "unterminated:${name}:${q}:${raw}" \
                "unterminated $q quote in $name — check the quoting in your config file"
            ;;
    esac

    # Unquoted (or an unterminated quote, which reaches here on purpose — see above).
    # Cut the inline comment, then the trailing whitespace the cut leaves behind (and the
    # trailing whitespace a user leaves behind when no comment is present).
    local v=$raw
    case $v in
        '#'*)                 v='' ;;
        *[[:space:]]'#'*)     v=${v%%[[:space:]]'#'*} ;;
    esac
    # `[[:space:]]` also covers the CR of a file saved with DOS line endings. An invisible
    # byte inside a port number or a path is a bug report nobody can read, and no user ever
    # meant the CR to be part of the value.
    while [ -n "$v" ] && [ "$v" != "${v%[[:space:]]}" ]; do
        v=${v%[[:space:]]}
    done

    # The trailing-backslash warning is for UNQUOTED values only. An unterminated quote
    # reaches this line too and has already had its own say; two messages for one typo
    # would name two different problems, only one of which is real.
    if [ -z "$quoted" ]; then
        case $v in
            *'\')
                droste::_cfg_note "backslash:${name}:${v}" \
                    "$name ends with a backslash — line continuation only works inside quotes, so the backslash is part of the value"
                ;;
        esac
    fi

    _droste_cfg_v=$v
    return 0
}

# ── droste::_cfg_take_export — strip ONE leading `export` keyword ────────────
# Usage: droste::_cfg_take_export LINE  → the remainder in `_droste_cfg_l`.
#
# 🚨 `export NAME=value` IS AN ASSIGNMENT AND IS HONOURED (ruled s59, and it overturned this
# file's first reading of rule 2). The strict reading — "after leading whitespace, the line
# matches NAME=" — excludes it, but users write `export` in files like this one, and a
# reader that dropped the line would discard input its author plainly intended as a setting.
# That the file is also SOURCED for the app settings is why the shape turns up here at all;
# it is not why we honour it.
# ⚠️ A WORD BOUNDARY IS REQUIRED: `exportNAME=v` is a command named `exportNAME`, not an
# assignment, and must not match. The pattern demands whitespace after the keyword.
# ⚠️ Exactly ONE `export` is consumed. Deeper stacking is not imitated: it is not a shape
# any user writes, and guessing at it is how two implementations of one rule start to differ.
# ⭐ IT IS A FUNCTION BECAUSE TWO CALLERS NEED THE SAME ANSWER — the fold's predicate and
# the reader's name test must accept exactly the same assignment shape, or a span could open
# on a line the reader later refuses to see as an assignment. One definition, one place to
# change, and one place for a mutation test to aim at.
droste::_cfg_take_export() {
    _droste_cfg_l=${1-}
    case $_droste_cfg_l in
        'export'[[:space:]]*)
            _droste_cfg_l=${_droste_cfg_l#export}
            while [ -n "$_droste_cfg_l" ] && [ "$_droste_cfg_l" != "${_droste_cfg_l#[[:space:]]}" ]; do
                _droste_cfg_l=${_droste_cfg_l#[[:space:]]}
            done
            ;;
    esac
    return 0
}

# ── droste::_cfg_open_quote — "does this line leave a quote open?" ───────────
# Usage: droste::_cfg_open_quote LINE   → `_droste_cfg_q` is the open quote character, or
# empty. The caller declares `_droste_cfg_q` local, as with `_droste_cfg_v`.
#
# 🚨 IT TAKES NO NAME, AND THAT IS ITS ENTIRE REASON FOR EXISTING. This is the half of the
# line structure that must be decided WITHOUT knowing what the caller is looking for: the
# fold in `cfg_get` uses it to find where one logical line ends, and a fold that consulted
# `$name` would give a file as many different line structures as it has settings.
#
# "An assignment" here is the same shape the reader accepts one step later — optional
# leading whitespace, optional `export` plus whitespace, then `IDENT=` — and NOTHING else.
# ⚠️ THE IDENTIFIER TEST IS NOT DEFENSIVENESS, IT IS THE PREDICATE. Without it a `#`
# comment ending in `\`, or a line of prose carrying a stray quote, would continue onto the
# next line and swallow a real setting. `# DROSTE_LLAMA_PORT="8188\` must fold nothing.
# ⚠️ The value's LEADING WHITESPACE comes off before the quote test here too — the same
# load-bearing order as `_cfg_unquote`'s steps 1 and 2, for the same reason: `NAME= "a\` is
# a quoted value and must be seen as one.
droste::_cfg_open_quote() {
    local line=${1-} head rhs q rest _droste_cfg_l=''
    _droste_cfg_q=''

    while [ -n "$line" ] && [ "$line" != "${line#[[:space:]]}" ]; do
        line=${line#[[:space:]]}
    done
    droste::_cfg_take_export "$line"; line=$_droste_cfg_l

    case $line in
        *=*) ;;
        *)   return 0 ;;                     # no `=` at all: not an assignment
    esac
    head=${line%%=*}                         # everything before the FIRST `=`
    [ -n "$head" ] || return 0               # `=value` names nothing
    case $head in
        [0-9]*) return 0 ;;                  # an identifier cannot start with a digit
    esac
    [ -z "${head//[A-Za-z0-9_]/}" ] || return 0

    rhs=${line#"$head"=}
    while [ -n "$rhs" ] && [ "$rhs" != "${rhs#[[:space:]]}" ]; do
        rhs=${rhs#[[:space:]]}
    done
    case $rhs in
        '"'*|"'"*) q=${rhs:0:1} ;;
        *)         return 0 ;;               # unquoted ⇒ nothing is open
    esac
    rest=${rhs:1}
    case $rest in
        *"$q"*) return 0 ;;                  # the quote closes on this line
    esac

    _droste_cfg_q=$q
    return 0
}

# ── droste::cfg_get — THE ENTRY POINT ────────────────────────────────────────
# Usage:  value=$(droste::cfg_get DROSTE_LLAMA_PORT [/path/to/app.cfg])
#
# Prints the value (possibly empty) on stdout and ALWAYS EXITS 0. Empty output means
# "absent" — rule 5: a blank value is treated exactly as absent, so blank means "no
# opinion" and the caller applies droste's per-box default.
#
# FILE defaults to `${CFG_FILE:-}`; with neither an argument nor `CFG_FILE`, the answer is
# empty. A box with no config file is a normal state, not a fault, so that case is SILENT —
# only a file that EXISTS and cannot be read earns a message.
#
# 🚨 THE LAST ACTIVE ASSIGNMENT WINS, which is why the scan cannot stop early.
# Later-overrides-earlier is what a config file MEANS: a user who adds a line at the bottom
# is changing the setting, not adding a second opinion to be arbitrated.
# 🚨 AND `cfg_get` MUST NOT WARN ABOUT A DUPLICATE ASSIGNMENT. That warning exists (the
# installer's `cfg_set` owns it, and leaves every earlier line exactly as the user wrote
# it), but this half runs in the healthcheck probe path — every 30 s in a FRESH PROCESS, so
# the memo below cannot dedup across runs and the box would log the same sentence ~2,880
# times a day. ⭐ A warning that repeats forever trains the reader to ignore the log, which
# costs us the warnings that matter.
#
# 🚨 NEVER FAILS, NEVER ABORTS THE CALLER. The read loop sits on the left of a `|| true`,
# which suspends `errexit` for the whole compound — so even a file yanked out from under us
# between the `-r` test and the redirect yields "absent" rather than a dead healthcheck.
# ⚠️ The flip side, stated so nobody is surprised by it: a genuine bug inside that loop is
# silent too. The harness is the compensating control.
#
# ⚠️ NON-REGULAR FILES ARE "ABSENT" BY DESIGN. `-f` excludes directories (whose redirect
# would fail) and FIFOs (whose redirect would BLOCK — a hung healthcheck is worse than a
# wrong one, and there is no timeout available here).
#
# ── THREE CASES THAT ARE SETTLED, NOT ACCIDENTS ──────────────────────────────
# Both implementations of this contract already behaved this way and neither said so, which
# is how an agreement gets "fixed" by one side. Written down s60 so it cannot be:
#   1. A BINARY FILE CONTAINING ONE WELL-FORMED LINE yields that line's value. There is no
#      sniffing and no rejection: this reader has no opinion about the bytes around the
#      line it was asked for.
#   2. A LAST LINE WITH NO TRAILING NEWLINE IS A LINE and is read — that is what the
#      `|| [ -n "$line" ]` on the loop's `read` is for, and the continuation join below
#      repeats the trick for the same reason. (The installer's `cfg_set` must not GROW one
#      either: a file whose last line lacked a newline still lacks one afterwards.)
#   3. NO TRAILING NEWLINE IS PRINTED. Callers use `$( )`, which would strip one anyway, so
#      the two are indistinguishable there — but the differential harness compares bytes,
#      and a future "tidy-up" that added a `printf '%s\n'` would be a silent contract break.
droste::cfg_get() {
    local name=${1-} file=${2-}

    [ -n "$name" ] || { printf '%s' ''; return 0; }
    [ -n "$file" ] || file=${CFG_FILE:-}
    [ -n "$file" ] || { printf '%s' ''; return 0; }

    # NAME must be a shell identifier. Not defensiveness for its own sake: `name` is used
    # inside a glob pattern below, so a metacharacter in it would silently match lines it
    # has no business matching — and a name that is not an identifier cannot be an
    # assignment in the sourced file either, so the honest answer is "absent".
    case $name in
        [0-9]*) name='' ;;
        *) [ -z "${name//[A-Za-z0-9_]/}" ] || name='' ;;
    esac
    if [ -z "$name" ]; then
        droste::_cfg_note "badname:${1-}" \
            "'${1-}' is not a valid variable name — treating it as unset"
        printf '%s' ''
        return 0
    fi

    [ -f "$file" ] || { printf '%s' ''; return 0; }
    if [ ! -r "$file" ]; then
        droste::_cfg_note "unreadable:$file" \
            "cannot read $file — every setting in it reads as unset; check its permissions"
        printf '%s' ''
        return 0
    fi

    local line val cont='' out='' _droste_cfg_v='' _droste_cfg_q='' _droste_cfg_l=''
    {
        while IFS= read -r line || [ -n "$line" ]; do
            # Rule 2: leading whitespace is allowed before the name, so it is removed
            # before anything is decided about the line. One character at a time, because
            # the alternatives all need extglob or an external command and this file may
            # not change the sourcing shell's options.
            while [ -n "$line" ] && [ "$line" != "${line#[[:space:]]}" ]; do
                line=${line#[[:space:]]}
            done

            # ── FOLD PHYSICAL LINES INTO ONE LOGICAL LINE (§2, ruled s60) ───────────
            # 🚨 THIS RUNS BEFORE ANY TEST INVOLVING `$name`, AND THAT ORDER IS THE WHOLE
            # POINT. A file has ONE line structure and it does not depend on what we came
            # looking for. Folding after the name test was a real defect (caught s60 by the
            # differential harness, which the single-lane suite structurally cannot see,
            # because it only ever queries the name that STARTS the span):
            #     DROSTE_LLAMA_HOST="a\
            #     DROSTE_LLAMA_PORT=9999\
            #     b"
            # is ONE assignment of HOST. Asked for PORT, a name-dependent fold skips line 1
            # (wrong name, `continue`) and then reads line 2 as an assignment in its own
            # right, answering `9999\` for a setting the file never sets. ⭐ A PARSER WHOSE
            # NOTION OF "A LINE" CHANGES WITH ITS ARGUMENT WILL DISAGREE WITH ITSELF.
            #
            # ⭐ THE QUOTE IS THE USER'S DECLARATION OF THE VALUE'S BOUNDARY, and that one
            # discriminator decides this as well as the whitespace rule: a value whose end
            # the user has declared may span physical lines; a bare one may not. Outside
            # quotes a trailing `\` is simply a byte of the value, and `_cfg_unquote` warns
            # about it because someone who typed it was usually reaching for this feature.
            #
            # THE PREDICATE IS DELIBERATELY NARROW — all three, re-evaluated on the text as
            # it grows: the line ENDS IN `\`; it is an ASSIGNMENT (optional `export`, then
            # `IDENT=`); and its value OPENS A QUOTE that does not close on it. So a `#`
            # comment ending in `\` continues NOTHING, and neither does prose carrying a
            # stray quote — continuation exists only inside an assignment's quoted value.
            # ⭐ The backslash is the ONLY continuation signal, and that is what keeps the
            # scan BOUNDED: nothing is read ahead speculatively, a file with no
            # continuations is scanned exactly as it was before this existed, and an
            # unterminated quote stays the error it is instead of becoming a reason to read
            # the rest of the file. It is also the cheap test, so it is asked first and
            # `_cfg_open_quote` never runs on the overwhelming majority of lines.
            # 🚨 THE JOIN STOPS AT A LINE THAT DOES NOT END IN `\`, EVEN WITH THE QUOTE
            # STILL OPEN (§2b, corrected s60 after a blind harness row caught the contract
            # contradicting itself). `NAME="a\` / blank / `b"` stops at the BLANK line and
            # yields `"a` plus the unterminated-quote warning — it does NOT reach the `b"`.
            # Continuing while a quote is open is the speculative forward scan this
            # contract refuses: an unbounded scan on the healthcheck's path is the failure
            # the whole file is designed away from.
            # ⚠️ THE JOINED LINES ARE CONSUMED: the inner `read` shares this loop's
            # redirection, so a line inside a span can never also be read as an assignment
            # of its own — for ANY name, which is exactly what the defect above got wrong.
            # (The writer half belongs to the installer's `cfg_set`, which must replace ALL
            # N lines or it strands the continuation lines in the file as live junk.)
            # ⭐ §2d — THE ASSIGNMENT'S SPAN IS EXACTLY WHAT THIS FOLD CONSUMED, including
            # the line that STOPPED it: the blank line above was read here, so it belongs
            # to the assignment and the writer removes it too. One definition, and it keeps
            # reader and writer in step by construction — a writer with its own opinion
            # about where an assignment ends is the corruption case named above.
            # ⚠️ THE TRAILING `\` IS CONSUMED AS THE SIGNAL, whether or not a line turns
            # out to follow it — so an open quote at EOF yields `"a`, exactly as the blank
            # line does. The two agreeing is the check that the rule is being read right.
            # 🚨 EXACTLY ONE TRAILING BACKSLASH IS CONSUMED — THE LAST ONE. Anything in
            # front of it is DATA, so `NAME="a\\` / `b"` is `a\b`, not `ab`. There is no
            # odd/even counting: a `\` at the end of the line always continues, and exactly
            # one character comes off. ⭐ The tie-break is this parser's bedrock rule — NO
            # ESCAPE PROCESSING, A BACKSLASH IS DATA. Removing the whole RUN would treat a
            # sequence of backslashes specially, which is escape processing wearing a
            # different hat, and it would silently destroy bytes the user typed (ruled s60,
            # after two independent readers of the contract split on it).
            # ⚠️ The real limitation, and it is worth knowing before you wrap a Windows
            # path: there is no way to end a continued line with a literal backslash AND
            # stop continuing. Put the backslash somewhere other than the line's last
            # character, or close the quote on that line.
            while :; do
                case $line in
                    *'\') ;;                    # a continuation signal…
                    *)    break ;;              # …none, so this logical line is complete
                esac
                droste::_cfg_open_quote "$line"
                [ -n "$_droste_cfg_q" ] || break    # not an assignment with an open quote
                line=${line%'\'}                # one character, not a run
                cont=''
                # A last line with no trailing newline is still a line: `read` reports EOF
                # but leaves the text in `cont`, so only an EMPTY failed read is the end of
                # the file. The `\` above is already gone either way.
                if ! IFS= read -r cont && [ -z "$cont" ]; then
                    break
                fi
                line=$line$cont
            done

            # Rule 2's comment test. This is how the template ships EVERY setting, so it is
            # the branch most lines in a real file take.
            # ⚠️ WHAT IT IS NOT, measured s59 and written down because the first draft of this
            # comment claimed the opposite: it is NOT what rejects `# NAME=v` or
            # `# export NAME=v`. Deleting it changes NO answer, because the name match below
            # is ANCHORED at the start of the (whitespace-stripped) line and `#` is not part
            # of the name, and the `export` pattern is anchored the same way. It is an
            # early-out plus an explicit statement of a contract rule — defence in depth on a
            # class the anchoring already rejects. ⭐ A guard whose removal changes nothing is
            # worth keeping and worth LABELLING, so the next reader does not go hunting for
            # the row that covers it.
            case $line in
                '#'*) continue ;;
            esac

            # `export NAME=value` is an assignment and is honoured — the keyword comes off
            # here, by the same helper the fold's predicate used, so the two cannot drift.
            # The reasoning lives at `droste::_cfg_take_export`.
            droste::_cfg_take_export "$line"; line=$_droste_cfg_l

            case $line in
                "$name"=*) ;;            # candidate. `"$name"=` is quoted ⇒ matched literally.
                *)         continue ;;
            esac

            # No whitespace is permitted around the `=`: `FOO = bar` is a COMMAND to bash,
            # not an assignment, and the `"$name"=*` pattern above already rejects it.
            # The value's own leading whitespace is `_cfg_unquote`'s step 1 — it must come
            # off before anything asks whether the value is quoted, and that rule lives in
            # one place so the two steps cannot drift apart.
            val=${line#"$name"=}

            droste::_cfg_unquote "$val" "$name"
            out=$_droste_cfg_v          # rule 3: keep overwriting — the LAST one wins.
        done < "$file"
    } || true

    # `%s`, never `%s\n` — case 3 above. The answer is the value's bytes and nothing else.
    printf '%s' "$out"
    return 0
}
