#!/usr/bin/env bash
# droste-serve.sh — shared SERVICE-LAUNCH library (SOURCED, not executed).
#
# ONE launch path, TWO doors. Both callers build the identical SERVICE argv the
# same way (source droste-resolve.sh -> source /opt/resources/build-spec ->
# resolve::apply_spec, which ends with CFG_FILE + PRE_LAUNCH), then hand it to
# this library:
#
#   droste-entrypoint.sh  (SERVER lane, pid1)  -> serve::exec_service
#       foreground exec, exactly as before this file existed. The server lane is
#       DELIBERATELY untouched by everything else here: it never reads the serve
#       settings, never rewrites the port or the bind address (the operator chose
#       both at run time on their own command line — droste ships no published-port
#       definition), never backgrounds anything. A direct `podman run` still works
#       from these images.
#
#   droste-init-hook.sh   (DISTROBOX lane, runs from the container's init line)
#                                                  -> serve::maybe_launch
#       the MERGED-container "server door": `podman start <box>` replays the
#       distrobox init line, the hook applies the spec, and this library decides
#       whether that start should also bring the box's service up. The decision
#       lives in the box's OWN config file on the per-box DATA volume (below), so
#       it is toggleable with an editor + `podman restart` and survives image
#       updates and container recreation.
#
# ── THE FIVE SERVE SETTINGS ─────────────────────────────────────────────────
# They live in /opt/data/<box>.cfg — the SAME file the user edits for every other
# setting this box has, beside them and in the same namespace. There is no second
# config file: `server.env` was deleted in s60 precisely because a user should not
# have to learn that the port lives somewhere other than everything else.
#
# 🚨 `<box>.cfg` AND `DROSTE_<APP>_*` NAME TWO DIFFERENT THINGS, AND THIS IS THE ONE
# PLACE THAT SAYS SO. The FILE is named for the BOX; the SETTINGS inside it are named
# for the APPLICATION. On four of five boxes the two coincide and the distinction is
# invisible — ds4.cfg/DROSTE_DS4_*, comfyui, llama, vllm — but on finetuning they do
# not: the file is `finetuning.cfg` and every setting in it is `DROSTE_JUPYTER_*`.
# There is no jupyter.cfg, and there is no DROSTE_FINETUNING_ anything. So a lowercase
# <box> and an uppercase <APP> in this codebase are NOT the same placeholder, even
# where they sit in the same sentence. Spelling the FILE with the application
# placeholder promises a jupyter.cfg that does not exist, and that promise is only
# visible to someone working on finetuning — which is why it survived a whole session.
#
# The PATH comes from the build-spec's CFG_FILE row and the PREFIX from its
# SERVE_CFG_PREFIX row (see serve::_read_serve_spec) — two rows precisely because the
# two names are independent:
#
#       DROSTE_<APP>_STARTUP_ENABLED=yes  # start this box's server when the BOX starts
#       DROSTE_<APP>_HOST=0.0.0.0         # the address the service BINDS. IPv4 literal
#                                         # only; blank or absent = 0.0.0.0, and anything
#                                         # else REFUSES to serve (§5)
#       DROSTE_<APP>_PORT=8188            # the HOST port the service binds DIRECTLY
#                                         # (host networking: nothing is remapped, so
#                                         # e.g. ds4 binds 8001 itself instead of its
#                                         # own default 8000). Blank or absent = this
#                                         # box's SERVE_PORT_DEFAULT (§7a); only a
#                                         # PRESENT bad value refuses to serve
#       DROSTE_<APP>_TLS_CERT=/path.pem   # PEM cert and key. TLS is on IFF BOTH are
#       DROSTE_<APP>_TLS_KEY=/path.pem    # set; one alone REFUSES to serve (§6)
#
# 🚨 THEY ARE PARSED, NEVER SOURCED — droste::cfg_get (droste-cfg.sh), and for this
# library that is a safety property rather than a style choice. The same file IS
# sourced a few milliseconds later, in a child shell, to hand the app its native
# settings; but THIS read also runs inside droste-healthcheck.sh, which fires every
# 30s under --health-on-failure=restart, so an abort there is a container restart
# loop that ejects every interactive shell in the box. A user's typo in several
# hundred lines of their own config must never be able to do that.
# Missing, unreadable or malformed file => do not serve, no error: an interactive-only
# box must never fail to start because of this file.
#
# ⭐ AND THE IMPORTANT PART IS THE LIFETIMES (s45). The file used to carry one knob,
# `SERVE`, meaning two different things at once — "start at box start" AND "this box
# is supposed to be serving". That single conflation is why stopping the service by
# hand got the container restarted under you, forever, and why holding the door shut
# for a test meant editing a file that SURVIVES RECREATE.
#
#   | | DROSTE_<APP>_STARTUP_ENABLED | state/.IS_ACTIVE                    |
#   |-|------------------------------|-------------------------------------|
#   | what     | a KEY in <box>.cfg  | a FILE in the program-cache state dir |
#   | written  | by the USER         | by the MACHINE (the verbs, the hook)  |
#   | lifetime | persistent, survives recreate | reset EVERY container start  |
#   | means    | start it at box start | it SHOULD be running right now      |
#
# So a stop is ALWAYS TEMPORARY and the user has to remember nothing. Putting the
# "now" flag in <box>.cfg would have re-created the original foot-gun.
# 🚨 A FILE IS A LOCATION; A LIFETIME IS A CONTRACT. Only the location moved in s60 —
# .IS_ACTIVE, .SCHEME and .PREFIX stay machine-written in the state dir and must never
# be folded into the config file.
# ✅ THE LEGACY `SERVE=` KEY IS GONE, not deprecated (s60). Jei confirmed no box
# carries it, and a guard that strands nothing is padding.
#
# Supervision is podman's (`--health-cmd` + `--health-on-failure=restart`, wired at
# create time by droste-setup.sh), probing droste-healthcheck.sh from inside the
# container. A restart re-runs the init line, i.e. re-runs serve::maybe_launch —
# which is why every step below is idempotent and why a leftover instance from a
# previous container start is actively cleaned up (see serve::maybe_launch).
#
# THE STATE RECORD (proof of ownership). Every decision this library makes about
# the service is written to ONE line in $DROSTE_SERVE_RECORD on the PROGRAM-CACHE
# volume (a pid record is re-obtainable bookkeeping — cache class by ruling; the
# service LOG beside it stays on the data volume, because it is what a user reads
# when things broke):
#
#       <pid> <starttime> <token> <argv0> <status>
#       12345 998877 4242:112233 llama-server running
#       -     -      4242:112233 -        refused
#
# with "-" for any field that does not apply. `status` is
# running | starting | stopped | refused | failed
# — WORDS, not 0/1/2, by the same readability rule that named STARTUP_ENABLED
# (`status=starting` needs no legend), and it is what makes the healthcheck honest:
# these boxes use HOST
# networking, so a probe of the port alone proves only that SOMETHING answers it.
# When the door refuses to start a second listener on a port another process
# already holds, the squatter's reply used to satisfy the probe and the box
# reported HEALTHY while serving nothing at all. droste-healthcheck.sh therefore
# requires BOTH halves: this record says OUR launch succeeded and that exact
# process is still alive (serve::state_ok), AND the endpoint answers.
# Every path through maybe_launch that ends in "we are not serving" rewrites the
# record (refused/failed) — it lives on a host volume and outlives both the
# process and the container, so it is never trusted just for being there.
#
# Sourced by a caller that has already set `set -euo pipefail`; kept in effect here.
set -euo pipefail
# Helpers a build-spec may call in EITHER lane (droste::split_args, and serve::*
# fallbacks). ⚠️ Sourced UNCONDITIONALLY: a build-spec's PRE_LAUNCH runs here too,
# and before s52 a serve::err call from one was `command not found` under set -e,
# which killed the lane instead of printing a warning.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/droste-common.sh"
# droste::cfg_apply — the child-shell apply step for a box's config file. It only
# CALLS serve::err/warn/info, so it is safe to source before this library defines its
# own prefixed versions: the names resolve when the function runs, not when it loads.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/droste-cfgapply.sh"
# droste::cfg_get — the SCANNING reader for the box's own <box>.cfg. serve::read_config
# is its only caller here, and sourcing it unconditionally is what lets the healthcheck
# keep sourcing THIS file alone. Definitions only, no side effects (see droste-cfg.sh).
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/droste-cfg.sh"

# ── Config (override via env before sourcing) ───────────────────────────────
# Two per-box roots, same names and defaults as droste-resolve.sh (this library is
# sourced on its own by droste-healthcheck.sh, so it cannot rely on that one having
# set them). Class split, per the storage taxonomy: the settings file and the
# service log are DATA (user-edited / read exactly when something broke), the pid
# record is PROGRAM CACHE (bookkeeping about a process that no longer exists once
# the box is recreated).
: "${DROSTE_DATA_DIR:=/opt/data}"
: "${DROSTE_PCACHE_DIR:=/opt/program-cache}"
# ⚠️ NO LITERAL DEFAULT FOR THE CONFIG FILE ANY MORE, and that is the point: there is
# no one path that is right for all five boxes now that the serve settings live in the
# box's own <box>.cfg. serve::read_config fills these two in from the baked build-spec
# (serve::_read_serve_spec) on every call. Setting either one here — or in the
# environment before sourcing — is a TEST override, honoured only when the build-spec
# declares nothing; production always has a spec and the spec always wins.
: "${DROSTE_SERVE_ENV:=}"          # the box's config file, from the spec's CFG_FILE
: "${SERVE_CFG_PREFIX:=}"          # its setting prefix, from the spec's SERVE_CFG_PREFIX
# ── The state folder (s45) ──────────────────────────────────────────────────
# Per-start state lives in ONE folder on the PROGRAM CACHE, and the folder supplies the
# context so the names inside it can be short:
#   state/launch      the launch record  — OBSERVATION: what we launched, and how it went
#   state/.IS_ACTIVE  0/1                — INTENT: should a server be running right now
# Keeping those in two files is the point, not an accident: they answer different
# questions and are written at different moments (a `stop` sets intent with no launch
# involved). Folding intent into the record — or into the box's <box>.cfg — would
# re-create the very conflation this split exists to remove.
# ⚠️ RENAMED FROM `.droste-serve.pid`: that name described one of its five fields. An
# existing box has its record at the old path, so the first start on new code finds none;
# state_ok already reports that honestly ("no launch record …"), so the cost is ONE
# spurious unhealthy cycle at upgrade. Known and accepted, not discovered later.
: "${DROSTE_SERVE_STATE_DIR:=$DROSTE_PCACHE_DIR/state}"
: "${DROSTE_SERVE_RECORD:=$DROSTE_SERVE_STATE_DIR/launch}"      # the launch record
: "${DROSTE_SERVE_ACTIVE:=$DROSTE_SERVE_STATE_DIR/.IS_ACTIVE}"  # the intent flag
: "${DROSTE_SERVE_SCHEME:=$DROSTE_SERVE_STATE_DIR/.SCHEME}"     # http|https, LEARNED
: "${DROSTE_SERVE_PREFIX:=$DROSTE_SERVE_STATE_DIR/.PREFIX}"     # path prefix, DECLARED
: "${DROSTE_SERVE_REQ_FIFO:=$DROSTE_SERVE_STATE_DIR/request}"   # verb → supervisor
: "${DROSTE_SERVE_SUP_RECORD:=$DROSTE_SERVE_STATE_DIR/supervisor}"  # its pid + start
: "${DROSTE_SERVE_REQ_WAIT:=60}"   # seconds a verb waits for the supervisor's launch
: "${DROSTE_SERVE_LOG:=$DROSTE_DATA_DIR/.droste-serve.log}"
# ── The four flags this library puts on the command line ────────────────────
# 🚨 EVERY BOX GETS A COMMAND-LINE FLAG, AND NO BOX GETS AN ENVIRONMENT VARIABLE OR A
# CONFIG KEY (ruled s60). A CLI flag outranks an env var (llama's LLAMA_ARG_*), a YAML
# key (vllm's vllm_config.yaml) and a built-in default (all five), which is what makes
# the "reserved by droste" block in each <box>.cfg TRUE rather than merely advisory —
# a claim nothing enforces is advice. It also sidesteps the s57 box-killer outright:
# LLAMA_ARG_HOST="" binds ::1 only and restart-loops the box, and a variable we never
# set cannot be blank.
#
# The port flag is uniform: comfyui main.py, jupyter lab, vllm serve, llama-server and
# ds4-server all spell it `--port`. The other three are NOT, so a build-spec overrides
# them by plain assignment — the spec is sourced AFTER this library in both doors, so
# its assignment wins over the default below.
#   host:  --host (llama, vllm, ds4) · --listen (comfyui) · --ip (jupyter)
#   TLS:   --ssl-cert-file/--ssl-key-file (llama) · --ssl-certfile/--ssl-keyfile (vllm)
#          --tls-certfile/--tls-keyfile (comfyui) · --certfile/--keyfile (jupyter)
# ⚠️ THE TLS PAIR HAS NO DEFAULT ON PURPOSE. There is no majority spelling to default
# to, and a wrong flag is not a wrong value — the server rejects the argv and never
# starts, which under --health-on-failure=restart is a restart loop. Empty means "this
# box declares no TLS flags", and serve::apply_tls says so out loud rather than
# guessing. ds4 ships no TLS settings at all (verified at its pin: zero ssl/tls matches
# in ds4_server.c), so on that box the pair is empty and nothing ever reads it.
: "${SERVE_PORT_FLAG:=--port}"
: "${SERVE_HOST_FLAG:=--host}"
: "${SERVE_TLS_CERT_FLAG:=}"
: "${SERVE_TLS_KEY_FLAG:=}"
# Our default bind address, and it is OURS rather than any server's (Jei, s59: "all
# should default to 0.0.0.0"). Four boxes already forced it in their spec; llama did
# not, so llama's behaviour CHANGES here — it bound llama.cpp's own loopback default
# and nothing reported it, because the probe asked 127.0.0.1 and a loopback-only
# listener answers that perfectly.
: "${SERVE_HOST_DEFAULT:=0.0.0.0}"
# Our default LISTEN PORT — the address's twin, and the row that was MISSING until s60
# (Jei: "we should make our default adjust the port via wiring. i thought that was
# clear"). It is N1a: a value we want every box to have belongs in the WIRING, because a
# line seeded into a config file only ever reaches boxes created after it was written.
# 🚨 THE ASYMMETRY IT REMOVES IS THE DEFECT. HOST had a default here and PORT had none,
# so "remove the line and get our default" — which the HOST refusal offers in so many
# words — was TRUE for the address and REFUSED TO SERVE for the port. Every box ships its
# port as a COMMENTED line whose value IS the shown default, so before this row a user
# who never uncommented it had a box that would not serve at all.
# ⚠️ UNLIKE THE ADDRESS, IT IS PER BOX and empty here on purpose: there is no number five
# servers could share. Host networking publishes nothing and remaps nothing, so two boxes
# on one port collide — which is exactly why ds4 is 8001 rather than ds4-server's own
# 8000, vllm's number. Each build-spec declares its own (comfyui 8188 · llama 8080 ·
# vllm 8000 · finetuning 8888 · ds4 8001), and serve::_read_serve_spec carries the row to
# the healthcheck, which sources this library ALONE and never reads a spec otherwise.
# ⚠️ AN EMPTY VALUE IS A REAL STATE — a lab, or a spec with no row. read_config then keeps
# the old refusal and names the IMAGE as the broken part, rather than binding a number
# nobody chose.
: "${SERVE_PORT_DEFAULT:=}"
: "${DROSTE_SERVE_STOP_WAIT:=15}"   # seconds to wait for a stale instance to die

# ── Messaging (independent of droste-resolve.sh: droste-healthcheck.sh sources
#    THIS file alone) ──────────────────────────────────────────────────────────
serve::info() { printf 'droste-serve: INFO: %s\n' "$*" >&2; }
serve::warn() { printf 'droste-serve: WARN: %s\n' "$*" >&2; }
serve::err()  { printf 'droste-serve: ERROR: %s\n' "$*" >&2; }

# ── Identity: DERIVED HERE, NEVER INHERITED ─────────────────────────────────
# 🚨 DROSTE_LANE/DROSTE_USER ARE PROCESS-LOCAL TO THE INIT HOOK. It exports them
# (droste-init-hook.sh:33,48) — but droste-healthcheck.sh and the host unit's
# ExecStop reach this library through `podman exec`, which inherits NOTHING from
# that process and runs as container root (no image sets USER). So every deviation
# gated on those names was silently OFF there, and _privdrop_prefix returned at its
# LANE test — above its own "will run as root" warning, so it said nothing at all.
# The healthcheck's surgical relaunch therefore ran the SERVICE as container root,
# which under keep-id is a host subuid: comfyui's user/default/comfy.settings.json
# was created unwritable by the very user the next start runs it as.
# The derivation below is the hook's, verbatim, so there is ONE rule and not two.
#
# ⚠️ THE CONTAINER TEST IS LOAD-BEARING, NOT BELT-AND-BRACES. A lab that sources this
# library on a normal host has a uid>=1000 user in /etc/passwd too, and must keep
# defaulting to the server lane — otherwise a harness driving serve::launch would try
# to setpriv into whoever happens to be uid 1000 on the developer's machine.
# ⚠️ AND THE MARKER IS THE BUILD-SPEC, NOT /run/.containerenv. The obvious podman
# marker was MEASURED and rejected: it exists in every podman container including the
# agent box this was written in, so it separates "a container" from "a host" and not
# "a droste box" from "anything else". /opt/resources/build-spec is baked by all five
# target images (targets/Container.*: `COPY build-spec /opt/resources/build-spec`) and
# by nothing else, and it is already this file's own answer to "what is this box"
# (see read_health_spec / build_service). A user with uid>=1000 beside it can only be
# distrobox-init's: no image creates one (base/Container.runtime:42 adds a GROUP).
# Absent marker ⇒ lane stays `server` ⇒ exactly today's behaviour. Fails closed.
SERVE_IDENTITY_DERIVED=""
serve::_derive_identity() {
    local guess=""
    [ -z "$SERVE_IDENTITY_DERIVED" ] || return 0
    SERVE_IDENTITY_DERIVED=1
    # GUESS ONLY WHEN THE CALLER TOLD US NOTHING — an explicit lane is never overridden,
    # and an explicit `server` must not pick up a box user either: launch's HOME reads
    # DROSTE_USER_HOME, so a guessed one would move the server lane's home out from
    # under it on the strength of a stray passwd entry.
    if [ -z "${DROSTE_LANE:-}" ] && [ -z "${DROSTE_USER:-}" ] \
       && [ -f "${DROSTE_BUILD_SPEC:-/opt/resources/build-spec}" ]; then
        guess=$(awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }' /etc/passwd)
    fi
    if [ -n "$guess" ]; then
        DROSTE_LANE=distrobox
        DROSTE_USER=$guess
        [ -n "${DROSTE_USER_HOME:-}" ] || \
            DROSTE_USER_HOME=$(awk -F: '$3 >= 1000 && $3 < 65534 { print $6; exit }' /etc/passwd)
    fi
    : "${DROSTE_LANE:=server}" "${DROSTE_USER:=}" "${DROSTE_USER_HOME:=}"
    export DROSTE_LANE DROSTE_USER DROSTE_USER_HOME
    return 0
}

# _own — hand ONE path we just created to the box user, or do nothing. The four call
# sites below used to spell this inline, each carrying its own copy of the lane gate;
# one helper is what makes "derive first" impossible to forget at a fifth. Best effort
# by construction (it is EPERM when a verb runs this as the box user, who already owns
# the file): a chown we could not do must never fail a start or a health probe.
serve::_own() {
    serve::_derive_identity
    [ "$DROSTE_LANE" = distrobox ] && [ -n "$DROSTE_USER" ] || return 0
    chown "$DROSTE_USER:" "$1" 2>/dev/null || true
    return 0
}

# _own_dirs — hand the DIRECTORIES under <root> to the box user, never the entries.
# The twin of resolve::_own_dirs, and it lives HERE for the same reason _own does:
# PRE_LAUNCH runs as root from BOTH doors, and the healthcheck's door sources this
# library ALONE (droste-healthcheck.sh:57), so nothing in droste-resolve.sh is
# reachable from it.
# ⚠️ DIRECTORIES ONLY — and here that is a CORRECTNESS rule, not the cost argument its
# twin makes. A model-tree entry is a SYMLINK into the user's HF cache, or under
# --hardlink a second name for the cache blob itself; chowning entries would reach
# through into the user's own data. Adding or removing a link is a directory-entry
# operation, so owning the directories is both sufficient and the whole requirement.
serve::_own_dirs() {
    serve::_derive_identity
    [ "$DROSTE_LANE" = distrobox ] && [ -n "$DROSTE_USER" ] || return 0
    [ -d "$1" ] || return 0
    find "$1" -type d ! -user "$DROSTE_USER" -exec chown "$DROSTE_USER:" {} + 2>/dev/null || true
    return 0
}

# ── Config reading ──────────────────────────────────────────────────────────
# _read_serve_spec — WHERE the box's config file is, what its settings are CALLED, and
# which PORT it falls back to. All three answers are baked, per box, in
# /opt/resources/build-spec:
#
#       CFG_FILE="/opt/data/llama.cfg"
#       SERVE_CFG_PREFIX="DROSTE_LLAMA_"
#       SERVE_PORT_DEFAULT=8080
#
# 🚨 READ HERE, NEVER INHERITED. droste-healthcheck.sh sources THIS library ALONE and
# never runs resolve::apply_spec, so nothing in this file may assume a build-spec has
# already been sourced. Sourced in a SUBSHELL for the same reason serve::read_health_spec
# is — that function is the precedent and this one follows it rather than inventing a
# second baked default: a spec-level side effect must not be able to reach a health probe.
# ⚠️ A spec declaring neither row leaves whatever the caller already set, which is what
# makes DROSTE_SERVE_ENV / SERVE_CFG_PREFIX usable as TEST overrides. Production always
# has a spec and the spec always wins, so the override can never mask a real box.
# ⚠️ NOT the same thing as $DROSTE_SERVE_PREFIX (the state file holding the server's URL
# path prefix). This one is the prefix of the SETTING NAMES.
#
# RETURNS 0 when a build-spec was there to read, 1 when there was none — and that
# distinction is the whole difference between "this is not a droste box" (a lab, the
# server lane, a harness: silence is right) and "this box's spec forgot a row" (an image
# defect that must be said out loud). Read_config uses it for exactly that.
serve::_read_serve_spec() {
    local spec=${1:-${DROSTE_BUILD_SPEC:-/opt/resources/build-spec}} raw="" k v
    [ -f "$spec" ] && [ -r "$spec" ] || return 1
    raw=$(
        set +e +u +o pipefail
        # shellcheck disable=SC1090
        . "$spec" >/dev/null 2>&1
        printf 'file=%s\nprefix=%s\nportdefault=%s\n' \
            "${CFG_FILE-}" "${SERVE_CFG_PREFIX-}" "${SERVE_PORT_DEFAULT-}"
    ) 2>/dev/null || raw=""
    while IFS='=' read -r k v; do
        case "$k" in
            file)        [ -n "${v:-}" ] && DROSTE_SERVE_ENV=$v ;;
            prefix)      [ -n "${v:-}" ] && SERVE_CFG_PREFIX=$v ;;
            # The port default travels the SAME path as the other two rows and for the
            # same reason: the healthcheck sources this library alone, so a row it cannot
            # read is a row that does not exist where it matters most.
            portdefault) [ -n "${v:-}" ] && SERVE_PORT_DEFAULT=$v ;;
        esac
    done <<<"$raw"
    return 0
}

# 🚨 RESOLVED AT LOAD TIME, NOT ONLY INSIDE read_config, and that is a fix rather than an
# optimisation: $DROSTE_SERVE_ENV is named in messages that are built BEFORE any config is
# read — droste-server.sh's usage text is assembled as the script loads — and an empty path
# in a sentence telling a user where to go and edit something is a value that neither works
# nor complains. One read at load means the name is true from the first line of output.
# read_config repeats it because a harness may swap the spec between calls; it is a file
# read in a subshell either way, and it happens once per probe, not once per line.
serve::_read_serve_spec || true

# _is_ipv4 — is this string a dotted-quad IPv4 LITERAL? Nothing else is accepted as a
# bind address (§5, ruled s59/s60): a hostname would have to be resolved, and the
# address a probe must use is then whatever that name happened to resolve to at launch
# — a moving target inside a health probe that restarts containers.
# ⚠️ AN OCTET WITH A LEADING ZERO IS REJECTED, deliberately: inet_pton(AF_INET) rejects
# it too (it is the historical octal form), so `010.0.0.1` is not the address the user
# thinks they typed. Better to say so than to hand it on and let each of five servers
# disagree about what it means.
# ⚠️ SINCE s60 A `NO` FROM THIS FUNCTION IS A REFUSAL TO SERVE, not a fall-back — read
# the block at the HOST arm of read_config before loosening anything here. Every string
# this returns 1 for is a box that will not come up.
serve::_is_ipv4() {
    local a=${1-} o
    [[ $a =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        case $o in 0[0-9]*) return 1 ;; esac
        [ "$o" -le 255 ] || return 1
    done
    return 0
}

# read_config — read the five serve settings out of the box's own <box>.cfg into
# SERVE_STARTUP_ENABLED (0/1), SERVE_PORT (digits or ""), SERVE_HOST (always an IPv4
# literal), SERVE_TLS_CERT / SERVE_TLS_KEY (paths or ""), plus one _ERR twin per setting
# and the TWO consumer channels — SERVE_CONFIG_ERR ("we refuse to serve, here is why")
# and SERVE_CONFIG_WARN ("we are serving, but not exactly as you asked"). See the block
# at the end of this function for why a display reads two names and not seven.
#
# 🚨 IT PARSES, IT DOES NOT SOURCE (s60). The old body sourced the file in a discarding
# subshell, which was safe for a droste-owned server.env of two keys; the file is now
# several hundred lines of the USER's own settings, so the read goes through
# droste::cfg_get. Same guarantee, kept for the same reason: this runs inside the
# healthcheck, every 30s, under --health-on-failure=restart. NEVER fails, never aborts
# the caller — a hand-edited file with a typo degrades to "don't serve" or to our
# default, never to a box that will not start.
#
# ⭐ IT SETS THE _ERR STRINGS AND PRINTS NOTHING. The launch path (serve::maybe_launch,
# the verbs) says them once, where a human is watching; the probe path reads the same
# values and stays quiet, because a warning repeated every 30s — ~2,880 times a day —
# trains the reader to ignore the log, which costs us the warnings that matter.
#
# ⭐ THE KEY IS `STARTUP_ENABLED`, AND IT ANSWERS EXACTLY ONE QUESTION: "start the
# server when the box starts". It does NOT mean "this box should be serving right
# now" — that is state/.IS_ACTIVE, and conflating the two is the bug this whole
# design exists to remove (a user who stopped the service by hand used to get the
# container restarted under them, forever, because the box still said it should serve).
# The name is Jei's, and so is the reason: "enabled" alone reads as "on right now"
# to anyone who does not speak systemd, so STARTUP supplies the disambiguation.
#
# 🚨 NORMALISE BLANKS FIRST, APPLY DEFAULTS SECOND (§5). A blank is not a value: it must
# behave exactly as if the setting were absent, which for HOST means our 0.0.0.0 and not
# the empty string. Measured, and it is not academic — LLAMA_ARG_HOST="" binds ::1 only
# and restart-loops the box, so the order of these two steps is a box-killer either way.
serve::read_config() {
    local file=${1-} pfx="" v="" spec=0
    local -a warns=()
    SERVE_STARTUP_ENABLED=0
    SERVE_PORT=""
    SERVE_TLS_CERT=""
    SERVE_TLS_KEY=""
    SERVE_STARTUP_ENABLED_ERR=""
    SERVE_PORT_ERR=""
    SERVE_HOST_ERR=""
    SERVE_TLS_ERR=""
    SERVE_CONFIG_ERR=""
    SERVE_CONFIG_WARN=""
    # The default is applied BEFORE the file is even opened, so every later arm —
    # absent, blank, refused — lands on it without a second code path.
    SERVE_HOST=$SERVE_HOST_DEFAULT
    serve::_read_serve_spec && spec=1
    [ -n "$file" ] || file=$DROSTE_SERVE_ENV
    pfx=$SERVE_CFG_PREFIX
    if [ -z "$file" ]; then
        # No config file. With NO BUILD-SPEC that is a normal state — the server lane, a
        # lab, a harness — and silence is right. WITH one it is an image defect: the box
        # declares a server but nowhere to configure it, so every message that names the
        # config file would print an empty path and the box would quietly never serve.
        [ "$spec" -eq 1 ] && SERVE_CONFIG_ERR="this box's build-spec declares no CFG_FILE, so there is nowhere to read its serve settings from — not serving, and nothing can be configured. This is a bug in the image, not in your config file."
        return 0
    fi
    if [ -z "$pfx" ]; then
        # A file with no prefix is the same class of defect one step further on: the
        # build-spec names the config file but not what its settings are CALLED, so all
        # five read as absent and the box silently stops serving.
        SERVE_CONFIG_ERR="this box's build-spec declares CFG_FILE=$file but no SERVE_CFG_PREFIX, so its serve settings cannot be found — not serving. This is a bug in the image, not in your config file."
        return 0
    fi
    # 🚨 ASK ABOUT READABILITY ONCE, HERE, AND NOT FIVE TIMES BELOW. droste::cfg_get warns
    # about an unreadable file and dedups with a memo — but the memo is a variable, the
    # normal call shape is `v=$(droste::cfg_get …)`, and a subshell's assignment dies with
    # the subshell. So five substitution calls produce five identical lines, and this
    # function runs inside the health probe every 30s: ~14,400 copies of one sentence a
    # day, which is how a log stops being read. The call pattern is OURS, so the fix is.
    # (A missing file stays SILENT — a box with no config file yet is a normal state.)
    if [ -e "$file" ] && [ ! -r "$file" ]; then
        SERVE_CONFIG_ERR="cannot read $file — every setting in it reads as unset, so this box is not serving. Check the file's permissions."
        return 0
    fi

    # ── STARTUP_ENABLED — {yes, no}, through the ONE boolean parser ──────────
    # droste::bool is a whitelist and case-folds, so `Yes`, `ON` and `1` all work and
    # `Off` cannot accidentally read as on (the blacklist it replaced did exactly that).
    # An UNRECOGNISED value is not a fall-through: it takes our default AND says so.
    v=$(droste::cfg_get "${pfx}STARTUP_ENABLED" "$file")
    case "$(droste::bool "$v")" in
        on)  SERVE_STARTUP_ENABLED=1 ;;
        off) SERVE_STARTUP_ENABLED=0 ;;
        *)   SERVE_STARTUP_ENABLED=0
             [ -z "$v" ] || SERVE_STARTUP_ENABLED_ERR="${pfx}STARTUP_ENABLED='$v' is not a yes/no value — the server will not be started with the box. Use yes or no in $file." ;;
    esac

    # ── PORT ────────────────────────────────────────────────────────────────
    # ⭐ PARSED ALWAYS, not only when startup is on — this MOVED in s45 and the move is
    # load-bearing. The verbs can start a server on a box whose STARTUP_ENABLED is no
    # (Jei's ruling: starting by hand must not rewrite what the box does at boot), and
    # that launch needs the port exactly as much as a boot-time one.
    # 🚨 ABSENT IS NOT WRONG (§7a, ruled s60) — the same rule the HOST arm below follows,
    # and the reason this arm has three branches rather than two. Absent and blank both
    # mean "no preference" and land on $SERVE_PORT_DEFAULT, which is what makes the
    # commented `# DROSTE_<APP>_PORT=…` line every box ships a TRUE statement of its
    # default instead of a line the box cannot start without. ONLY a value that is
    # PRESENT and unparseable still refuses: someone typed a port and we cannot honour
    # it, and quietly binding a different one is how a user ends up looking for their
    # server on the wrong number.
    # ⚠️ THE DEFAULT IS APPLIED HERE AND NOT BEFORE THE FILE IS OPENED, which is a
    # deliberate difference from the host default above. The address has ONE value for
    # all five boxes and can never be missing; the port is declared per box, so its
    # absence is a possible IMAGE defect and gets said out loud rather than silently
    # producing an empty flag.
    v=$(droste::cfg_get "${pfx}PORT" "$file")
    if [ -z "$v" ]; then
        if [ -n "$SERVE_PORT_DEFAULT" ]; then
            SERVE_PORT=$SERVE_PORT_DEFAULT
        else
            SERVE_PORT_ERR="${pfx}PORT is not set in $file and this box's build-spec declares no default port, so there is nothing to bind — this is a bug in the image, not in your config file"
        fi
    elif [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ]; then
        SERVE_PORT=$v
    else
        # ⭐ THE EXAMPLE IS THE BOX'S OWN DEFAULT, NEVER A LITERAL. This sentence used to
        # end "add e.g. ${pfx}PORT=8188" on all five boxes — comfyui's port, told to a
        # ds4 user whose box wants 8001. A box that names another box's number in its own
        # error message is teaching the collision that host networking makes real.
        SERVE_PORT_ERR="${pfx}PORT='$v' is not a port number; use a whole number from 1 to 65535 in $file${SERVE_PORT_DEFAULT:+, or remove that line to use $SERVE_PORT_DEFAULT}"
    fi

    # ── HOST — AN IPv4 LITERAL, OR WE DO NOT SERVE ──────────────────────────
    # 🚨 NEVER RESOLVE A FAILURE TOWARD MORE EXPOSURE — FAIL (Jei, s60: "fail").
    # This arm used to warn and bind $SERVE_HOST_DEFAULT. That is not a neutral
    # fallback: a user who typed a hostname was plausibly trying to NARROW what the
    # box listens on, and the fallback handed them EVERY interface instead — on boxes
    # where four of five answer without asking who you are, and two of those four have
    # no authentication mechanism to turn on. It is the same shape as a certificate
    # without a key (below): the user believes the port is protected and it is not. So
    # it gets the same answer, through the same channel — refuse to serve, and say why.
    # ⚠️ TWO COUNTS, TWO QUESTIONS, AND THEY ARE NOT THE SAME NUMBER: comfyui and ds4
    # have no auth mechanism at all (verified at the pins), while llama and vllm have
    # one that ships OFF. Only finetuning is authenticated as shipped. This comment
    # said "three of five have no authentication at all", which is neither count.
    # ⚠️ THE ACCEPTED COST, ON THE RECORD: a typo here is now DOWNTIME rather than a
    # degraded start. Jei weighed that against silent over-exposure and chose downtime;
    # the refusal is loud and names the exact line.
    # ⚠️ A BLANK IS NOT A BAD VALUE. Absent and blank both mean "no preference" and
    # both land on $SERVE_HOST_DEFAULT, which was applied before the file was even
    # opened. ONLY a value that is PRESENT and unparseable refuses — conflating the two
    # would turn a commented-out setting into a box that will not serve.
    # 🚫 NO PER-BOX WORDING. One message, identical on all five boxes; the two arms
    # discriminate on the VALUE, never on the box — a `:` says the user reached for
    # IPv6, anything else says they typed something that is not an address at all
    # (a hostname, a URL, a typo). Everything after that first clause is ONE shared
    # string, so the two arms cannot drift into two different messages.
    # ⚠️ SERVE_HOST IS DELIBERATELY LEFT AT THE DEFAULT rather than cleared. The TLS
    # refusal clears its pair because a half-applied PATH must not reach the argv; the
    # opposite is true here — an empty SERVE_HOST reaching serve::apply_host would emit
    # `--host ""`, which is the s57 box-killer, and serve::probe_addr documents "set but
    # empty" as a state read_config never produces. Nothing binds it either way: every
    # path that could put it on a command line (serve::maybe_launch) returns at
    # SERVE_CONFIG_ERR first.
    v=$(droste::cfg_get "${pfx}HOST" "$file")
    if [ -n "$v" ] && ! serve::_is_ipv4 "$v"; then
        case $v in
            *:*) SERVE_HOST_ERR="${pfx}HOST='$v' is an IPv6 address" ;;
            *)   SERVE_HOST_ERR="${pfx}HOST='$v' is not an IPv4 address" ;;
        esac
        SERVE_HOST_ERR="$SERVE_HOST_ERR — this box binds an IPv4 literal only, and binding every interface when you asked for one address would be worse than not serving. THIS BOX IS NOT SERVING. Put an IPv4 address in ${pfx}HOST in $file — or remove that line to bind $SERVE_HOST_DEFAULT — then restart the container."
        SERVE_STARTUP_ENABLED=0
        SERVE_CONFIG_ERR="$SERVE_HOST_ERR"
    elif [ -n "$v" ]; then
        SERVE_HOST=$v
    fi

    # ── TLS — on IFF BOTH are set, and ONE ALONE REFUSES TO SERVE ───────────
    # ⭐ The reasoning, since the alternative is defensible: a user who set a certificate
    # BELIEVES the port is encrypted. Serving plaintext on it behind a warning they may
    # never read is a security-shaped surprise; a box that refuses and says why is
    # merely down.
    # ⚠️ A PATH IS VALIDATED BY EXISTENCE, NEVER BY PLAUSIBILITY — "   " is a legal file
    # name on Linux, so there is no shape test to make here. `-e`, not `-r`: this runs as
    # root while the service runs as the box user, so OUR ability to read the file says
    # nothing about the server's, and a privilege-dependent verdict is worse than none.
    SERVE_TLS_CERT=$(droste::cfg_get "${pfx}TLS_CERT" "$file")
    SERVE_TLS_KEY=$(droste::cfg_get "${pfx}TLS_KEY" "$file")
    if [ -n "$SERVE_TLS_CERT" ] || [ -n "$SERVE_TLS_KEY" ]; then
        if [ -z "$SERVE_TLS_KEY" ]; then
            SERVE_TLS_ERR="${pfx}TLS_CERT is set but ${pfx}TLS_KEY is not — TLS needs both, and serving plaintext on a port you asked to encrypt would be worse than not serving. Set both in $file, or neither."
        elif [ -z "$SERVE_TLS_CERT" ]; then
            SERVE_TLS_ERR="${pfx}TLS_KEY is set but ${pfx}TLS_CERT is not — TLS needs both, and serving plaintext on a port you asked to encrypt would be worse than not serving. Set both in $file, or neither."
        elif [ ! -e "$SERVE_TLS_CERT" ]; then
            SERVE_TLS_ERR="${pfx}TLS_CERT points at '$SERVE_TLS_CERT', which does not exist — the server would fail to start and the box would restart in a loop. Fix the path in $file, or remove both TLS lines to serve plain HTTP."
        elif [ ! -e "$SERVE_TLS_KEY" ]; then
            SERVE_TLS_ERR="${pfx}TLS_KEY points at '$SERVE_TLS_KEY', which does not exist — the server would fail to start and the box would restart in a loop. Fix the path in $file, or remove both TLS lines to serve plain HTTP."
        fi
    fi
    if [ -n "$SERVE_TLS_ERR" ]; then
        # Refuse, and refuse WHOLE: half-applied TLS is the state this check exists to
        # prevent, so neither path survives into the argv.
        SERVE_TLS_CERT=""
        SERVE_TLS_KEY=""
        SERVE_STARTUP_ENABLED=0
        # ⚠️ FIRST REFUSAL WINS — the same rule the port check below states, and it is
        # load-bearing now that HOST can refuse too: a box with both a bad address and a
        # half-set TLS pair would otherwise report only the second one, and the user
        # would fix TLS and still not serve. Message first, refusal always.
        [ -n "$SERVE_CONFIG_ERR" ] || SERVE_CONFIG_ERR="$SERVE_TLS_ERR"
    fi

    # A box asked to serve AT STARTUP without a usable port must not serve, and must say
    # why: the healthcheck probe reads the same setting, so it would otherwise run
    # unsupervised on a port nobody agreed on. (Unchanged behaviour, new placement.)
    # An earlier SERVE_CONFIG_ERR is never overwritten — the first refusal is the one
    # that explains the box's state, and a second message would only compete with it.
    # ⭐ IT QUOTES SERVE_PORT_ERR RATHER THAN RESTATING IT, which is what keeps the
    # box's own default in the sentence: since s60 an empty SERVE_PORT always comes with
    # a message that names it, and a second hand-written copy here is how the two drift
    # into naming different numbers.
    if [ "$SERVE_STARTUP_ENABLED" -eq 1 ] && [ -z "$SERVE_PORT" ] && [ -z "$SERVE_CONFIG_ERR" ]; then
        SERVE_STARTUP_ENABLED=0
        SERVE_CONFIG_ERR="the server is set to start with the box, but $SERVE_PORT_ERR — so it is not serving."
    fi

    # ── THE TWO CHANNELS A CONSUMER HAS TO KNOW ABOUT ───────────────────────
    #   SERVE_CONFIG_ERR   we REFUSE to serve, and this says why.
    #   SERVE_CONFIG_WARN  we ARE serving, but not exactly as asked: a value was
    #                      rejected and ours was used instead. Newline-separated.
    # 🚨 TWO, NOT SEVEN. The per-setting _ERR twins above exist for PRECISION — a test
    # asserts on one, and a message names exactly the setting that is wrong — but a
    # DISPLAY (droste-server.sh's status, the verbs, both doors) reads these two. A
    # consumer that has to learn a new variable name every time a setting is added is
    # the coupling that rots, and the setting everyone forgets to add is the one no
    # user ever sees.
    # ⚠️ SERVE_PORT_ERR IS DELIBERATELY NOT IN EITHER CHANNEL. When it matters it has
    # already become the SERVE_CONFIG_ERR above; when it does not, it says "this box
    # has no port" about an interactive-only box that was never meant to have one, and
    # a status line that nags every such box is a warning that teaches people to stop
    # reading warnings. The launch path still prints it at the moment it refuses.
    # ⚠️ SERVE_HOST_ERR MOVED OUT OF THIS LIST IN s60 and must not come back: a bad
    # address now REFUSES (above), so its message belongs to the ERR channel. Leaving it
    # here as well would print the same sentence twice — once as "we are not serving"
    # and once as "we are serving, but not as asked", the second of which is now false.
    # The per-setting twin is still set, for the tests and for precision.
    # ⚠️ AN ARRAY FOR ONE ENTRY IS DELIBERATE: the channel is a LIST that happens to have
    # one member today, and the next warning is meant to be one more element rather than a
    # restructure. (A bare `for v in "$ONE_THING"` is also SC2066.)
    warns=("$SERVE_STARTUP_ENABLED_ERR")
    for v in "${warns[@]}"; do
        [ -n "$v" ] || continue
        SERVE_CONFIG_WARN="${SERVE_CONFIG_WARN}${SERVE_CONFIG_WARN:+$'\n'}$v"
    done
    return 0
}

# ── Intent: state/.IS_ACTIVE ────────────────────────────────────────────────
# "Should a server be running right now?" — the USER's intent, set by the verbs and
# reset from STARTUP_ENABLED at every container start. NOT an observation: after a
# crash, .IS_ACTIVE=1 with nothing serving is the CORRECT reading — the system wants
# it up and is failing to keep it up, which is exactly the state the relaunch logic
# acts on. The observation stays where it already is and is already honest
# (serve::state_ok: pid + process start-time + port probe).
#
# 🚨 "RESET AT EVERY CONTAINER START" IS ENFORCED BY CODE, NOT BY THE STORAGE.
# /opt/program-cache is a HOST directory and survives container restarts, so nothing
# resets this file by itself — droste-init-hook.sh calls serve::reset_active on every
# start, and that call is what makes "stop is always temporary" true.
serve::is_active() {
    local v=""
    [ -f "$DROSTE_SERVE_ACTIVE" ] && [ -r "$DROSTE_SERVE_ACTIVE" ] || return 1
    read -r v < "$DROSTE_SERVE_ACTIVE" 2>/dev/null || return 1
    case "${v,,}" in
        1|true|yes|on) return 0 ;;
        *)             return 1 ;;
    esac
}

# set_active — write the intent flag. Chowned like every other file this library
# creates in the distrobox lane: it is written as root (a host subuid under keep-id)
# onto a host dir the box user owns, and the VERBS write it as that user.
serve::set_active() {  # 0|1
    local want=$1
    mkdir -p "$DROSTE_SERVE_STATE_DIR" 2>/dev/null || true
    printf '%s\n' "$want" > "$DROSTE_SERVE_ACTIVE" 2>/dev/null || {
        serve::warn "could not write $DROSTE_SERVE_ACTIVE"
        return 1
    }
    serve::_own "$DROSTE_SERVE_ACTIVE"
    serve::_own "$DROSTE_SERVE_STATE_DIR"
    return 0
}

# reset_active — the once-per-container-start reset. Called by the init hook BEFORE
# maybe_launch, so a box whose user stopped the service by hand comes back serving on
# the next start with nothing to remember, and a box that was never meant to serve
# stays off.
serve::reset_active() {
    serve::read_config
    if [ "${SERVE_STARTUP_ENABLED:-0}" -eq 1 ]; then
        serve::set_active 1
    else
        serve::set_active 0
    fi
}

# read_health_spec — pull the per-box probe endpoint out of the baked build-spec
# (rows HEALTH_PATH / HEALTH_ACCEPT; see base/resolve/build-spec.example). Sourced
# in a SUBSHELL for the same reason serve::_read_serve_spec is: the health probe must
# not be able to trip over spec-level side effects. Defaults are the safe generic pair
# ("/" and "ok" = any 2xx/3xx).
serve::read_health_spec() {
    local spec=${1:-${DROSTE_BUILD_SPEC:-/opt/resources/build-spec}} raw="" k v
    HEALTH_PATH="/"
    HEALTH_ACCEPT="ok"
    [ -f "$spec" ] && [ -r "$spec" ] || return 0
    raw=$(
        set +e +u +o pipefail
        # shellcheck disable=SC1090
        . "$spec" >/dev/null 2>&1
        printf 'path=%s\naccept=%s\n' "${HEALTH_PATH-}" "${HEALTH_ACCEPT-}"
    ) 2>/dev/null || raw=""
    while IFS='=' read -r k v; do
        case "$k" in
            path)   [ -n "$v" ] && HEALTH_PATH=$v ;;
            accept) [ -n "$v" ] && HEALTH_ACCEPT=$v ;;
        esac
    done <<<"$raw"
    case "$HEALTH_PATH" in
        /*) ;;
        *)  HEALTH_PATH="/$HEALTH_PATH" ;;
    esac
    # A path prefix moves EVERY route, /health included, so the probe has to follow
    # it or 404 forever (see droste::set_health_prefix). Written by the box's own
    # PRE_LAUNCH, which is the only code that has seen the user's config; absent =
    # no prefix, which is the overwhelmingly common case and costs one stat.
    # Prepended VERBATIM so we compute the same string the server computed.
    if [ -r "$DROSTE_SERVE_PREFIX" ]; then
        read -r _hp_prefix <"$DROSTE_SERVE_PREFIX" 2>/dev/null || _hp_prefix=""
        [ -n "${_hp_prefix:-}" ] && HEALTH_PATH="${_hp_prefix}${HEALTH_PATH}"
        unset _hp_prefix
    fi
    case "$HEALTH_ACCEPT" in
        ok|any) ;;
        *)      HEALTH_ACCEPT="ok" ;;
    esac
    return 0
}

# ── Talking to our own server: scheme, and the one probe ────────────────────
# Four of the five ports can serve HTTPS (vllm 5 flags, comfyui 2, llama 2,
# finetuning 2 Jupyter traits; ds4 none), and until now every probe here spoke
# `http://` and nothing else. A box serving TLS therefore read as unhealthy, and
# with --health-on-failure=restart that is a restart loop; adopt_running could not
# recognise its own server either. That is OUR defect, not a property of TLS, and
# the fix belongs here rather than in a caveat telling users not to enable it.
#
# WHY DETECT RATHER THAN DECLARE. TLS is turned on by the USER, in the per-box
# config file, and each port spells it differently — llama LLAMA_ARG_SSL_CERT_FILE,
# vllm --ssl-keyfile in YAML or DROSTE_VLLM_EXTRA_ARGS, comfyui --tls-keyfile in
# the catch-all, and finetuning a `certfile` TRAIT IN A PYTHON FILE. The build-spec
# is baked and cannot know; a config scan would need four parsers and would still
# miss the Python one. Asking the socket works the same way on all five, which is
# the "mechanism differences are ours to absorb" rule applied literally.
#
# MEASURED, not inferred — curl against a real TLS server and a real plain one:
#   nothing listening       both schemes  rc 7            → DOWN, not a mismatch
#   plain server, http://   code 200 rc 0                 → right
#   plain server, https://  rc 35 (SSL connect error)     → wrong scheme
#   TLS server,   http://   rc 56, code 000               → wrong scheme
#   TLS server,   https://  rc 60 (cert verify) WITHOUT -k
#   TLS server,   https://  code 200 WITH -k
# Two things fall out of that table and BOTH are needed:
#   1. `-k` is not optional. A local box's cert is self-signed as a matter of
#      course, so without it every TLS box fails cert verification and we would
#      have "fixed" the scheme and still reported unhealthy. We are calling our own
#      server over loopback and identifying it by pid and mount namespace elsewhere;
#      certificate validation adds nothing here that those do not already do better.
#   2. rc 7 stays DOWN. Connection refused means nothing is listening, on either
#      scheme, so it is not a scheme question and is answered without a retry.
#      ⚠️ HONESTLY: this one is for CLARITY, not for correctness or speed — measured,
#      removing it changes no outcome (the retry also gets rc 7 / 000, remembers
#      nothing and logs nothing) and no measurable time (76ms vs 74ms, because a
#      refused connection returns instantly rather than waiting out the timeout).
#      It earns its place by saying "refused means down, full stop" in one place.
serve::probe_scheme() {
    local cached
    if [ -r "$DROSTE_SERVE_SCHEME" ]; then
        read -r cached <"$DROSTE_SERVE_SCHEME" 2>/dev/null || cached=""
        case "$cached" in http|https) printf '%s\n' "$cached"; return 0 ;; esac
    fi
    printf 'http\n'
}

serve::_remember_scheme() {
    case "$1" in http|https) ;; *) return 0 ;; esac
    mkdir -p "$DROSTE_SERVE_STATE_DIR" 2>/dev/null || return 0
    printf '%s\n' "$1" >"$DROSTE_SERVE_SCHEME" 2>/dev/null || return 0
    serve::_own "$DROSTE_SERVE_STATE_DIR" 2>/dev/null || true
}

# ── Talking to our own server: the ADDRESS ──────────────────────────────────
# probe_addr — the address every probe in this project asks. THE SINGLE SOURCE for all
# four call sites (three here, one in droste-healthcheck.sh); they each carried the
# literal `127.0.0.1` until s60, which was a restart loop waiting for its trigger: the
# moment a user binds their server to one specific address, a probe still asking
# loopback gets nothing, reports UNHEALTHY forever, and --health-on-failure=restart
# bounces a container whose server is working perfectly.
#
#   | SERVE_HOST                    | probe        |
#   |-------------------------------|--------------|
#   | unset / 0.0.0.0 (the wildcard)| 127.0.0.1    |
#   | a specific IPv4 literal       | that address |
#
# ⭐ WHY THIS ONE IS DERIVED AND NOT DECLARED. The other two things a probe has to know
# about our own server are not: the SCHEME is probed (the user turns TLS on in four
# different spellings, and the build-spec is baked and cannot know) and the path PREFIX
# is declared by the box's own PRE_LAUNCH. The address is already in the value we just
# read, so a setting for it would be a second place to get it wrong.
# ⚠️ A wildcard listener answers on loopback too, so 127.0.0.1 stays the right question
# for 0.0.0.0 — cheaper and immune to a machine with no route to its own external IP.
#
# ⚠️ THERE IS NO THIRD ROW FOR "THE ADDRESS WAS REFUSED", AND THAT IS CHECKED, NOT
# ASSUMED (s60). A box whose HOST cannot be parsed does not serve at all, so nothing
# should be asking this function where to probe it — and nothing does: serve::maybe_launch
# and start_service both return at SERVE_CONFIG_ERR before any probe, and the healthcheck
# exits at gate 0 because reset_active derived .IS_ACTIVE from STARTUP_ENABLED=0 at
# container start. The one path that still reaches a probe is a user editing a bad address
# into the cfg of a box that is ALREADY serving: the process running there was launched
# from a value that parsed, and this function keeps answering exactly what it answered
# before the edit (the default is untouched by the refusal), which is the only address
# anyone here has. That box then reports unhealthy, cannot be relaunched (the config
# refuses), and comes back interactive-but-not-serving after the container bounce — the
# accepted cost, converging on "down and loud" rather than on a wider bind.
#
# 🚨 IT READS THE CONFIG ITSELF WHEN NOBODY ELSE HAS, AND THAT IS NOT DEFENSIVENESS.
# Every arm of this function returns a PLAUSIBLE address, so a caller that forgot
# serve::read_config gets 127.0.0.1 — silently right for a wildcard box and silently
# WRONG for a box bound to one address, which is exactly the distinction serve::_port_busy
# must not get wrong (a wildcard listener and a specific-address listener are different
# occupancy questions; the wrong one either misses a real conflict or invents one). A
# comment saying "call read_config first" cannot fail loudly, so this does the call.
# ⭐ THE TEST IS PRESENCE, NEVER VALUE — `${SERVE_HOST+set}`, not `${SERVE_HOST:-}`. An
# empty SERVE_HOST is a state read_config never produces (it normalises blanks to the
# default before the file is even opened), so "set but empty" can only be a caller who
# meant it, and a value test would throw that away and re-read over the top of them.
# read_config always assigns SERVE_HOST, so this runs at most once per shell and never
# recurses — nothing in read_config asks for an address.
serve::probe_addr() {
    [ -n "${SERVE_HOST+set}" ] || serve::read_config
    case "${SERVE_HOST:-}" in
        ''|0.0.0.0) printf '127.0.0.1\n' ;;
        *)          printf '%s\n' "$SERVE_HOST" ;;
    esac
}

# serve::probe — ask our own endpoint, learning the scheme if it moved. Echoes the
# HTTP code (or 000) and returns curl's rc for the attempt that produced it, so a
# caller can still tell "refused" from "answered badly" exactly as before.
# The learned scheme lives in the state folder, so it resets every container start:
# a user who turns TLS on and restarts is re-detected rather than remembered wrong.
serve::probe() {
    local port=$1 path=${2:-/} timeout=${3:-${DROSTE_HEALTH_TIMEOUT:-5}}
    local scheme other addr code rc=0
    command -v curl >/dev/null 2>&1 || { printf '000\n'; return 1; }
    scheme=$(serve::probe_scheme)
    # ONE address for both attempts: the retry exists to settle the SCHEME, and moving
    # the address between the two would make its answer unattributable.
    addr=$(serve::probe_addr)
    code=$(curl -s -k -o /dev/null -w '%{http_code}' --max-time "$timeout" \
        "$scheme://${addr}:${port}${path}" 2>/dev/null) || rc=$?
    # Answered, or nothing is listening at all: either way the scheme is not the
    # question. rc 7 must not trigger a retry — see the table above.
    if { [ -n "$code" ] && [ "$code" != 000 ]; } || [ "$rc" -eq 7 ]; then
        printf '%s\n' "${code:-000}"; return "$rc"
    fi
    case "$scheme" in http) other=https ;; *) other=http ;; esac
    rc=0
    code=$(curl -s -k -o /dev/null -w '%{http_code}' --max-time "$timeout" \
        "$other://${addr}:${port}${path}" 2>/dev/null) || rc=$?
    if [ -n "$code" ] && [ "$code" != 000 ]; then
        serve::_remember_scheme "$other"
        serve::info "the endpoint answers ${other}, not ${scheme}; probing ${other} from now on."
    fi
    printf '%s\n' "${code:-000}"; return "$rc"
}

# ── Argv plumbing: the four flags ───────────────────────────────────────────
# _apply_flag — put ONE value into the SERVICE argv, in place: replace the value after
# EVERY existing occurrence of the flag, and append flag+value only if the flag is not
# there at all. Every-occurrence rather than first is deliberate — a duplicated flag
# whose two copies disagreed would hand the outcome to whichever the server's parser
# happens to keep, and this way they cannot disagree.
# ⭐ ONE BODY, FOUR CALLERS (port, host, TLS cert, TLS key). apply_port carried this
# loop alone until s60; a second hand-written copy for host is how two flags that are
# supposed to behave identically start to differ.
serve::_apply_flag() {
    local flag=$1 val=$2 i=0 n=${#SERVICE[@]} found=0
    [ -n "$flag" ] || return 0
    while [ "$i" -lt "$n" ]; do
        if [ "${SERVICE[$i]}" = "$flag" ]; then
            found=1
            if [ $((i + 1)) -lt "$n" ]; then
                SERVICE[i + 1]=$val
            else
                SERVICE+=("$val")
            fi
        fi
        i=$((i + 1))
    done
    [ "$found" -eq 1 ] || SERVICE+=("$flag" "$val")
    return 0
}

# apply_port — put the configured port into the SERVICE argv. The flag is already
# there on some boxes (comfyui/jupyter carry one in the spec; ds4's PRE_LAUNCH emits
# one from DROSTE_DS4_PORT, which is the SAME cfg value we read, so the two agree —
# an agreement worth asserting rather than assuming; servewire drives all four cases)
# and absent on others
# (llama/vllm otherwise take their port from an env file / config file / their own
# built-in default — a trailing CLI flag wins over all of those in llama.cpp, vLLM
# and ds4-server, which is what "installer-owned ports" requires).
serve::apply_port() {
    serve::_apply_flag "$SERVE_PORT_FLAG" "$1"
}

# apply_host — the same, for the bind address. Exactly the same shape as apply_port
# and for exactly the same reason: ds4 and comfyui already put a host flag in their
# argv, llama puts none at all, and both cases have to end up with OUR value.
# ⚠️ The value is always an IPv4 literal by the time it gets here — read_config
# normalises a blank to 0.0.0.0, and a value that is neither refuses to serve outright
# (SERVE_CONFIG_ERR), which returns maybe_launch before it reaches this line — so nothing
# downstream has to think about bracketing an IPv6 address into a URL.
serve::apply_host() {
    serve::_apply_flag "$SERVE_HOST_FLAG" "$1"
}

# apply_tls — make sure the certificate and key REACHED the command line, and ONLY when
# the user set them.
# 🚨 NEVER A DEFAULT (Jei, s60). A CLI flag outranks a YAML key, so emitting a default
# path here would silently beat a user's own `ssl-certfile:` in vllm_config.yaml and
# destroy the choice that file grants them. No setting ⇒ no flag ⇒ their file decides.
# read_config has already refused to serve if only one of the two was set, or if either
# path does not exist, so reaching here with both non-empty means TLS is genuinely on.
#
# ⭐ IT IS A BACKSTOP, NOT THE PRIMARY EMITTER, and the shape follows from where the
# knowledge lives. Every port spells the pair differently (--ssl-cert-file /
# --ssl-certfile / --tls-certfile / --certfile), and each box's PRE_LAUNCH already
# translates its own settings into its own flags — so on all five, TLS is on the argv
# before this runs. A box that declares SERVE_TLS_CERT_FLAG/_KEY_FLAG gets the flags
# from here instead; a box that declares neither is checked rather than trusted.
# ⚠️ THE CHECK IS FOR THE USER'S OWN PATH IN THE ARGV, not for a flag name — a flag name
# would need us to know the four spellings we just said we do not. If the exact string
# the user configured is in the command line, somebody put it there. If it is not, TLS
# was configured and did NOT happen, which the user must hear: they believe that port is
# encrypted. Guessing a flag name instead would make the server reject its own argv and
# restart-loop the box, which is worse than either.
serve::apply_tls() {
    local a
    [ -n "${SERVE_TLS_CERT:-}" ] && [ -n "${SERVE_TLS_KEY:-}" ] || return 0
    if [ -n "$SERVE_TLS_CERT_FLAG" ] && [ -n "$SERVE_TLS_KEY_FLAG" ]; then
        serve::_apply_flag "$SERVE_TLS_CERT_FLAG" "$SERVE_TLS_CERT"
        serve::_apply_flag "$SERVE_TLS_KEY_FLAG" "$SERVE_TLS_KEY"
        return 0
    fi
    for a in ${SERVICE[@]+"${SERVICE[@]}"}; do
        [ "$a" = "$SERVE_TLS_CERT" ] && return 0
    done
    serve::warn "TLS is configured in this box's config file but its certificate never reached the server's command line — the server is starting WITHOUT TLS, on a port you asked to encrypt. This is a bug in the image, not in your config file."
    return 0
}

# _port_busy — is anything answering on <the address we would bind>:<port>? Uses curl
# (baked in the runtime base; bash /dev/tcp is not guaranteed to be compiled in). curl
# exit 7 = connection refused = free; anything else (0 = answered, 28 = timed out,
# protocol junk) is treated as occupied — under host networking that could be our own
# survivor from a previous start, another droste box, or a host process, and in
# every one of those cases starting a second binder is wrong.
# ⚠️ IT ASKS THE SAME ADDRESS THE PROBE DOES, and that is a correctness rule rather
# than tidiness: "is 0.0.0.0:8080 free?" and "is 10.0.0.5:8080 free?" are DIFFERENT
# occupancy questions, and asking the wrong one either misses a real conflict or
# invents one that does not exist.
serve::_port_busy() {
    local port=$1 rc=0
    command -v curl >/dev/null 2>&1 || return 1
    # -k so a TLS listener with a self-signed cert is not mistaken for a free port:
    # without it curl exits 60 (cert verify), which is already "not 7" and so already
    # reads as busy — the right answer for the wrong reason. Keeping the scheme plain
    # http:// is deliberate here and NOT an oversight: this asks "may I bind?", and a
    # TLS server answers that question by refusing to speak HTTP, which is not exit 7.
    # Every mismatch rc measured (35, 56, 60) is likewise not 7, so the verdict is
    # correct on both schemes without a second probe on the hot path.
    curl -s -k -o /dev/null --max-time 3 "http://$(serve::probe_addr):$port/" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 7 ]
}

# ── Process identity (the idempotency machinery) ────────────────────────────
# _proc_fields — echo "<state> <starttime>" for a pid, or fail. /proc/<pid>/stat's
# comm field (2) can contain spaces and parens, so everything up to the LAST ") "
# is dropped: the remaining field 1 is state (stat field 3) and field 20 is
# starttime (stat field 22).
serve::_proc_fields() {
    local pid=$1 stat
    [ -n "$pid" ] || return 1
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    stat=${stat##*") "}
    # shellcheck disable=SC2086   # deliberate word split of a numeric stat line
    set -- $stat
    [ "$#" -ge 20 ] || return 1
    printf '%s %s' "$1" "${20}"
}

# _instance_token — an id that is unique to THIS container start and stable within
# it: pid + starttime of our parent (distrobox-init's shell, which `eval`s the init
# hook once per start). WHY: the pid file lives on a HOST volume, so it outlives
# both the process and the container; distrobox boxes also default to `--pid host`,
# so a recorded pid can still be alive — and can even still be OUR service — after a
# `podman restart`. Comparing tokens is what lets maybe_launch tell "already
# launched during this start" (skip) from "leftover from the previous start"
# (adopt if it is serving, otherwise clear it out and relaunch).
serve::_instance_token() {
    local f
    if f=$(serve::_proc_fields "$PPID"); then
        printf '%s:%s' "$PPID" "${f#* }"
    else
        printf 'unknown:%s' "$$"
    fi
}

# _pid_is_ours — is <pid> a live, non-zombie process that is the very one we
# recorded at launch? Identity = pid AND process START TIME: a bare "is the pid
# alive" test would happily match an unrelated process that inherited the number
# (pids come from the HOST namespace here — distrobox defaults to `--pid host` —
# and the pid file lives on a host volume, so both outlive the container), while
# the start-time tick pins it to the exact process we forked. Zombies count as
# dead: our service can exit and sit unreaped for a while, because pid 1 is
# distrobox-init's keepalive shell, not an eager reaper.
# argv[0] is deliberately NOT part of the identity — it is recorded for humans
# only. Several services exec themselves into a different name (the `jupyter`
# dispatcher becomes `jupyter-lab`), so matching on it produces false negatives.
# A recorded start time is REQUIRED: a blank one (the service died before we could
# read /proc) must never match a live process, or _stop_stale could signal a
# stranger.
serve::_pid_is_ours() {
    local pid=$1 want_start=$2 fields state start
    [ -n "$want_start" ] || return 1
    fields=$(serve::_proc_fields "$pid") || return 1
    state=${fields% *}
    start=${fields#* }
    [ "$state" != Z ] || return 1
    [ "$start" = "$want_start" ] || return 1
    return 0
}

# _read_pidfile — load SERVE_REC_PID / _START / _TOKEN / _CMD / _STATUS from the
# state record. (_CMD is read back purely so the field is documented and never
# mis-parsed; the identity check deliberately ignores it — see _pid_is_ours.)
#
# ⚠️ THE EMPTY-STATUS DEFAULT WAS FLIPPED IN s45, AND IT MATTERS. It used to read as
# `running` — an optimistic default, harmless while every record either had a status
# or came from a pre-status image. It becomes WRONG the moment `starting` exists: a
# truncated or half-written record would read as "up and fine". It now FAILS CLOSED.
# The compatibility reason for the old default is gone anyway: the record MOVED to
# state/launch in the same change, so a pre-status record at the old path is never
# read at all — a start with no record simply relaunches, which is correct.
# shellcheck disable=SC2034
serve::_read_pidfile() {
    SERVE_REC_PID="" SERVE_REC_START="" SERVE_REC_TOKEN="" SERVE_REC_CMD="" SERVE_REC_STATUS=""
    [ -f "$DROSTE_SERVE_RECORD" ] || return 1
    read -r SERVE_REC_PID SERVE_REC_START SERVE_REC_TOKEN SERVE_REC_CMD SERVE_REC_STATUS \
        < "$DROSTE_SERVE_RECORD" 2>/dev/null || return 1
    [ -n "${SERVE_REC_PID:-}" ] || return 1
    [ -n "${SERVE_REC_STATUS:-}" ] || SERVE_REC_STATUS=unknown   # fail closed, see above
    return 0
}

# _write_state — write THE state record (one line, see the header). Every field is
# written as "-" when it does not apply, so the line always has five fields and
# `read` can never shift them: a blank start time used to collapse two separators
# into one and slide the token into the start column.
# Chowned to the box user for the same reason the log is: it is written as root in
# the distrobox lane (a subuid on the host under keep-id) onto a host dir of the
# user's (the program-cache root).
serve::_write_state() {
    local status=$1 pid=${2:--} start=${3:--} token=${4:--} cmd=${5:--}
    mkdir -p "$(dirname "$DROSTE_SERVE_RECORD")" 2>/dev/null || true
    printf '%s %s %s %s %s\n' "$pid" "$start" "$token" "$cmd" "$status" \
        > "$DROSTE_SERVE_RECORD" 2>/dev/null || {
        serve::warn "could not write $DROSTE_SERVE_RECORD"
        return 1
    }
    serve::_own "$DROSTE_SERVE_RECORD"
    return 0
}

# _log_note — append one header line to the service log, in the log's own
# "=== droste-serve: <ts> — <what>" style. WHY it exists beyond launch's own
# header: the log is created AT LAUNCH, so a start that never launched (the
# port-in-use refusal) left no log at all — and the log on the data volume is the
# first place a user looks. "No log" reads as "nothing ran"; it must instead say
# what the door decided and why. No /dev/* guard: writing to the /dev/stderr
# fallback is fine (only _log_tail must never READ it back).
serve::_log_note() {
    local msg=$1
    case "$DROSTE_SERVE_LOG" in
        /dev/*) ;;
        *)      mkdir -p "$(dirname "$DROSTE_SERVE_LOG")" 2>/dev/null || true ;;
    esac
    printf '=== droste-serve: %s — %s\n' "$(date -Is 2>/dev/null || true)" "$msg" \
        >>"$DROSTE_SERVE_LOG" 2>/dev/null || return 0
    serve::_own "$DROSTE_SERVE_LOG"
    return 0
}

# _not_serving — the ONE way this library says "this container start is not
# serving": warn into the container log (what `podman logs` shows), append the
# same sentence to the service log (what the user reads first), and stamp the
# state record so the healthcheck cannot be fooled by whatever else answers the
# port. Every early return from maybe_launch that is not "our service is up"
# goes through here.
serve::_not_serving() {
    local status=$1 token=$2 pid=$3 start=$4 msg=$5
    serve::warn "$msg"
    serve::_log_note "${status^^}: $msg"
    serve::_write_state "$status" "$pid" "$start" "$token" "-"
    return 0
}

# _record_age — seconds since the launch record was last written, or a large number
# when there is no record. The record's OWN MTIME is the "since when" the `starting`
# status needs, which is why `starting` cost no new file and no format change: one
# artifact answers "where is the launch up to?", exactly as one answers "should it be
# running?". Prints a bare integer; never fails (a stat we cannot do reads as "old",
# which lets a relaunch proceed rather than wedging on a missing timestamp).
serve::_record_age() {
    local mtime now
    mtime=$(stat -c %Y "$DROSTE_SERVE_RECORD" 2>/dev/null) || { printf '%s' 99999; return 0; }
    now=$(date +%s 2>/dev/null) || { printf '%s' 99999; return 0; }
    printf '%s' $(( now - mtime ))
}

# heartbeat_starting — refresh a `starting` record's mtime, and report whether it is
# still `starting`. The second hand of the clock serve::_relaunch_due reads.
#
# 🚨 WHY THE CLOCK NEEDED ONE (s48, the fresh-install failure). _record_age measures
# "since the record was last WRITTEN", and the init hook writes `starting` exactly ONCE,
# before resolve::apply_spec (droste-init-hook.sh) — which on a fresh install spends
# MINUTES in the model-tree scan and never touches the record again. So the age crossed
# the 120s cooldown while the launch pipeline was healthily working, _relaunch_due said
# yes, and the probe launched the service INTO A HALF-MOUNTED BOX: precisely the hole
# the stamp was added to close, reopened by the stamp's own timestamp going stale.
# A heartbeat makes the mtime mean "when did this launch last show a SIGN OF LIFE"
# rather than "when did it begin" — which is the question the cooldown was always
# asking, and the reason the fix is here and not in a bigger number.
# ⚠️ ONLY `starting` IS EVER REFRESHED, and that is a safety property rather than
# tidiness: touching a `refused` or `failed` record would postpone the very relaunch
# that is supposed to recover from it. Any other status returns 1 — which doubles as
# the beating caller's stop condition, since a record whose status changed has an owner
# again and no longer needs anyone keeping it warm.
serve::heartbeat_starting() {
    serve::_read_pidfile || return 1
    [ "${SERVE_REC_STATUS:-}" = starting ] || return 1
    touch "$DROSTE_SERVE_RECORD" 2>/dev/null || return 1
    return 0
}

# state_ok — did OUR launch succeed, and is that exact process still alive?
# The healthcheck's first gate (see droste-healthcheck.sh); sets SERVE_STATE_MSG
# with the reason on failure. Deliberately says nothing about the port: the probe
# is the second, independent gate.
# shellcheck disable=SC2034   # SERVE_STATE_MSG is consumed by droste-healthcheck.sh
serve::state_ok() {
    SERVE_STATE_MSG=""
    if ! serve::_read_pidfile; then
        SERVE_STATE_MSG="no launch record at $DROSTE_SERVE_RECORD — the server door has not started a service in this container. See $DROSTE_SERVE_LOG (and the container log) for what it decided instead."
        return 1
    fi
    case "$SERVE_REC_STATUS" in
        running) ;;
        starting)
            # A launch is IN FLIGHT (see serve::_relaunch_due). Not serving yet, and
            # deliberately not treated as a failure to be retried: the whole reason
            # this value exists is that ds4 can take minutes to load and a probe every
            # 30s would otherwise start a second launch racing the first for the port.
            SERVE_STATE_MSG="a launch is still in progress (started $(serve::_record_age)s ago) — not serving yet. See $DROSTE_SERVE_LOG."
            return 1
            ;;
        refused)
            SERVE_STATE_MSG="the server door REFUSED to launch (port ${SERVE_PORT:-?} was already in use when the container started) — whatever answers that port is not this box's service. See $DROSTE_SERVE_LOG."
            return 1
            ;;
        stopped)
            # Deliberate: someone ran server_stop. Reported plainly rather than as a
            # fault — but still `return 1`, because the question this function answers
            # is "is our service up", and it is not. The healthcheck never sees this:
            # a stop clears .IS_ACTIVE and the probe exits at that gate first.
            SERVE_STATE_MSG="the server was stopped by hand (server_stop). It starts again with the box unless ${SERVE_CFG_PREFIX}STARTUP_ENABLED=no in $DROSTE_SERVE_ENV."
            return 1
            ;;
        *)
            SERVE_STATE_MSG="the last launch attempt recorded status '$SERVE_REC_STATUS' — nothing of ours is serving. See $DROSTE_SERVE_LOG."
            return 1
            ;;
    esac
    if ! serve::_pid_is_ours "$SERVE_REC_PID" "$SERVE_REC_START"; then
        SERVE_STATE_MSG="the service we launched (pid $SERVE_REC_PID) is gone — anything still answering port ${SERVE_PORT:-?} is not it. See $DROSTE_SERVE_LOG."
        return 1
    fi
    return 0
}

# _stop_stale — terminate a leftover service from a PREVIOUS container start that
# is NOT serving (the port was free when we checked). Only ever called for a pid
# whose start time matches the one we recorded when WE forked it, so this cannot
# signal an innocent bystander. Without it, a `--pid host` box that survives a
# healthcheck-triggered restart could come back with a wedged old process and no
# new one — the design's "restart brings the service back" promise would be false.
serve::_stop_stale() {
    local pid=$1 start=$2 waited=0
    serve::warn "stale service from a previous container start (pid $pid) is not serving — stopping it before relaunch."
    kill -TERM "$pid" 2>/dev/null || true
    while [ "$waited" -lt "$DROSTE_SERVE_STOP_WAIT" ]; do
        serve::_pid_is_ours "$pid" "$start" || return 0
        sleep 1
        waited=$((waited + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
    if serve::_pid_is_ours "$pid" "$start"; then
        serve::err "could not stop stale service pid $pid — not launching a second instance."
        return 1
    fi
    return 0
}

# ── Privilege model ─────────────────────────────────────────────────────────
# _privdrop_prefix — print (NUL-separated) the argv prefix that runs the service
# as the box user in the DISTROBOX lane; nothing in the server lane.
#
# WHO OWNS THE SERVED PROCESS:
#   server lane   — root, exactly as today. No image sets USER, droste-setup.sh passes
#                   no --user, and the compose/plain create binds the HF cache to
#                   /root/.cache/huggingface: the service has always been root there
#                   and stays root. Nothing in this function fires for it.
#   merged/distrobox — the BOX USER (uid >= 1000, $DROSTE_USER). distrobox creates
#                   the container with `--userns keep-id`, so container uid 1000 IS
#                   the host user while container root maps to a SUBUID: a service
#                   running as root would write files into the user's real home
#                   (the HF cache lives there, auto-bound) and into the data volume
#                   that the host user then cannot even delete. It would also fight
#                   the resolver, whose whole distrobox deviation set (_mkuserdir,
#                   _own_dirs, copy-mode chown) exists to keep in-box state owned by
#                   uid 1000. Same-uid-as-the-interactive-door is also the point of
#                   the merge: `pip install` in the box and the served process are
#                   then literally the same environment and the same owner.
#
# setpriv, NOT runuser/su: supplementary groups must be INHERITED, not looked up.
# distrobox creates the container with `--annotation run.oci.keep_original_groups=1`
# and only adds the box user to `sudo` inside /etc/group — the host's render/video
# gids (what opens /dev/kfd and /dev/dri) reach the container as the container
# process's own group list, and `distrobox enter` (a podman exec) inherits that same
# list rather than doing a group lookup. setpriv --reuid/--regid --keep-groups keeps
# the current supplementary groups untouched, so the served process gets exactly the
# group set an interactive session has. runuser/su would re-initgroups from
# /etc/group and drop GPU access.
#
# --keep-groups IS MANDATORY, not decoration: setpriv refuses to run at all when
# --regid arrives without one of --keep-groups/--clear-groups/--init-groups/--groups
# ("--[re]gid requires --keep-groups, --clear-groups, --init-groups, or --groups") —
# it insists the caller say out loud what happens to the supplementary list. Of the
# four, --keep-groups is the one that spells the paragraph above: inherit the
# container's list verbatim. Leaving it out did not merely change the group set, it
# made setpriv exit before ever exec'ing the service, so the distrobox lane's server
# door never opened in any box.
serve::_privdrop_prefix() {
    local uid gid
    serve::_derive_identity
    [ "$DROSTE_LANE" = distrobox ] || return 0
    [ "$(id -u)" = "0" ] || return 0            # not root: nothing to drop
    [ -n "$DROSTE_USER" ] || { serve::warn "no box user derived — the service will run as root."; return 0; }
    uid=$(id -u "$DROSTE_USER" 2>/dev/null) || uid=""
    gid=$(id -g "$DROSTE_USER" 2>/dev/null) || gid=""
    if [ -z "$uid" ] || [ -z "$gid" ]; then
        serve::warn "could not resolve uid/gid for '$DROSTE_USER' — the service will run as root."
        return 0
    fi
    if ! command -v setpriv >/dev/null 2>&1; then
        serve::warn "setpriv (util-linux) not found — the service will run as root; files it writes into your home and data dir will not be owned by you."
        return 0
    fi
    printf 'setpriv\0--reuid=%s\0--regid=%s\0--keep-groups\0--\0' "$uid" "$gid"
}

# ── Launch ──────────────────────────────────────────────────────────────────
# _log_tail — copy the last few lines of the service log to stderr, one prefixed
# line each. WHY: the only thing a user ever sees of a failed start is `podman
# logs <box>`, and the reason (a python traceback, a port already bound, setpriv
# rejecting its own argv) is in the log file on the data volume — which they have
# to be told to go and read. Putting the tail directly under the error message
# makes the container log self-explanatory.
# Silent unless the log is a readable regular file: the unwritable-data-dir path in
# launch repoints DROSTE_SERVE_LOG at /dev/stderr, where the output has already
# gone and which must never be read back.
serve::_log_tail() {
    local n=${1:-10} line
    case "$DROSTE_SERVE_LOG" in /dev/*) return 0 ;; esac
    [ -f "$DROSTE_SERVE_LOG" ] && [ -r "$DROSTE_SERVE_LOG" ] || return 0
    while IFS= read -r line; do
        printf 'droste-serve:   | %s\n' "$line" >&2
    done < <(tail -n "$n" "$DROSTE_SERVE_LOG" 2>/dev/null)
    return 0
}

# launch — start SERVICE in the background, record its identity, return.
# Output goes to a log on the data volume (readable from either door and from the
# host) with ONE generation kept, because a healthcheck-triggered restart would
# otherwise erase the evidence of the crash that caused it. stdin is /dev/null:
# nothing here is interactive, and the init hook's stdin is pid 1's.
serve::launch() {
    local token=$1 prefix=() pid fields start cmd0 died=0
    # IN THIS SHELL, not only inside _privdrop_prefix: the mapfile below runs that
    # function in a PROCESS SUBSTITUTION, so everything it exports dies with the
    # subshell and the HOME line further down would still read the caller's.
    serve::_derive_identity
    if [ "${#SERVICE[@]}" -eq 0 ]; then
        serve::err "no SERVICE defined in the build-spec — nothing to serve."
        return 1
    fi
    mapfile -t -d '' prefix < <(serve::_privdrop_prefix)
    mkdir -p "$(dirname "$DROSTE_SERVE_LOG")" 2>/dev/null || true
    if [ -s "$DROSTE_SERVE_LOG" ]; then
        mv -f "$DROSTE_SERVE_LOG" "$DROSTE_SERVE_LOG.prev" 2>/dev/null || true
    fi
    if ! ( : >"$DROSTE_SERVE_LOG" ) 2>/dev/null; then
        serve::warn "cannot write $DROSTE_SERVE_LOG — service output goes to the container log instead."
        DROSTE_SERVE_LOG=/dev/stderr
    fi
    serve::_log_note "launching: ${SERVICE[*]}"

    HOME="${DROSTE_USER_HOME:-${HOME:-/root}}" \
    USER="${DROSTE_USER:-${USER:-root}}" \
    LOGNAME="${DROSTE_USER:-${LOGNAME:-root}}" \
        ${prefix[@]+"${prefix[@]}"} "${SERVICE[@]}" \
        >>"$DROSTE_SERVE_LOG" 2>&1 </dev/null &
    pid=$!

    # Let the fork settle before believing in it. A child that is about to fail its
    # very first exec (a missing interpreter, setpriv rejecting its own argv) is
    # still a live pid for a few milliseconds, so probing /proc in the same breath
    # as the `&` reports a healthy process for something that never ran — which is
    # exactly how a dead server door got announced as "service started". A fifth of
    # a second settles that and is invisible against a container start; if this
    # sleep cannot do fractions the probe simply runs as early as it used to.
    sleep 0.2 2>/dev/null || true

    # Record identity (setpriv execs, it does not fork, so this pid is the service).
    # A service that dies instantly leaves no /proc entry — the start time then
    # records blank, which _pid_is_ours treats as "not ours", so the next run
    # relaunches instead of trusting a pid it cannot verify. It may instead be a
    # ZOMBIE, still listed but already exited (pid 1 here is distrobox-init's
    # keepalive shell, not an eager reaper); that is just as dead, and _pid_is_ours
    # rejects state Z for the same reason. Either shape means the launch failed.
    # argv[0] is written as the 4th field for humans reading the file; it is not
    # part of the identity. The status field is the healthcheck's gate: only a
    # launch we watched survive its first fifth of a second is written `running`.
    start=""
    if fields=$(serve::_proc_fields "$pid"); then
        start=${fields#* }
        [ "${fields% *}" != Z ] || died=1
    else
        died=1
    fi
    cmd0=$(basename -- "${SERVICE[0]}")
    if [ "$died" -eq 1 ]; then
        serve::_write_state failed "$pid" "${start:--}" "$token" "$cmd0"
    else
        serve::_write_state running "$pid" "${start:--}" "$token" "$cmd0"
    fi
    # Keep the log deletable by the box user too (it is on the host's data dir;
    # written here as root, which is a subuid on the host under keep-id — the
    # state record is chowned by _write_state for the same reason).
    serve::_own "$DROSTE_SERVE_LOG"
    # Report what actually happened. The old code announced "service started" from
    # the mere fact that a fork had returned a pid, so a service that died on its
    # first instruction left a container log claiming success and a port nobody was
    # listening on — the failure only surfaced later as an unexplained UNHEALTHY.
    # Returning non-zero here is safe for every caller: the sole one is
    # maybe_launch, which runs this behind `||` and always returns 0 itself, and
    # the init hook guards maybe_launch behind a second `||` for the same reason —
    # a broken service must never make the box hard to enter.
    if [ "$died" -eq 1 ]; then
        serve::err "the service exited immediately (pid $pid) — nothing is serving port ${SERVE_PORT:-?}. Last lines of $DROSTE_SERVE_LOG:"
        serve::_log_tail   # BEFORE the note below, so the tail shows the service's
                           # own last words rather than our summary of them.
        serve::_log_note "FAILED: the service exited immediately (pid $pid) — nothing is serving port ${SERVE_PORT:-?}."
        return 1
    fi
    serve::info "service started (pid $pid) on port ${SERVE_PORT:-?}; output: $DROSTE_SERVE_LOG"
    return 0
}

# maybe_launch — the whole server-door decision, called once per container start
# from droste-init-hook.sh (and again after every healthcheck-triggered restart).
# Never returns non-zero for a reason that should keep the box from coming up.
#
# ⭐ THE GATE IS INTENT (state/.IS_ACTIVE), NOT CONFIG (STARTUP_ENABLED). At container
# start those two agree, because the init hook calls serve::reset_active first — but
# they are not the same question, and every other caller reaches this function when
# they DISAGREE: server_start on a box whose startup is off, and the healthcheck's
# relaunch after a user ran server_stop (intent 0 ⇒ leave it down; the old code would
# have fought the user forever because the config still said to serve).
serve::maybe_launch() {
    local token _w
    serve::read_config
    if [ -n "${SERVE_CONFIG_ERR:-}" ]; then
        serve::warn "$SERVE_CONFIG_ERR"
        return 0
    fi
    if ! serve::is_active; then
        # Silent by design: interactive-only boxes are the common case, and this
        # runs on every single container start. No state record either — an
        # interactive-only box writes nothing into its host dirs, and the
        # healthcheck answers "healthy, nothing to probe" from the same flag
        # before it ever looks at the record.
        return 0
    fi
    # ⭐ THE NON-FATAL MESSAGES ARE SAID HERE. read_config sets them and prints nothing,
    # because it also runs inside a health probe that fires every 30s; this function runs
    # when a box is actually being brought up, which is the moment a human is watching the
    # container log. Below the intent gate so an interactive-only box stays as silent as
    # it has always been. One line each, through serve::warn, so every line keeps the
    # prefix — a multi-line printf would leave the second sentence looking like the
    # server's own output.
    if [ -n "${SERVE_CONFIG_WARN:-}" ]; then
        while IFS= read -r _w; do
            [ -z "$_w" ] || serve::warn "$_w"
        done <<<"$SERVE_CONFIG_WARN"
    fi
    if [ -z "${SERVE_PORT:-}" ]; then
        # Reachable now that intent and config can disagree: a box whose startup setting
        # is `no` and which has no port, started by hand. read_config's own startup-time
        # check never fires for it, so say it here rather than launching a service with
        # no agreed port.
        serve::warn "${SERVE_PORT_ERR:-no usable port in $DROSTE_SERVE_ENV} — not serving."
        return 0
    fi
    token=$(serve::_instance_token)

    if serve::_read_pidfile; then
        if serve::_pid_is_ours "$SERVE_REC_PID" "$SERVE_REC_START"; then
            if [ "$SERVE_REC_TOKEN" = "$token" ]; then
                serve::info "service already launched during this container start (pid $SERVE_REC_PID) — nothing to do."
                return 0
            fi
            if serve::_port_busy "$SERVE_PORT"; then
                serve::warn "a service from a previous container start (pid $SERVE_REC_PID) is still answering on port $SERVE_PORT — leaving it alone."
                return 0
            fi
            if ! serve::_stop_stale "$SERVE_REC_PID" "$SERVE_REC_START"; then
                # The wedged process is still alive and still not serving. Its
                # record would otherwise read `running` + a live pid, so a
                # squatter answering the port would make the box look healthy.
                serve::_not_serving failed "$token" "$SERVE_REC_PID" "$SERVE_REC_START" \
                    "a wedged service from a previous container start (pid $SERVE_REC_PID) could not be stopped — this box is not serving port $SERVE_PORT."
                return 0
            fi
        fi
    fi

    if serve::_port_busy "$SERVE_PORT"; then
        # ⭐ OURS ALREADY? The refusal below is the right answer for a squatter and the
        # WRONG one for our own server. The healthcheck's surgical relaunch comes
        # through this function, so a launch record that goes bad while the service is
        # genuinely up made every retry find the port held by the very process it was
        # trying to start: refuse, stamp `refused`, fail gate 1 on that stamp, relaunch,
        # refuse — for as long as the box lives. The adopt branch above cannot cover it,
        # because it is nested inside a VALID record and a bad record is exactly what
        # this case has. See serve::adopt_running for the proofs it demands first.
        if serve::adopt_running "$SERVE_PORT" "$token"; then
            return 0
        fi
        serve::_not_serving refused "$token" - - \
            "port $SERVE_PORT is already in use at $(serve::probe_addr) (host networking: another droste box or a host process?) — not starting a second listener. Change ${SERVE_CFG_PREFIX}PORT in $DROSTE_SERVE_ENV or free the port, then restart the container."
        return 0
    fi

    # The argv, finished. All three are idempotent replacements, so a spec that already
    # carries a flag keeps ONE of it with OUR value — and a relaunch through this same
    # function does not accumulate copies.
    serve::apply_port "$SERVE_PORT"
    serve::apply_host "$SERVE_HOST"
    serve::apply_tls
    serve::launch "$token" || serve::warn "service launch failed — the box is still usable interactively; see $DROSTE_SERVE_LOG."
    return 0
}

# ── The launch supervisor ───────────────────────────────────────────────────
# 🚨 WHY THIS EXISTS — AND IT IS NOT WHAT THE FIRST DIAGNOSIS SAID. MEASURED s65 on
# Loaf (podman 4.9.3, rootless) and cross-checked on a second host (podman 5.4.2,
# rootful AND rootless):
#
#   lane                                    TTY?   a service launched there…
#   init hook (container start, pid 1)       -     SURVIVES
#   podman healthcheck run → serve::relaunch no    SURVIVES
#   podman exec <box> …                      no    SURVIVES
#   podman exec -t … / distrobox enter       YES   IS KILLED with the session
#
# ⭐ THE TRIGGER IS THE TTY. `setsid` AND `nohup` BOTH FAIL TO SAVE IT — measured on a
# HEALTHY box with the container's RestartCount recorded either side, so a healthcheck
# bounce cannot be mistaken for the kill. Whatever podman/conmon does at TTY-exec
# teardown finds the process by something other than its session or process group.
# ⚠️ THE BEHAVIOUR IS MEASURED; THE CAUSE IS NOT. Do not add a comment here claiming to
# know which mechanism it is — three plausible ones were proposed and two were refuted.
#
# ⇒ `server_start` from `distrobox enter` forked a service that died with the session.
# The record said `running` because serve::launch watches its first 0.2 s and the kill
# lands later; the box then failed its probe and podman BOUNCED THE CONTAINER, ejecting
# every interactive shell — the precise outcome the s45 lifecycle exists to prevent.
#
# THE FIX: the verbs stop forking the service. A supervisor spawned by the INIT HOOK —
# the one lane with no TTY anywhere in its ancestry — does the forking instead, so what
# it starts has no TTY session to be torn down with.
#
# ⭐ IT BLOCKS ON A FIFO RATHER THAN POLLING. Blocked on `read` is genuinely asleep: no
# CPU, no wakeups, and no interval to tune — and it responds the instant a verb writes.
# The absence of a timer here is the design, not an omission.
# ⭐ AND A FIFO RATHER THAN A SIGNAL (asked and answered, Jei s65). The supervisor is
# spawned by the init hook and runs as ROOT; a verb runs as the BOX USER, because
# serve::_privdrop_prefix opens with `[ "$(id -u)" = "0" ] || return 0` precisely so a
# non-root caller works. `kill` across that boundary is EPERM, and leaning on
# distrobox's passwordless sudo would make a core path depend on a convenience. A fifo
# needs no privilege beyond file mode — and it carries a PAYLOAD, where a signal
# carries none and `start` vs `restart` would need a second signal or a side channel.
#
# 🚨 PODMAN'S HEALTHCHECK IS **NOT** REPLACED, AND THAT IS DELIBERATE. It is the
# EXTERNAL watchdog — the thing that notices a wedged box, INCLUDING A DEAD SUPERVISOR
# — and its relaunch already runs in a lane that survives (no TTY). Folding health in
# here would make this process a single point of failure with nothing watching it.
#
# ⚠️ THE FIFO IS MODE 0666 AND THAT GRANTS NOTHING. A launch request carries no
# arguments: the argv comes from the baked build-spec and the user's own <box>.cfg, and
# the service still drops to the box user via setpriv. Anyone who can write this fifo
# can already run `server_start`.

# supervisor_alive — is the recorded supervisor the very process we started? Same
# pid+start-time identity the launch record uses, for the same reason: a bare pid test
# matches an unrelated process that inherited the number (pids are the HOST's here).
serve::supervisor_alive() {
    local pid start
    [ -r "$DROSTE_SERVE_SUP_RECORD" ] || return 1
    read -r pid start < "$DROSTE_SERVE_SUP_RECORD" 2>/dev/null || return 1
    [ -n "${pid:-}" ] && [ -n "${start:-}" ] || return 1
    serve::_pid_is_ours "$pid" "$start"
}

# supervisor_start — spawn one if none is running. The init hook replays on EVERY
# container start by design, so this must be safe to call against a live supervisor.
serve::supervisor_start() {
    local self
    serve::supervisor_alive && return 0
    mkdir -p "$DROSTE_SERVE_STATE_DIR" 2>/dev/null || true
    # Recreate rather than reuse: the state dir resets per container so a leftover is
    # already unusual, and recreating means the mode is ours rather than whatever a
    # previous owner left. Losing the fifo is NOT fatal — the verbs fall back.
    rm -f "$DROSTE_SERVE_REQ_FIFO" 2>/dev/null || true
    if ! mkfifo -m 0666 "$DROSTE_SERVE_REQ_FIFO" 2>/dev/null; then
        serve::warn "could not create $DROSTE_SERVE_REQ_FIFO — server_start inside the box will launch the service directly, and it will not outlive the session that ran it."
        return 1
    fi
    serve::_own "$DROSTE_SERVE_REQ_FIFO"
    self="$(dirname -- "${BASH_SOURCE[0]}")/droste-server.sh"
    if [ ! -r "$self" ]; then
        serve::warn "no $self — cannot start the launch supervisor."
        return 1
    fi
    # Detached exactly as dlwatch::_spawn detaches its daemon, and for the same reason:
    # anything this process still holds would otherwise be inherited by the SERVICE.
    # ⚠️ RESOLVE_DIR IS PASSED, NOT LEFT TO ITS DEFAULT. droste-server.sh falls back to a
    # HARDCODED /opt/resources/resolve, so a supervisor spawned from a library living
    # anywhere else would load a DIFFERENT copy than the one that spawned it — silently,
    # and only where it matters least (a lab, a mutation run, a relocated tree). Pinning
    # the child to `dirname "${BASH_SOURCE[0]}"` makes "the daemon runs the code that
    # started it" true by construction rather than by coincidence of paths.
    RESOLVE_DIR="$(dirname -- "${BASH_SOURCE[0]}")" \
        bash "$self" __supervisor >/dev/null 2>&1 </dev/null &
    return 0
}

# supervisor_loop — the daemon body. Runs as the `__supervisor` action of
# droste-server.sh, so it reaches the library exactly the way every verb does.
serve::supervisor_loop() {
    local req fields fd
    mkdir -p "$DROSTE_SERVE_STATE_DIR" 2>/dev/null || true
    [ -p "$DROSTE_SERVE_REQ_FIFO" ] || return 1
    # WRITTEN BY THE CHILD, because only the child knows its own pid.
    fields=$(serve::_proc_fields "$$") || return 1
    printf '%s %s\n' "$$" "${fields#* }" > "$DROSTE_SERVE_SUP_RECORD" || return 1
    serve::_own "$DROSTE_SERVE_SUP_RECORD"
    # 🚨 READ-WRITE, NOT READ-ONLY, AND THIS IS THE WHOLE TRICK. Opening a fifo
    # O_RDONLY blocks until a writer appears and then returns EOF as soon as the last
    # writer closes — so the loop would exit after the FIRST request. Holding a write
    # end ourselves means the read never sees EOF and blocks indefinitely instead,
    # which is what "asleep with no timer" means here.
    exec {fd}<>"$DROSTE_SERVE_REQ_FIFO" || return 1
    while IFS= read -r req <&"$fd"; do
        case "$req" in
            "")     : ;;
            launch)
                # 🚨 IN A SUBSHELL, DELIBERATELY. This library turns errexit ON when
                # sourced, and PRE_LAUNCH is arbitrary per-box code: an `exit` or a
                # failing command inside it would otherwise take the supervisor down
                # and leave every later verb falling back silently. The launched
                # service is unaffected — it is backgrounded, so the subshell exiting
                # merely re-parents it to pid 1.
                ( serve::build_service && serve::maybe_launch ) || \
                    serve::warn "supervisor: launch request failed; see $DROSTE_SERVE_LOG."
                ;;
            *)      serve::warn "supervisor: ignoring unrecognised request '$req'." ;;
        esac
    done
    return 0
}

# request_launch — ask the supervisor to launch, then wait for the record to say it
# did. Returns 0 launched, 1 no supervisor (caller falls back), 2 asked but not up.
serve::request_launch() {
    local waited=0
    serve::supervisor_alive || return 1
    [ -p "$DROSTE_SERVE_REQ_FIFO" ] || return 1
    # The supervisor holds a read end open, so this write returns immediately. The
    # timeout is not for the normal case — it is so a supervisor that died between the
    # liveness check above and this line cannot hang a user's terminal on an open().
    timeout 5 sh -c "printf 'launch\n' >> \"\$1\"" sh "$DROSTE_SERVE_REQ_FIFO" \
        2>/dev/null || return 1
    while [ "$waited" -lt "$DROSTE_SERVE_REQ_WAIT" ]; do
        serve::state_ok && return 0
        sleep 1
        waited=$((waited + 1))
    done
    return 2
}

# ── Socket ownership: does OUR process actually hold the port? ──────────────
# The last hole in "this box is serving": gate 1 proves our recorded process is ALIVE
# and gate 2 proves SOMETHING answers the port, but neither proves they are the same
# thing. A process can be alive and not listening (its server thread died, or it never
# bound and did not exit) — and under HOST NETWORKING anything on the machine can then
# take that port and answer the probe. The box reported HEALTHY while serving nothing.
#
# 🔧 PURE PROCFS, NO NEW DEPENDENCY. `ss -tlnp` is the obvious tool and iproute2 is
# NOT installed in any of these images — adding a package to satisfy a health probe is
# a worse trade than reading the two files the kernel already exposes. /proc/net/tcp
# gives the inode of the LISTEN socket on our port; /proc/<pid>/fd tells us whether
# that inode is ours.
#
# ⚠️ THIS GATE ONLY EVER DENIES ON POSITIVE EVIDENCE. Returns:
#   0  ours          — our pid (or a descendant) holds a LISTEN socket on that port
#   1  NOT ours      — someone else holds it, and we know who does not
#   2  cannot tell   — unreadable procfs, no listener found, etc.
# The caller treats 2 as "carry on", never as a failure. A health probe that restarts
# containers must not act on an inconclusive read.
serve::_listen_rows() {  # port → "<inode> <uid>" per LISTEN socket on that port
    # The unused names are the procfs COLUMN LAYOUT, kept in full so the fields we do
    # read are provably the right ones: sl local rem st tx:rx tr:tm retrnsmt uid
    # timeout inode. Collapsing them to positional junk is how a column shift goes
    # unnoticed after a kernel format change.
    # shellcheck disable=SC2034
    local port=$1 hp f sl loc rem st txrx trtm retr uid tmo inode rest
    hp=$(printf '%04X' "$port" 2>/dev/null) || return 1
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] || continue
        # shellcheck disable=SC2034
        while read -r sl loc rem st txrx trtm retr uid tmo inode rest; do
            [ "$st" = 0A ] || continue          # 0A = TCP_LISTEN (skips the header too)
            [ "${loc##*:}" = "$hp" ] || continue
            printf '%s %s\n' "$inode" "$uid"
        done < "$f"
    done
    return 0
}

serve::_pid_holds_inode() {  # pid, inodes → 0 holds one of them, 1 no, 2 cannot read
    local pid=$1 inodes=$2 fd target ino want
    [ -d "/proc/$pid/fd" ] || return 2
    ls "/proc/$pid/fd" >/dev/null 2>&1 || return 2   # alive but not ours to inspect
    for fd in "/proc/$pid/fd"/*; do
        target=$(readlink "$fd" 2>/dev/null) || continue
        case "$target" in
            'socket:['*']') ino=${target#socket:[}; ino=${ino%]} ;;
            *) continue ;;
        esac
        for want in $inodes; do
            [ "$ino" = "$want" ] && return 0
        done
    done
    return 1
}

# port_owned_by_us — the whole check. Fast path first: our own fds, ONE directory read.
# Only when that fails do we pay for a descendant walk, because a server may hand its
# listening socket to a worker child (vllm forks; the socket is inherited, so the fd
# lives in a process whose ancestry reaches ours). That walk needs a pid→ppid map, and
# under `--pid host` /proc holds every process on the machine — which is exactly why it
# is on the rare path and not the common one.
serve::port_owned_by_us() {  # port, pid → 0 ours | 1 not ours | 2 cannot tell
    local port=$1 pid=$2 rows inodes rc p ppid depth stat ourid ino uid same
    rows=$(serve::_listen_rows "$port") || return 2
    # NOTHING LISTENING is not really "cannot tell" — under host networking the box
    # shares the netns, so an empty result means nothing in that namespace is serving,
    # and we know it. It returns 2 so the PROBE reports it, because "no HTTP response
    # (curl exit 7)" is the more actionable sentence than anything this gate would say.
    # Behaviour, not ignorance.
    [ -n "$rows" ] || return 2
    inodes=$(printf '%s\n' "$rows" | while read -r ino uid; do printf '%s\n' "$ino"; done)
    serve::_pid_holds_inode "$pid" "$inodes"; rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 2 ] && return 2
    # Not held by our pid directly. Look for a DESCENDANT that holds it.
    for p in /proc/[0-9]*; do
        p=${p#/proc/}
        serve::_pid_holds_inode "$p" "$inodes" || continue
        # p holds it — is p a descendant of our pid? Walk up its ppid chain.
        depth=0
        while [ "$p" != 1 ] && [ "$p" != 0 ] && [ -n "$p" ] && [ "$depth" -lt 32 ]; do
            [ "$p" = "$pid" ] && return 0
            stat=$(cat "/proc/$p/stat" 2>/dev/null) || break
            stat=${stat##*") "}
            # shellcheck disable=SC2086   # deliberate word split of a numeric stat line
            set -- $stat
            ppid=${2:-}
            [ -n "$ppid" ] || break
            p=$ppid
            depth=$((depth + 1))
        done
        return 1        # somebody else's process is holding our port
    done
    # ⭐ LAST EVIDENCE BEFORE GIVING UP: the socket's OWNING UID, which /proc/net/tcp
    # gave us for free in the same read. We get here when no pid could be attributed —
    # the holder's /proc/<pid>/fd is unreadable, i.e. it belongs to another user. If
    # EVERY listener on this port is owned by a different uid than our recorded
    # process, that is POSITIVE evidence the listener is not ours, so it is a denial
    # and not a shrug. Sound in this architecture because the whole service tree runs
    # as the box user: setpriv sets uid AND gid and children inherit, so our own socket
    # can only ever carry our own uid.
    # ⚠️ A uid that MATCHES proves nothing (same user, different process), so that case
    # stays "cannot tell". The residue — a same-uid squatter with an unreadable fd
    # table — is a genuine limit of procfs without privileges we do not have, not a
    # gap to be closed by being cleverer here.
    ourid=$(stat -c %u "/proc/$pid" 2>/dev/null) || ourid=""
    if [ -n "$ourid" ]; then
        same=0
        while read -r ino uid; do
            [ -n "${uid:-}" ] || continue
            [ "$uid" = "$ourid" ] && same=1
        done <<<"$rows"
        [ "$same" -eq 0 ] && return 1
    fi
    return 2            # a listener exists, same uid or unknown — genuinely unresolved
}

# ── Adoption: the port is busy — is the holder THIS BOX'S OWN SERVICE? ──────
# The INVERSE of serve::port_owned_by_us, and the reason that one could not simply be
# called from the refusal path: it verifies a pid we already have, and the refusal path
# is precisely the path with no pid to verify (serve::relaunch writes the record's pid
# field as "-", which _pid_is_ours rejects by design). Same two procfs files, same two
# helpers, opposite direction: name the holder first, then decide whether it is ours.
#
# ⚠️ ADOPTION IS A STRONGER CLAIM THAN REFUSAL AND CARRIES A HEAVIER BURDEN OF PROOF.
# Refusing needs only "something is on that port". Adopting writes `running` into the
# launch record, which is the one thing that makes droste-healthcheck.sh call this box
# healthy — and it hands server_stop a pid it is willing to signal. So ALL THREE proofs
# below must hold; any one of them failing refuses exactly as before, and no path here
# ever starts a process.

# _port_holder_pid — which visible pid holds a LISTEN socket on <port>? Fails when there
# is no listener, or when no holder's fd table is ours to read (a process outside our
# user namespace) — both of which mean "cannot claim it", which is a refusal.
#
# ⭐ IT ANSWERS WITH THE ANCESTOR, AND THAT IS NOT A REFINEMENT — IT IS THE ANSWER.
# A listening socket is INHERITED across fork (the same reason serve::port_owned_by_us
# walks descendants at all: vllm hands its listener to workers), so several pids hold
# ONE inode and /proc's glob order between them is lexical, i.e. arbitrary — "1001"
# sorts before "999". Naming a worker would put a worker's pid in the launch record,
# and server_stop signals exactly the pid in the record: it would kill one worker, watch
# _pid_is_ours go false, and report "Server stopped." while the parent kept serving.
# So: collect every holder, then answer with the one whose PARENT is not also a holder.
# That costs the full /proc walk instead of stopping at the first match — the same walk
# port_owned_by_us already pays on its rare path, and this path is rarer still (only a
# busy port reaches it).
serve::_port_holder_pid() {
    local port=$1 rows inodes p holders="" stat ppid
    # shellcheck disable=SC2034   # ino/uid name the procfs columns; only ino is used
    local ino uid
    rows=$(serve::_listen_rows "$port") || return 1
    [ -n "$rows" ] || return 1
    inodes=$(printf '%s\n' "$rows" | while read -r ino uid; do printf '%s\n' "$ino"; done)
    for p in /proc/[0-9]*; do
        p=${p#/proc/}
        serve::_pid_holds_inode "$p" "$inodes" || continue
        holders="$holders $p"
    done
    holders=${holders# }
    [ -n "$holders" ] || return 1
    for p in $holders; do
        stat=$(cat "/proc/$p/stat" 2>/dev/null) || continue
        stat=${stat##*") "}
        # shellcheck disable=SC2086   # deliberate word split of a numeric stat line
        set -- $stat
        ppid=${2:-}
        case " $holders " in *" $ppid "*) continue ;; esac
        printf '%s' "$p"
        return 0
    done
    # Every holder's parent is also a holder (the top of the tree exited between the two
    # walks, or its stat was unreadable). Any of them still proves the port is held by
    # this box; take the first rather than refuse over a race.
    printf '%s' "${holders%% *}"
    return 0
}

# _same_container — is <pid> a process of THIS container? The MOUNT namespace answers it
# in both shapes these boxes run in: podman always gives the container its own, and it
# does not depend on whether the box was created with `--pid host` (under which /proc
# lists the whole machine and mere visibility proves nothing). An unreadable link is a
# NO, not a shrug: /proc/<pid>/ns/* needs ptrace-read on the target, which we have for
# our own container's processes and do not have for a stranger's — so the failure mode
# points at refusal, which is the safe direction.
serve::_same_container() {
    local pid=$1 mine theirs
    mine=$(readlink "/proc/self/ns/mnt" 2>/dev/null) || return 1
    theirs=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null) || return 1
    [ -n "$mine" ] && [ "$mine" = "$theirs" ]
}

# _endpoint_ok — does the BOX'S OWN endpoint answer acceptably on <port>? The same
# question droste-healthcheck.sh's gate 2 asks (build-spec HEALTH_PATH / HEALTH_ACCEPT),
# and deliberately NOT the question serve::_port_busy asks: that one counts a TIMEOUT as
# occupied, which is right for "may I bind?" and catastrophic for "may I call this
# mine?". A wedged holder must keep refusing, not get adopted and reported healthy.
serve::_endpoint_ok() {
    local port=$1 code
    command -v curl >/dev/null 2>&1 || return 1
    serve::read_health_spec
    # serve::probe speaks whichever scheme this box's server actually answers, so a
    # TLS box can be recognised as our own instead of being refused forever. Its rc
    # is deliberately ignored here: a TLS handshake can leave a non-zero exit behind
    # an HTTP code we did receive, and the code is the whole question at this gate.
    code=$(serve::probe "$port" "$HEALTH_PATH") || true
    [ -n "$code" ] && [ "$code" != 000 ] || return 1
    case "$HEALTH_ACCEPT" in
        any) return 0 ;;
    esac
    [ "$code" -ge 200 ] && [ "$code" -lt 400 ]
}

# adopt_running — claim an already-running server as this box's own, or decline.
# On success the record reads exactly as if we had launched it (pid + START TIME, so
# _pid_is_ours pins the identity the same way) under THIS call's token, which puts the
# next maybe_launch of this container start on the "already launched" fast path.
# Says so loudly in both logs: this is a recovery from a state that should not happen,
# and the note is the breadcrumb that lets the cause be found later — today the
# `refused` stamp erases it.
serve::adopt_running() {  # port, token → 0 adopted (record written) | 1 not ours
    local port=$1 token=$2 pid fields start comm
    pid=$(serve::_port_holder_pid "$port") || return 1
    serve::_same_container "$pid" || return 1
    fields=$(serve::_proc_fields "$pid") || return 1
    [ "${fields% *}" != Z ] || return 1
    start=${fields#* }
    serve::_endpoint_ok "$port" || return 1
    comm=$(cat "/proc/$pid/comm" 2>/dev/null) || comm=""
    comm=${comm//[[:space:]]/_}          # the record is 5 SPACE-separated fields
    serve::info "port $port is already served by a process of this box (pid $pid) — adopting it rather than refusing to start a second one."
    serve::_log_note "ADOPTED: pid $pid (${comm:--}) already holds port $port and answers this box's health endpoint; recording it as this box's server."
    serve::_write_state running "$pid" "$start" "$token" "${comm:--}"
    return 0
}

# ── Surgical recovery (used by droste-healthcheck.sh) ───────────────────────
# The container bounce was never the GOAL — it is the MECHANISM podman gave us for
# relaunching a dead service, because it has no "restart just the service". Killing
# every interactive shell in the box is collateral from using a sledgehammer to do a
# screwdriver's job. With --health-retries 3 at 30s there is a ~90-second window in
# which we can try the screwdriver first, and still let podman restart the container if
# it does not work. Honest reporting is preserved throughout: unhealthy is reported as
# unhealthy on every failing probe, including the one that triggers a relaunch.

# _relaunch_due — may we relaunch RIGHT NOW? The cooldown is the one non-negotiable
# part of this feature: probes fire every 30s whether or not the previous relaunch has
# finished, so without it a slow-starting service (ds4 loads up to 430 GB) would get a
# SECOND launch racing the first for the port, and the feature would spawn processes
# instead of recovering them.
# The clock is the launch record's OWN MTIME — no new file, no new format. Default
# cooldown is 120s: longer than the 30s interval, so AT MOST ONE relaunch happens
# inside a 3-retry window, which is exactly the intended shape (check #1 relaunches;
# #2 and #3 observe, and if they still fail podman bounces the container as before).
#
# ⚠️ ONE ACCEPTED IMPRECISION, stated rather than left to be rediscovered: the mtime is
# the last WRITE, which for a healthy server is its launch. So a server that dies within
# the cooldown of starting up does not get relaunched on the first failing probe — it
# waits for the age to pass 120s, possibly using up most of the retry window. That is
# the right way to be wrong: the alternative (relaunch immediately after a recent
# launch) is precisely the crash-loop that spawns processes, and the cooldown's job is
# to prevent that. A long-running server is unaffected — its record is hours old, so a
# crash relaunches on the very next probe, which is the common case this exists for.
: "${DROSTE_SERVE_RELAUNCH_COOLDOWN:=120}"
serve::_relaunch_due() {
    local age
    age=$(serve::_record_age)
    [ "$age" -ge "$DROSTE_SERVE_RELAUNCH_COOLDOWN" ]
}

# warn_ttys — tell anyone actually sitting in the box, BEFORE podman can eject them.
# Today the first thing a user learns is that they have been disconnected. Best-effort
# by construction: a tty we cannot write to is not a reason to fail a health probe.
# ⚠️ The wording distinction here is load-bearing and must survive editing: the
# relaunch sentence says SERVER, the fallback sentence says BOX — because that one
# really is the container restarting.
serve::warn_ttys() {
    local msg=$1 pts
    for pts in /dev/pts/*; do
        [ -w "$pts" ] || continue
        case "$pts" in */ptmx) continue ;; esac
        printf '\n[droste] %s\n' "$msg" > "$pts" 2>/dev/null || true
    done
    return 0
}

# build_service — turn the build-spec into a final SERVICE argv, WITHOUT re-running the
# mounts. resolve::apply_spec's steps 6+7 (source CFG_FILE, run PRE_LAUNCH) are the
# argv-finalising half; steps 1-5 are mounts, overlays and template seeding, which
# belong to the init hook and must not be repeated.
#
# 🚨 THIS LIVES HERE, NOT IN THE VERB SCRIPT, BECAUSE THE HEALTHCHECK NEEDS IT TOO.
# Found by testing, not by reading: serve::relaunch called maybe_launch -> launch, which
# hits `${#SERVICE[@]}` under `set -u` and died with `SERVICE: unbound variable` — the
# healthcheck sources this library but has no argv of its own. The relaunch could never
# have worked, and worse, it left the record stuck on `starting` so every later probe
# reported "a launch is in progress" forever. The design note that `start` is "a thin
# wrapper over maybe_launch" was true of the VERB (which builds the argv) and not of the
# PROBE. One copy, both callers.
serve::build_service() {
    local spec=${DROSTE_BUILD_SPEC:-/opt/resources/build-spec}
    [ -f "$spec" ] || { serve::err "no build-spec at $spec — cannot tell what this box's server is."; return 1; }
    SERVICE=()
    CFG_FILE=""
    PRE_LAUNCH=""
    # shellcheck disable=SC2034  # consumed by resolve::apply_spec, defined for set -u
    OVERLAYS=() SURFACES=() CRITICAL=() OPTIONAL=() CACHES=()
    # shellcheck source=/dev/null
    source "$spec" || { serve::err "could not read $spec"; return 1; }
    # Child-shell apply, identical to the distrobox lane's step 6 — one behaviour, both
    # doors. This lane matters even more than the other: a config typo here would abort
    # serve::build_service, which the HEALTHCHECK also calls, so it would take out the
    # relaunch path as well as the launch path. See droste-cfgapply.sh.
    droste::cfg_apply "${CFG_FILE:-}"
    if [ -n "${PRE_LAUNCH:-}" ]; then
        "$PRE_LAUNCH" || serve::warn "PRE_LAUNCH reported a problem; continuing with the argv as built."
    fi
    [ "${#SERVICE[@]}" -gt 0 ] || { serve::err "the build-spec defines no SERVICE."; return 1; }
    return 0
}

# relaunch — one attempt to bring the service back WITHOUT bouncing the container.
# Marks the record `starting` first so a probe arriving mid-launch can tell "a launch is
# in flight" from "nothing is running" — that is the whole reason `starting` was added
# to the existing status vocabulary rather than as a second file.
serve::relaunch() {
    serve::_log_note "RELAUNCH: the healthcheck found the service down; relaunching without restarting the container."
    # Build the argv BEFORE claiming a launch is starting: if the spec is unreadable
    # there is nothing to start, and a `starting` record we never follow through on
    # would tell every later probe that a launch is in flight forever.
    if ! serve::build_service; then
        serve::_write_state failed - - - -
        return 0
    fi
    serve::_write_state starting - - - -
    # maybe_launch re-reads the record it just found: pid "-" cannot match a live
    # process (_pid_is_ours rejects it), so it falls straight through to the port check
    # and a fresh launch — which is the intended path, not a coincidence.
    serve::maybe_launch
    # ⚠️ NEVER LEAVE `starting` BEHIND. maybe_launch has several early returns that write
    # no record at all (intent cleared mid-probe, no usable port); any of them would
    # strand the marker written above and wedge every subsequent probe on "a launch is
    # still in progress". If nothing overwrote it, the launch did not happen.
    if serve::_read_pidfile && [ "$SERVE_REC_STATUS" = starting ]; then
        serve::_write_state failed - - - -
    fi
    return 0
}

# exec_service — the FOREGROUND door (server lane, pid 1). Byte-for-byte the
# behaviour droste-entrypoint.sh had inline: exec the spec's SERVICE argv.
serve::exec_service() {
    if [ "${#SERVICE[@]}" -eq 0 ]; then
        serve::err "no SERVICE to exec"
        return 1
    fi
    exec "${SERVICE[@]}"
}
