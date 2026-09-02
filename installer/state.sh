# ── State ────────────────────────────────────────────────────────────────────
declare -A ACTION            # box → new|keep|recreate|modify
declare -A CFG_BOXSV         # box → 1|""  serve when the BOX starts (<box>.cfg)
declare -A CFG_HSTSV         # box → 1|""  start the box at HOST BOOT (user unit)
declare -A CFG_PORT          # box → host port the service binds
declare -A CFG_MODE          # box → ""|fuse|copy|ignore  (overlay mitigation)
declare -A CFG_FS            # box → probed fstype of the data dir
# EVERY PATH IN HERE IS HELD AS THE PERSON WHO CHOSE IT WROTE IT (s39): typed,
# read back out of their ini, or — for a placement the installer derived — in
# the spelling of the root it hangs off. Absolute or ~-rooted, never expanded;
# fs_path resolves at the filesystem boundary and the result is never kept.
declare -A PATHS             # "box:label" → host path, as spelled
declare -A EX_INI EX_CTR     # detection (1/"" ; EX_CTR = container state)
declare -A EXD_PATH          # "box:label" → host path from the old ini, as spelled
declare -A EXD_PORT EXD_BOXSV EXD_HSTSV EXD_MODE   # parsed defaults
declare -A SESSION_STATE     # box → ACTIVE|STOPPED (what this run did)
SELECTED=()                  # chosen boxes, canonical order
CONFIGURE=()                 # SELECTED minus keeps (definitions (re)generated)
KEEP=()                      # kept boxes (untouched files; ladder still offered)
HF_CACHE=""
# The box user's home AS THE CONTAINER SEES IT. distrobox mounts the real home
# out of /etc/passwd, which is not necessarily what $HOME is spelled as: a login
# through an aliased or symlinked home (HOME=/srv, passwd=/home/gopher) leaves
# the two different. Anything that names a path INSIDE the box has to use this
# one — $HOME there produced a container-side destination that does not exist,
# which silently unsatisfied the CRITICAL hf-cache bind and re-downloaded
# gigabytes into the container layer.
USER_HOME=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)
[[ -n $USER_HOME ]] || USER_HOME=$HOME
COMPUTE_CACHE=""             # shared MIOpen/Triton/torch/vLLM kernel cache
MODELS_DIR=""                # "" = not configured
EMIT_DIR=""
RUNG="w"                     # w|p|c|a

RUNTIME="" RUNTIME_BIN="" ROOTLESS=0 HAVE_DISTROBOX=0
LINGER=""                    # yes|no|"" (unknown) — user-manager lingering
PF_ME="" PF_UID=""           # this user's name + uid (subordinate-id lookups)
PF_STOP=0                    # 1 = preflight found something it must block on

# WHOSE SESSION IS THIS? `sudo -iu droste` / `su - droste` gives a shell that
# looks right and works for everything the installer does — until
# distrobox-assemble, which hard-refuses ("Running distrobox-assemble via
# SUDO/DOAS is not supported"). On a first run that refusal lands AFTER tens of
# GB of image have been pulled, so the check belongs here, at the top — and it
# is the one preflight row that stops the run.
pf_session() {
  local via="" who=""
  if [[ -n "${SUDO_USER:-}" ]]; then via=SUDO_USER who=$SUDO_USER
  elif [[ -n "${DOAS_USER:-}" ]]; then via=DOAS_USER who=$DOAS_USER
  fi
  if [[ -z $via ]]; then
    pf_ok "session belongs to $PF_ME (not sudo/su-derived)"
    return 0
  fi
  # $who is who reached for sudo; $PF_ME is who the boxes would belong to, and
  # therefore who has to be logged in for distrobox to accept the run.
  pf_bad "sudo/su-derived shell ($via=$who) $EMD distrobox will refuse it"
  pf_hint "and it refuses AFTER the pulls, so this run stops here instead"
  pf_hint "systemd: $(emph "machinectl shell $PF_ME@") (pkg systemd-container)"
  pf_hint "or $(emph "ssh $PF_ME@localhost") $EMD anything that is a real login"
  PF_STOP=1
  return 0
}

# ── Subordinate id ranges (the lchown EINVAL lesson) ─────────────────────────
# Rootless podman maps container uids/gids through the ranges /etc/subuid and
# /etc/subgid grant this user, and it caches that map in its storage the FIRST
# time it runs. Ranges added afterwards never reach a storage that is already
# initialised: the pull then dies mid-download with "lchown …: invalid
# argument" (an unmapped gid), GBs in. So BOTH halves are checked, before the
# build ladder can pull anything — the grant on paper, and the map podman
# actually holds.
SUBID_MIN=65536
subid_count() {   # subuid|subgid → largest count granted to this user (0=none)
  local db=$1 out="" n best=0
  # getent knows the databases on hosts with libsubid NSS; everywhere else the
  # file IS the database. Entries may be keyed by name or by uid.
  out=$(getent "$db" "$PF_ME" 2>/dev/null) || out=""
  if [[ -z $out && -r /etc/$db ]]; then
    out=$(grep -E "^($PF_ME|$PF_UID):" "/etc/$db" 2>/dev/null) || out=""
  fi
  while IFS=: read -r _ _ n; do   # <name>:<first id>:<count>, count is ours
    [[ $n =~ ^[0-9]+$ ]] || continue
    [[ $n -gt $best ]] && best=$n
  done <<<"$out"
  printf '%s' "$best"
}

idmap_rows() {   # uid_map|gid_map → rows podman really maps (0 = no probe)
  local out
  out=$("$RUNTIME_BIN" unshare cat "/proc/self/$1" 2>/dev/null) \
    || { printf 0; return 0; }
  # One row = the user's own id and nothing else, which is exactly the state a
  # storage initialised before the grant is stuck in.
  awk 'NF {c = c + 1} END {print c + 0}' <<<"$out"
}

pf_idmap() {
  local u g ru rg
  # Rootful podman (and docker) map container ids directly and grant no
  # subordinate ranges; `podman unshare` refuses to run there at all.
  [[ $RUNTIME == podman && $ROOTLESS -eq 1 ]] || return 0
  u=$(subid_count subuid)
  g=$(subid_count subgid)
  if [[ $u -lt $SUBID_MIN || $g -lt $SUBID_MIN ]]; then
    if [[ $u -eq 0 || $g -eq 0 ]]; then
      pf_bad "no subuid/subgid range for $PF_ME $EMD rootless pulls cannot map ids"
    else
      pf_bad "subuid/subgid range for $PF_ME is short ($u/$g < $SUBID_MIN ids)"
    fi
    pf_hint "grant one: $(emph "sudo usermod --add-subuids 100000-165535 \\")"
    pf_hint "$(emph "                        --add-subgids 100000-165535 $PF_ME")"
    pf_hint "then $(emph 'podman system migrate') $EMD podman caches the old map"
    # Returning HERE, before the unshare probe, is the point: `podman unshare`
    # initialises the storage it is asked about, and a storage first
    # initialised without the grant is exactly the stale map above.
    return 0
  fi
  ru=$(idmap_rows uid_map)
  rg=$(idmap_rows gid_map)
  # 0 rows is not a short map, it is no answer at all (podman unshare could not
  # run — no newuidmap, a locked-down host, a broken runtime dir). Say so
  # instead of diagnosing a map that was never read.
  if [[ $ru -eq 0 || $rg -eq 0 ]]; then
    # TWO rows, because the probe answers two different questions and only one
    # of them came back: the grant on paper IS good (✅), the map podman holds
    # simply went unread (🔶 — maybe fine, maybe the lchown death). Saying that
    # in one row made the good half look like part of the problem, and the two
    # hint lines under it explained a failure that has not happened yet; the
    # fix now rides in the caution row itself.
    pf_ok "subuid/subgid granted ($u ids)"
    pf_note "$RUNTIME id mapping unverified; if pull fails, try \"$RUNTIME system migrate\""
    return 0
  fi
  if [[ $ru -lt 2 || $rg -lt 2 ]]; then
    pf_bad "podman maps only your own id ($ru/$rg rows) $EMD pulls die mid-layer"
    pf_hint "the ranges above were granted after podman first ran, so its"
    pf_hint "storage never saw them: $(emph 'podman system migrate'), then re-run"
    return 0
  fi
  pf_ok "subuid/subgid mapping live ($u ids; $ru/$rg map rows)"
  return 0
}

