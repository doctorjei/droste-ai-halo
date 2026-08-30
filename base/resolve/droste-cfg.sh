#!/usr/bin/env bash
# droste-cfg.sh — read ONE serve setting out of an `<app>.cfg` WITHOUT SOURCING IT.
#
# ⭐ WHY THIS FILE EXISTS (case 2, s59). `server.env` is deleted and the five serve
# settings move into the box's own `<app>.cfg`, which is ALSO the file both resolvers
# source (under `set -a`) to hand the app its native settings. Two readers, one file:
#   • the APP settings are read by SOURCING — that is what makes the file a config surface;
#   • the SERVE settings are read by SCANNING — this file.
# They must not be the same read, because the second one runs somewhere the first is not
# allowed to fail: the healthcheck fires every 30 s, and `--health-on-failure=restart`
# turns any abort there into a container restart loop that ejects every interactive shell
# in the box. A user's typo in their own config file must never be able to do that. That
# property is why `serve::read_config` uses a discarding subshell today; "parse, never
# source" is what preserves it once the settings move.
#
# ⭐ THE PARSER MUST AGREE WITH THE SHELL. The same file IS sourced, a few milliseconds
# later, for the app settings. Any place where this scanner and bash disagree is a place
# where the box behaves as though the config said two different things — the worst kind of
# bug to be handed, because the file itself looks correct. Every rule below is written to
# match what `source` would do, and the two deliberate divergences are named as such.
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
#   DROSTE_SERVE_STARTUP_ENABLED   start this box's server when the BOX starts
#   DROSTE_SERVE_HOST              address the server BINDS
#   DROSTE_SERVE_PORT              port it BINDS (host networking: nothing is remapped)
#   DROSTE_SERVE_TLS_CERT          PEM certificate path
#   DROSTE_SERVE_TLS_KEY           PEM private key path
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
# Writes its answer into `_droste_cfg_v`, which the caller declares `local`. Bash's dynamic
# scoping makes that visible here, and it buys a fork per matching line back — worth it in
# a function the healthcheck runs every 30 s.
#
# 🚨 INLINE COMMENTS ARE STRIPPED, AND THIS IS NOT OPTIONAL. Every template in this project
# documents its settings on the assignment line itself — measured at the tip: 152 such lines
# in llama.cfg, 119 in vllm.cfg, 22 in ds4.cfg, 17 in finetuning.cfg, 2 in comfyui.cfg. The
# user turns a setting on by DELETING THE LEADING `#`, which leaves
# `DROSTE_SERVE_PORT=8188        # port it binds`. A parser that takes the rest of the line
# verbatim reads that port as `8188        # port it binds` while `source` reads `8188` —
# precisely the silent disagreement this file is written to avoid. The cut is at the first
# `#` that begins the line or follows whitespace, which is bash's own rule for where an
# unquoted word ends and a comment begins (`FOO=a#b` keeps the `#`; `FOO=a #b` does not).
#
# ⚠️ DIVERGENCE 1, DELIBERATE: an UNQUOTED value containing interior spaces is kept WHOLE.
# Bash would end the assignment at the first space and try to RUN the remainder as a
# command, so `DROSTE_SERVE_TLS_CERT=/opt/my certs/a.pem` is already a broken line in the
# sourcing path — there is no shell behaviour worth agreeing with. Keeping it whole makes
# the error message name the exact string the user typed; truncating would report a path
# they never wrote. The templates tell users to quote values containing spaces.
#
# ⚠️ DIVERGENCE 2, DELIBERATE: text after a CLOSING quote is dropped. Bash concatenates
# (`FOO="a"b` is `ab`), but the only shape that occurs in the wild is
# `DROSTE_LLAMA_EXTRA_ARGS="…"   # example only` — a trailing comment — and the contract
# says "strip ONE matching outer quote pair", which already reads the quoted span as the
# whole value.
#
# ⚠️ AN UNTERMINATED QUOTE IS RETURNED VERBATIM, quote character included, plus a warning.
# Bash would swallow the following lines until it found a closing quote, which we cannot
# usefully imitate line-by-line and should not: the honest answer is to hand back what the
# user actually typed so the failure names the typo. Refusing instead would take the box
# down over a config-file typo, the failure this whole file exists to remove.
#
# NO ESCAPE PROCESSING AND NO EXPANSION, in either quoting form: a `$` in the value comes
# back verbatim and is the caller's problem, never the parser's. The value is DATA. (The
# file is sourced elsewhere, so the user can already run anything they like — that is not a
# reason for this read to re-evaluate a value behind their back.)
droste::_cfg_unquote() {
    local raw=${1-} q rest
    _droste_cfg_v=''

    case $raw in
        '"'*|"'"*)
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
            droste::_cfg_note "unterminated:${q}:${raw}" \
                "unterminated $q quote in a config value — returning the line's text verbatim. Check the quoting in your config file."
            ;;
    esac

    # Unquoted. Cut the inline comment, then the trailing whitespace the cut leaves behind
    # (and the trailing whitespace a user leaves behind when no comment is present).
    local v=$raw
    case $v in
        '#'*)                 v='' ;;
        *[[:space:]]'#'*)     v=${v%%[[:space:]]'#'*} ;;
    esac
    # `[[:space:]]` also covers the CR of a file saved with DOS line endings. Bash would
    # keep that CR in the value; dropping it diverges only in the safe direction — an
    # invisible byte inside a port number or a path is a bug report nobody can read.
    while [ -n "$v" ] && [ "$v" != "${v%[[:space:]]}" ]; do
        v=${v%[[:space:]]}
    done
    _droste_cfg_v=$v
    return 0
}

# ── droste::cfg_get — THE ENTRY POINT ────────────────────────────────────────
# Usage:  value=$(droste::cfg_get DROSTE_SERVE_PORT [/path/to/app.cfg])
#
# Prints the value (possibly empty) on stdout and ALWAYS EXITS 0. Empty output means
# "absent" — rule 5: a blank value is treated exactly as absent, so blank means "no
# opinion" and the caller applies droste's per-box default.
#
# FILE defaults to `${ENV_FILE:-}`; with neither an argument nor `ENV_FILE`, the answer is
# empty. A box with no config file is a normal state, not a fault, so that case is SILENT —
# only a file that EXISTS and cannot be read earns a message.
#
# 🚨 THE LAST ACTIVE ASSIGNMENT WINS. The file is still sourced for the app settings, so
# shell semantics decide: a first-match parser would silently disagree with the very file it
# is reading. That is also why the scan cannot stop early.
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
droste::cfg_get() {
    local name=${1-} file=${2-}

    [ -n "$name" ] || { printf '%s' ''; return 0; }
    [ -n "$file" ] || file=${ENV_FILE:-}
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
            "config lookup for '${1-}' is not a valid variable name — treating it as unset."
        printf '%s' ''
        return 0
    fi

    [ -f "$file" ] || { printf '%s' ''; return 0; }
    if [ ! -r "$file" ]; then
        droste::_cfg_note "unreadable:$file" \
            "cannot read config file '$file' — every setting in it reads as unset. Check its permissions."
        printf '%s' ''
        return 0
    fi

    local line val out='' _droste_cfg_v=''
    {
        while IFS= read -r line || [ -n "$line" ]; do
            # Rule 2: leading whitespace is allowed before the name, so it is removed
            # before anything is decided about the line. One character at a time, because
            # the alternatives all need extglob or an external command and this file may
            # not change the sourcing shell's options.
            while [ -n "$line" ] && [ "$line" != "${line#[[:space:]]}" ]; do
                line=${line#[[:space:]]}
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

            # 🚨 `export NAME=value` IS AN ASSIGNMENT AND IS HONOURED (ruled s59, and it
            # overturned this file's first reading of rule 2). The strict reading — "after
            # leading whitespace, the line matches NAME=" — excludes it, but the file is
            # STILL SOURCED for the app settings, where bash sets the variable exactly as it
            # would without the keyword. A line that works for every app setting while being
            # invisible to the serve settings is a SPLIT BRAIN, with the user's line sitting
            # right there in the file looking correct. ⭐ Agreeing with the shell outranks a
            # narrow reading of the rule's wording — that is the whole premise of parsing
            # rather than sourcing.
            # ⚠️ A WORD BOUNDARY IS REQUIRED: `exportNAME=v` is a command named `exportNAME`,
            # not an assignment, and must not match. The pattern demands whitespace after the
            # keyword, so it cannot.
            # ⚠️ Exactly ONE `export` is consumed. Deeper stacking is not imitated: it is not
            # a shape any user writes, and guessing at it is how two implementations of one
            # rule start to differ.
            case $line in
                'export'[[:space:]]*)
                    line=${line#export}
                    while [ -n "$line" ] && [ "$line" != "${line#[[:space:]]}" ]; do
                        line=${line#[[:space:]]}
                    done
                    ;;
            esac

            case $line in
                "$name"=*) ;;            # candidate. `"$name"=` is quoted ⇒ matched literally.
                *)         continue ;;
            esac

            # No whitespace is permitted around the `=`: `FOO = bar` is a COMMAND to bash,
            # not an assignment, and the `"$name"=*` pattern above already rejects it.
            val=${line#"$name"=}
            droste::_cfg_unquote "$val"
            out=$_droste_cfg_v          # rule 3: keep overwriting — the LAST one wins.
        done < "$file"
    } || true

    printf '%s' "$out"
    return 0
}
