# ── Preflight (warns; one hard stop) ─────────────────────────────────────────
preflight() {
  section "Preflight" intro
  say ""
  PF_ME=$(id -un)
  PF_UID=$(id -u)
  # First row, because it is the only one that ends the run — a reader who has
  # to act on it should not have to find it halfway down the report.
  pf_session
  if command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
    RUNTIME_BIN=$(command -v podman)
    [[ ${EUID:-$(id -u)} -ne 0 ]] && ROOTLESS=1
    pf_ok "podman found ($([[ $ROOTLESS -eq 1 ]] && echo rootless || echo rootful))"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME=docker
    RUNTIME_BIN=$(command -v docker)
    pf_ok "docker found (podman not present)"
    pf_hint "docker satisfies distrobox's dependency, so no podman comes in;"
    pf_hint "the image pulls need it: $(emph 'sudo apt install podman') (apt distros)"
  else
    pf_bad "neither podman nor docker found $EMD definitions will still be written"
    pf_hint "apt distros: $(emph 'sudo apt install podman') $EMD else your package manager"
  fi
  # Ordered after the runtime row on purpose: it has nothing to say until it
  # knows there is a rootless podman to ask (it returns silently otherwise).
  pf_idmap
  if [[ -e /dev/kfd && -e /dev/dri ]]; then
    pf_ok "GPU devices present: /dev/kfd /dev/dri"
  else
    # No reassuring tail: on THIS installer's hosts the GPU is the point, and a
    # 🚨 that ends in "fine on a non-GPU host" reads as its own dismissal.
    pf_bad "GPU devices missing (/dev/kfd, /dev/dri)"
  fi
  # ONE list, used twice: the prose names the groups exactly as the usermod
  # argument spells them (bare commas), which is also what brings the row to 79
  # columns — the width the whole report is drawn to.
  local g missing=""
  for g in render video; do
    id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$g" || missing="$missing,$g"
  done
  missing=${missing#,}
  if [[ -n $missing ]]; then
    pf_bad "not in $missing (fix: sudo usermod -aG $missing \$USER; re-login)"
  else
    pf_ok "user is in the render + video groups"
  fi
  if [[ -e /dev/fuse ]]; then
    pf_ok "/dev/fuse present (fuse-overlayfs fallback option)"
  else
    # 🔶, not 🚨: fuse-overlayfs is one of three mitigation options, so losing
    # it only blocks the run on a filesystem that turns out to need it.
    pf_note "/dev/fuse missing $EMD fuse-overlayfs fallback unavailable"
  fi
  # The pull path is curl (POST to the podman REST API) piped into python3
  # (which aggregates the per-layer byte counts into one bar). Both are hard
  # dependencies of an image pull; neither is needed to write definitions.
  if command -v python3 >/dev/null 2>&1; then
    pf_ok "python3 found (image-pull progress)"
  else
    pf_bad "python3 not found $EMD image pulls will fail (definitions still written)"
  fi
  if command -v curl >/dev/null 2>&1; then
    pf_ok "curl found (image-pull transport)"
  else
    pf_bad "curl not found $EMD image pulls will fail (definitions still written)"
  fi
  # Lingering: a rootless user manager exits at logout unless the user lingers,
  # which would take BOTH the boot auto-start units and podman's own healthcheck
  # timers down with it. Reported here; offered for real (bare `loginctl
  # enable-linger`, no sudo — verified on hardware) only if a box actually asks
  # to start at host boot. See enable_linger().
  probe_linger
  case "$LINGER" in
    yes) pf_ok "user lingering enabled (boot auto-start + healthcheck timers)" ;;
    no)  pf_note "user lingering off $EMD needed to start boxes at host boot (offered later)" ;;
    # Unknown is 🔶: nothing is wrong yet, the installer just could not look —
    # and the boot auto-start offer later on works it out for itself.
    *)   pf_note "cannot read user lingering state (loginctl missing?)" ;;
  esac
  command -v distrobox >/dev/null 2>&1 && HAVE_DISTROBOX=1
  if [[ $HAVE_DISTROBOX -eq 0 ]]; then
    # The blocker and its fix in ONE row: the hint under it said the same thing
    # at a second indent, and this is the row a first-time reader stops at.
    pf_bad "distrobox missing; needed to create boxes. Try \`sudo apt install distrobox\`"
  fi
  # The whole report is printed first, THEN the run ends: a session that has to
  # be replaced is worth reporting alongside everything else the new one will
  # find. This is the one thing preflight blocks on (see pf_session).
  if [[ $PF_STOP -eq 1 ]]; then
    say ""
    die "log in as $PF_ME itself, then re-run (see the $MK_BAD row above)"
  fi
  return 0
}

# `loginctl show-user -p Linger` without --value (systemd < 231 lacks it), and
# without failing the run when there is no loginctl / no session at all.
probe_linger() {
  local out
  LINGER=""
  command -v loginctl >/dev/null 2>&1 || return 0
  out=$(loginctl show-user "${USER:-$(id -un)}" -p Linger 2>/dev/null) || return 0
  case "${out#Linger=}" in
    yes) LINGER=yes ;;
    no)  LINGER=no ;;
  esac
  return 0
}

