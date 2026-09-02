# BUILD_NOTES.md

Recovered engineering rationale that was trimmed out of the Containerfiles for
readability (as of commit `0ed6498`). The comment-rich originals live at commit
`2344772`; this file preserves the "why" behind each layer as a companion doc.
Nothing here changes the build — it only documents intent, ordering constraints,
pin reasoning, patch purposes, and known-issue workarounds.

---

## Cross-cutting rationale (shared across images)

These notes repeated across multiple Containerfiles. They are stated once here
and referenced from the per-image sections below.

### The unified pin (`base/rocm-version.env`, formerly root `rocm-version.env` / `rocm-pin.env`)
- ONE pinned TheRock gfx1151 nightly feeds every image, and the pin file is the
  ONLY place those versions are written. `base/Container.runtime` — the single
  root of the FROM tree (everything else builds FROM a droste image) — `COPY`s
  it to `/etc/droste/rocm-version.env`; every downstream image inherits that
  exact file through `FROM`, and every version-consuming `RUN` opens with
  `. /etc/droste/rocm-version.env` and reads the values from the shell.
- Consequences worth stating: there are NO version `ARG`s (and no version
  `--build-arg`s in CI) — an image cannot be handed a pin that disagrees with
  its base, so a port can never outrun the base it was built on. The old scheme
  (a wrapper/CI step sourcing the file and passing each key as `--build-arg`,
  with matching `ARG` defaults per Containerfile) duplicated the truth three
  ways and is gone. The `RUN` shell — not the Dockerfile parser — expands
  `${VAR}` in shell-form `RUN`, which is what makes the sourced values visible.
- Cache/placement: the `COPY` sits BELOW the runtime base's apt layers, so a pin
  bump rebuilds from the ROCm install down rather than from apt down. The file
  also ships in every runtime image (`cat /etc/droste/rocm-version.env` reports
  the pin an image was actually built from).
- Nothing uses an apt ROCm repo or an S3 `therock-dist` tarball — the runtime
  kernels and the SDK are both pip-installed from the same nightly index, so the
  whole set is ABI-matched from one source. This replaced both the apt ROCm
  7.2.4 repo (old llama/ds4) and the S3 tarball (old finetuning/vllm).
- Why the date is the binding constraint: torch is the limiter. The newest
  Linux + cp313 (Debian 13 = Python 3.13) torch wheel sits on `7.13.0a20260501`;
  `rocm-sdk-devel` and `rocm-sdk-libraries-gfx1151` both exist at that exact
  date, so everything lines up on one rocm version line.
- Bump procedure: pick a newer date where torch (Linux, cp313) AND both
  `rocm-sdk-*` wheels coexist on ONE rocm version line; update all fields
  together. Verify provenance post-install:
  `cat $(rocm-sdk path)/share/therock/therock_manifest.json`.
- `gfx1151`-ONLY: native kernels exist (`rocm-sdk-libraries-gfx1151`, ~573 MB).
  A `gfx1100` fast-path was DECLINED — the gfx110X-dgpu libs are stuck at
  `7.10.0a` (Nov 2025), version-mismatched vs our `7.13.0a`; it would add ~280 MB
  for an ABI-risky, temporary perf gain.

### canopy de-divert + GNU coreutils rehydrate
- The canopy base routes coreutils/etc. to busybox via `.distrib` dpkg
  diversions, but pip/apt postinsts need the real GNU binaries. So: remove the
  `.distrib` diversions, then rehydrate GNU coreutils BEFORE any other install.
- This is done once in the runtime base and inherited by the build base, so the
  de-divert happens exactly once for the whole ROCm lineage. Anything compiled
  in the build base therefore ABI-matches the runtime libs shipped by the
  runtime base. (Lifted verbatim from the old amd-runtime-base / droste-seed.)

### `localhost/` base-image prefix (local podman vs CI)
- Local rootless podman builds need a `localhost/` prefix on locally-built base
  images, which is why the `BASE_IMAGE`/`ARTIFACTS_IMAGE` defaults use it.
- CI overrides them to the registry, e.g.
  `--build-arg BASE_IMAGE=ghcr.io/<owner>/rocm-runtime-base:<tag>` and
  `--build-arg ARTIFACTS_IMAGE=ghcr.io/<owner>/<port>-artifacts:<tag>`.

### The scratch-carrier "artifacts seam"
- Each build-carrier compiles ONLY its own gfx1151 outputs and ships them from a
  `FROM scratch` stage holding just `/artifacts`. The runtime image does a
  `COPY --from` off the carrier. The carrier never ships as a runnable image, so
  it carries none of the SDK/toolchain that built it.
- The seam invariant: ROCm runtime `.so` (hip runtime, rocBLAS/hipBLAS/hipBLASLt/
  MIOpen) come from the runtime base's `rocm-sdk-libraries-gfx1151` wheel, NOT
  from any carrier. Ports therefore re-add NO ROCm/`-dev` packages.
- `FROM scratch` has no shell, so the carrier stages have no `CMD`.

### Reproducibility FLAG (recurring known issue) — CLOSED at `c756385`
- Several source clones defaulted to a moving upstream branch HEAD. Each carries a
  `*_REF` ARG so a fixed sha/tag can be pinned at build time, and `c756385` ("Pin
  all float-HEAD upstream refs to SHAs", 2026-07-05) filled every one of them with
  the upstream head that had just built green. Nothing in the tree floats now:
  every `*_REF` is a sha, except `VLLM_REF`, which is the tag `v0.16.0`.
  ⚠️ Several sections below still carry per-ref "must get a sha pin" FLAGs. Those
  describe the state BEFORE that commit; each is annotated at its own site now, and
  each names the branch its sha came off, which is the provenance the comment above
  each ARG records. No date is given here on purpose — the refs move independently,
  so a single cross-cutting date cannot say how stale any one of them is; the dates
  live per ref, at the ref.
- Unchanged by any of that: the provenance sha in a header pins only the toolbox
  repo, not the upstream app/library repos.

### profile.d login-shell wiring (interactive toolboxes)
- The runtime base already writes `/etc/profile.d/rocm.sh` (activates the venv +
  exports `ROCM_PATH`), so upstream Fedora `venv.sh` is intentionally not ported.
- Interactive toolboxes add: `01-rocm-env*.sh` (torch/AOTriton/Triton serve-time
  env), `99-toolbox-banner.sh` (login banner), `zz-venv-last.sh` (keeps
  `/opt/venv/bin` first on PATH under distrobox user dotfiles), and a
  core-dump-suppression guard.

### distrobox host-home hazards
- Distrobox/Toolbox shares the host home directory. `PYTHONNOUSERSITE=1` prevents
  the host's `~/.local/lib/python*` from shadowing container-installed packages
  (e.g. the hf CLI importing a host-side broken `huggingface_hub`).
- The old `/opt` world-write hack (`chmod -R a+rwX /opt`) is RETIRED: writability
  now comes from the venv overlay upper + the user's own binds (see "Runtime
  contract" below), so nothing in the baked tree needs loosening.

---

## Runtime contract — shared resolver + per-port build-spec

The "bucket B" rework turned all five ports from interactive `CMD bash` toolboxes
into servers-by-default with ONE shared runtime mechanism. The moving parts:

### Resolver + entrypoint (baked in the runtime base, inherited by all 5 ports)
- `base/resolve/droste-resolve.sh` — a sourced primitive library (overlay, surface,
  cache-bind, critical, optional-marker, template seeding), baked at
  `/opt/resources/resolve/`. Lane-aware: `DROSTE_LANE=server` (default) mounts;
  `DROSTE_LANE=distrobox` (since v0.2.0) runs the SAME mounts with deliberate
  deviations only — no HF-cache bind (the real home is auto-bound), `/root/`
  destinations remapped to the box user's home, created dirs chowned to the box
  user. (Pre-0.2.0 the distrobox lane skipped every internal mount — see
  "2026-07-09 — lane unification" below for why that was wrong and reversed.)
  **LANE ≠ CONTAINER (2026-08-14).** The two lanes are the resolver's two
  ENTRY POINTS, not two boxes: `server` is reached only through the image
  ENTRYPOINT, i.e. a DIRECT `podman run` (and `check-rocm.sh`), while a box
  created by `distrobox assemble` runs `DROSTE_LANE=distrobox` for BOTH of its
  doors — serving included, because the serve door IS the init hook. See
  "2026-08-14 — one container, two doors" below.
- `droste-entrypoint.sh` — the server-lane ENTRYPOINT for every port. Sources the
  library + the port's `/opt/resources/build-spec`, runs `resolve::apply_spec` in
  the fixed design order (ensure `/opt/data` → SURFACES/OVERLAYS/CACHES → CRITICAL
  → OPTIONAL → templates → CFG_FILE → PRE_LAUNCH), then execs SERVICE — unless the
  user passed a command, which wins (`podman run IMAGE bash` still works).
- `droste-init-hook.sh` — the distrobox-lane counterpart, invoked from
  `targets/<port>/distrobox.ini` `init_hooks` (distrobox replaces pid1, so the
  ENTRYPOINT never runs there). Same spec, `DROSTE_LANE=distrobox`, no exec.
  init_hooks run as root (HOME=/root), so it re-derives the distrobox USER's home
  (first uid >= 1000 in /etc/passwd; `DROSTE_USER_HOME` overrides) before applying
  the spec — that is what lets `$HOME`-relative CRITICALs see the host-home bind.
  Since the merged-container work it ends by calling `serve::maybe_launch` (below).
- `droste-serve.sh` — the shared SERVICE-launch library both doors run through:
  `serve::exec_service` (server lane: the same foreground `exec "${SERVICE[@]}"`
  as always) and `serve::maybe_launch` (distrobox lane: the "server door" of the
  merged one-container shape). maybe_launch reads the box's OWN config surface,
  `/opt/data/<box>.cfg` (the path is the build-spec's `CFG_FILE` row), for the five
  serve settings: `DROSTE_<APP>_{STARTUP_ENABLED,HOST,PORT,TLS_CERT,TLS_KEY}`, the
  prefix coming from the spec's `SERVE_CFG_PREFIX` row and naming the APPLICATION,
  not the box (`DROSTE_JUPYTER_*` on finetuning). `STARTUP_ENABLED` takes
  `{yes, no}`. They are PARSED, never sourced (`droste::cfg_get`), so a bad file
  can never fail the box — the same guarantee the old subshell source bought, now
  on a file that is several hundred lines of the user's own settings. It rewrites
  the port AND the bind address into the SERVICE argv (replace-or-append the
  per-box flags: `--port` on all five; `--host`, except comfyui's `--listen` and
  finetuning's `--ip`), appends the TLS pair when BOTH halves are set, and starts
  the service in the background as the BOX USER via `setpriv --reuid/--regid`
  (supplementary groups inherited, so the GPU device groups survive; runuser/su
  would not).
  Re-entrant by construction: a STATE RECORD on the data volume
  (`state/launch`, one line: `pid starttime token argv0 status`) records
  pid + process start time + a per-container-start token, so a re-run of the init
  line adopts, skips or replaces the previous instance instead of double-starting.
  The `status` field (`running` | `refused` | `failed`) is rewritten by every
  outcome of every start — including the refusals that launch nothing — and is
  what the healthcheck reads as PROOF OF OWNERSHIP; a refusal is also appended to
  `.droste-serve.log` (created at launch, so a start that never launched used to
  leave no log at all, which reads as "nothing ran").
  **A setting can REFUSE the start outright**: no usable `PORT` on a box asked to
  serve at startup, and — ruled s60 — a `HOST` that is not an IPv4 literal or a
  TLS pair with only one half set. Those last two do NOT fall back: a fallback is
  not neutral when it is WIDER than what the user asked for, and on boxes where four
  of five answer without asking who you are — two of them with no auth mechanism to
  turn on at all — silently binding every interface after someone named one address
  is the same shape as a certificate with no key.
  The accepted cost is that such a typo is downtime rather than a degraded start;
  the refusal is loud and names the setting.
  **The server lane never reads server.env** — its ports are podman-published
  `HOST:CONTAINER` remaps, so rewriting the in-container bind would break them.
  (HISTORICAL as written, on both halves: `server.env` was deleted in s60, and the
  published-port remap belonged to the compose lane, retired 2026-08-14 — see "one
  container, two doors" below. The RULE outlived both reasons and still holds: the
  server lane is the direct-`podman run` route only, it reads no serve setting from
  any file, and it rewrites neither port nor bind address — the operator chose both
  on their own command line, and droste ships no published-port definition to
  reconcile with. droste-setup.sh creates no such container, so every INSTALLED box
  goes through the distrobox door and its `<box>.cfg`.)
- `droste-healthcheck.sh` — the container-side probe for
  `--health-cmd` + `--health-on-failure=restart` (wired by droste-setup.sh at create
  time; the images bake NO `HEALTHCHECK`). TWO gates, both required: (1) the state
  record says OUR launch succeeded and that exact pid is still alive, (2) the
  endpoint answers. Gate 1 exists because these boxes use HOST networking — when
  the door refuses a port another process already holds, that squatter's reply
  satisfies gate 2 and the box reported HEALTHY while serving nothing (live-confirmed).
  Reads the same `<box>.cfg` for PORT and HOST, probing the address the server
  BINDS (`serve::probe_addr`: the configured HOST, or `127.0.0.1` when that is the
  `0.0.0.0` wildcard) — a probe still asking `127.0.0.1` after a user picks a
  specific address gets nothing, reports UNHEALTHY forever and is restarted by a
  supervisor doing exactly what it was told. Plus
  the build-spec's `HEALTH_PATH`/`HEALTH_ACCEPT` rows: comfyui `/`, llama `/health`,
  vllm `/health`, finetuning `/` with `accept=any` (jupyter only ever answers 302/403
  unauthenticated), ds4 `/v1/models` (source-verified: ds4-server has no `/health`
  and 404s `/`). A box with serving off is healthy by definition. `--health-start-period`
  MUST cover model load or the box restart-loops.
- `droste-dlwatch.sh` — the download announcer (N24). The one file under `resolve/` that
  is BOTH a sourced library and a program, which is why `base/Container.runtime` gives it
  `+x`: the doors source it for `dlwatch::launch`, and that launcher then EXECs the same
  path as a background daemon. Both doors call it **after `resolve::apply_spec` and before
  the server door** — after, because R8's off switch `DROSTE_DOWNLOAD_ANNOUNCE` lives in
  the box's `<box>.cfg` and does not exist until apply_spec's step 6 has applied it (a
  daemon that read its own kill switch would have to be started to read it); before,
  because llama's router downloads on demand and vLLM's loader downloads while it starts,
  so the watcher wants to be looking already. The daemon holds ONE private fd (9), opened
  `>>` on `/proc/1/fd/2` while still root — an open file description is not
  re-permission-checked after the uid change, and that stream IS `podman logs <box>`,
  which is the ruled output surface. **Not the service log** (`.droste-serve.log`): the
  container log is the only stream that exists before the service does, which is the whole
  point — the healthcheck returns early for a non-serving box, so a long first download is
  exactly the window in which nothing else can speak.
  Polls every `DROSTE_DOWNLOAD_INTERVAL` (5 s) over `<home>/.cache/huggingface`,
  `<home>/.cache/llama.cpp` and any `DOWNLOAD_WATCH` extras a build-spec declares (none
  today; the row exists for ds4's flat `--local-dir` target), globbing for the only two
  partial suffixes any of the five downloaders writes — `*.incomplete` (huggingface_hub,
  both majors, every backend) and `*.downloadInProgress` (llama.cpp). Six globs and one
  `stat` per root, never a walk, so the scan cost is proportional to REPOSITORY COUNT, not
  cache size. Lines are aggregated per repository with the file count as a field:
  STARTED / RESUMED / RUNNING (rate-limited, `DROSTE_DOWNLOAD_REPORT_INTERVAL`) /
  FINISHED / STALLED (`DROSTE_DOWNLOAD_STALL_WINDOW`) / ABANDONED, all six formatted in
  one place so the wording lives in one file.
  🚨 **A PARTIAL THAT NEVER GROWS IS SILENT, AND THAT IS THE FEATURE.** hub 1.x names each
  attempt uniquely and unlinks in a `finally`, so every SIGKILL leaves an orphan
  `.incomplete` that is never reused and never reaped; a cache with any history holds a
  drawer of them, and announcing those would be a false positive on every box at every
  start. The cost is that a genuine resume is announced on its first GROWTH, up to one tick
  late. We do not reap them either — a reaper is a new destructive behaviour and must not
  be smuggled in under an announcement feature. The same silence holds at the far end: a
  group we never announced emits no terminal line.
  ⚠️ **errexit is OFF** (`set -uo pipefail`, matching the healthcheck): a partial vanishing
  between the glob and the `stat` is not an error, it is the FINISHED signal, and a daemon
  that exited on the race it was written to detect would go quiet exactly when it mattered.
  Every arm of `dlwatch::launch` returns 0 and both doors call it `|| serve::warn`, so an
  announcement feature can never cost a user their box; a load failure warns rather than
  going quiet, because the spawn is silent and a missing file would otherwise disable the
  feature permanently and say nothing. Single-instance guard: a pidfile in the program
  cache's `state/`, validated against `/proc/<pid>/cmdline` rather than the pid alone.
  The log prefix `droste-download` is a CONSTANT, not read from the environment: distrobox
  parses the container log while a box starts and aborts `distrobox enter` on a line
  opening `Error:`, `Warning:`, `distrobox:`, `+` or `container_setup_done`, so a cfg able
  to set the prefix could have broken every enter for the duration of a download.
  ⚠️ **One accepted residual, LATENT rather than live.** `scan_root` also globs the
  `--local-dir` shape (`<root>/.cache/huggingface/download/*.incomplete`), and for that
  shape alone a disappearing partial is reported FINISHED rather than ABANDONED: hub names
  it `{_short_hash(name)}.{etag}.incomplete`, and a hash is not a path, so the "the blob
  now exists" test cannot run. Telling every ds4 user that a fetch they just watched
  succeed had failed is the worse of the two errors. It is unreachable as shipped — that
  glob only fires under a root, and no build-spec declares a `DOWNLOAD_WATCH` extra — so
  declaring one is what would make the residual visible.
- **The percentage shim (N24 P4)** — `targets/{comfyui,ds4,vllm,finetuning}/scripts/`
  ships `droste_dlwatch_shim.py` + `zz_droste_dlwatch.pth`, copied into
  `/opt/venv/lib/python*/site-packages/` by each of those four Containerfiles. It lazily
  wraps huggingface_hub's single download funnel `_download_to_tmp_and_move` (the funnel
  behind `hf_hub_download`, `snapshot_download`, `HfApi.*` and the `hf` CLI) and writes the
  expected total — which hub holds only in memory — to a `<blob-stem>.total` sidecar beside
  the partial. `dlwatch::total_for` reads it and the RUNNING line gains a ` (NN%)` suffix;
  with no sidecar the line is byte-identical to the pre-P4 form, which is the One Surface
  constraint that lets llama keep the same grammar with no shim at all.
  🚨 **`sitecustomize.py` DOES NOT WORK FROM A VENV** — `site` imports the FIRST
  `sitecustomize` on `sys.path`, and the system `/usr/lib/python3.13/` copy wins before the
  venv's site-packages is searched (measured). A `.pth` IS executed, needs no `PYTHONPATH`
  and no login shell, and a shim whose import raises prints a site warning while the server
  still starts. And the patch is registered LAZILY on purpose: patching eagerly during
  hub's own circular import raises, hub SWALLOWS the error, and the result is a shim that
  never installs while every download succeeds — the silent no-op this feature exists to
  remove. A hub that renamed the funnel warns once and no-ops.
  Coverage is all-or-nothing per repository: if any live partial in a group has no usable
  sidecar (llama's C++ fetcher writes none, and mixed coverage is the normal case), the
  percentage is omitted rather than computed against an understated denominator. A total
  smaller than the bytes already on disk — a stale sidecar from a shorter revision —
  prints nothing rather than clamping to 100%, because evidence that our input is wrong is
  not evidence about the answer.
- **`is_bound` is an ancestor-walk**, not an exact mountinfo match: the longest
  component-aware mount-point prefix of the target decides (rootfs `/` → unbound;
  anything deeper → bound). Needed because distrobox binds the whole `$HOME` —
  an exact match would false-error every critical living under it.
- **`CFG_FILE` is sourced under `set -a`** so plain `VAR=` lines are exported and
  survive the exec into the service (llama-server reads `LLAMA_ARG_*` from its
  environment) — since s60 in a CHILD shell, with the result applied as an `env -0`
  diff (`droste::cfg_apply`, `base/resolve/droste-cfgapply.sh`); the resolver's own
  process never sources it. llama/ds4 keep belt-and-braces export loops in
  PRE_LAUNCH so their specs stay self-sufficient under other callers. That source
  is for the box's APPLICATION settings: the five serve settings live in the same
  file, and the serve wiring reads them with `droste::cfg_get` (above) rather than
  off the environment copy the source leaves behind — taking `$DROSTE_<APP>_PORT`
  from the environment would quietly put shell semantics back in front of a config
  file.
  Where a spec's own translation emits one of them from the environment anyway
  (ds4's flag table), `serve::apply_port`/`apply_host` overwrite it afterwards, so
  the parsed value is still the one that ships.
  🚨 **THE CHILD IS THE GUARANTEE, AND ITS BLAST RADIUS IS THE WHOLE FILE —
  MEASURED.** A malformed line can no longer take the box down: all three failure
  arms — a `bash -n` syntax failure, a missing sentinel, an unreadable baseline —
  say so and `return 0`. But that child runs under `set -euo pipefail`, so one
  unguarded `$` aborts it BEFORE `env -0` ever runs: there is no diff to apply, the
  sentinel check fails, and a file of 200 good lines applies **NONE** of them — the
  settings ABOVE the offending line included. The box comes up on stock defaults and
  the warning is the only thing that says so: *"$file stopped part-way through, so
  NONE of its settings were applied and this box is running on defaults."*
  ⚠️ **NOT "everything after the bad line" — everything, full stop.** That older
  description is true of the pre-s60 in-process `set -a; source`, where assignments
  made before the abort had already landed in the resolver's own environment. It is
  not true of this one.
  ⭐ **What makes the failure diagnosable:** the baseline child's stderr is discarded
  and the applying child's is not, so bash's own line-numbered message (`<file>:
  line 3: NOT_SET_ANYWHERE: unbound variable`) prints immediately above ours — which
  is what the warning means by "the message just above (if any) is bash's own and
  names the line".
- **The SERVICE-rebuild pattern:** build-spec is sourced bash, so `SERVICE=( … )`
  expands BEFORE CFG_FILE is sourced. Ports whose argv depends on env-file values
  (llama `$DROSTE_LLAMA_EXTRA_ARGS`, ds4's flag translation) declare a placeholder argv
  and rebuild `SERVICE` inside PRE_LAUNCH, which runs after CFG_FILE. Documented
  in `base/resolve/build-spec.example`.

### build-spec (the per-port declaration)
One sourced-bash file per port (`targets/<port>/build-spec`, baked at
`/opt/resources/build-spec`; the name is a placeholder pending a rename). Rows:
`SERVICE / CFG_FILE / OVERLAYS / SURFACES / CACHES / CRITICAL / OPTIONAL /
PRE_LAUNCH` — all paths explicit + absolute (`$HOME` allowed and preferred for
home-relative paths: it is the only form correct in BOTH lanes). SURFACES and
CACHES are structurally identical binds kept as separate rows by design (future
cache-specific behaviour — which arrived in v0.2.0, when CACHES retargeted to
the shared `/opt/caches` volume; see the 2026-07-09 shared compute-cache
entry). There is deliberately no DEFAULTS row — ALL content
seeding is owned by templates.yaml. Contract doc: `base/resolve/build-spec.example`.

**Which root a row uses IS its class declaration (2026-08-15).** There are
three container-side roots, and the prefix of a src/upper carries the whole
classification, so nothing downstream has to guess from a path's contents:
`/opt/data` = per-box PERSISTENT, `/opt/program-cache` = per-box PROGRAM CACHE
(re-obtainable, and the one root the installer may empty whole), `/opt/caches`
= the SHARED compute caches, which no spec writes to directly — it is reached
only by the CACHES rewrite. The single exception to the table is a `.work`
dir, which follows its own upper's root instead (kernel: workdir and upperdir
must share a filesystem). See the 2026-08-15 storage-taxonomy entry below.

### Templates (first-run seeding)
`targets/<port>/templates/` bakes to `/opt/resources/templates/`; the manifest
`templates.yaml` (restricted YAML subset, parsed by the base's stdlib-only
`apply_templates.py` — no pyyaml in the lean images) maps `src: dest` under two
rules: `if_empty` (copy iff dest is a COMPLETELY empty dir — a user who deleted
the starter content expressed intent, nothing is resurrected) and `if_missing`
(copy iff dest does not exist — user edits are never overwritten). Seeding runs
AFTER mounts so seeds land on the bound destinations. The `/opt/models` marker
body (`mount_shared_models_here`) lives in templates/ too, picked up by name by
the OPTIONAL primitive, not by the manifest.

Seeding runs as root, so in the **distrobox lane** the resolver passes
`--owner "$DROSTE_USER"` down to `apply_templates.py` and the script chowns
what it CREATED — the file counterpart of the `_mkuserdir`/`_own_dirs`
deviation. Without it the seeded configs land owned by the container's root,
which is a host subuid under `keep-id` (uid 100000), and "after first start
they are yours to edit" is false: the user needs `sudo chown` first. The chown
sits in the Python because only it knows the exact created set — a
pre-existing dest dir (often a user bind, e.g. comfyui's `input/`) and
anything already inside one are never touched, and nothing is chowned
recursively past the copy that just happened. Server lane passes nothing: its
service is root by design. Boxes seeded before this landed keep their
root-owned copies — the fix is not retroactive (see the README bullet).

### Repo layout convention (per port)
`targets/<port>/profile.d/` → `/etc/profile.d/` (interactive-lane shells);
`targets/<port>/scripts/` → `/opt/resources/scripts/` (baked RO helpers on
PATH/PYTHONPATH, never seeded); `templates/` → `/opt/resources/templates/`;
`build-spec` → `/opt/resources/build-spec`; `distrobox.ini` = repo-side example,
not baked. comfyui's `scripts/tests/` is repo-only (never COPY'd).

### Distrobox-lane writability: ownership, not group membership
The baked venv and `custom_nodes` are root-owned in the image, but the box user
must be able to add, remove and replace entries in them (pip installs, node
clones). The image also creates a shared `droste` group and makes those trees
group-writable — that part still stands, but **no route delivers the group to a
distrobox session**, verified on hardware (rootless podman + crun, gfx1151):

- the init hook's `usermod -aG droste` really does write `/etc/group`, but no
  session re-reads it — `podman exec` sets uid/gid plus `keep-groups` and never
  performs a supplementary-group lookup, and every `distrobox enter` is a
  `podman exec`. Not an ordering race (a second enter is identical) and not a
  numeric-vs-name issue (`--user jjb` behaves the same as `--user 1000`);
- a create-time `--group-add droste` in `additional_flags` is accepted —
  `podman inspect` reports `groupadd=[droste]` — but is swallowed by crun's
  `keep-groups`: the gid never materializes, not even for the container's own
  root process;
- only `podman exec --user <user>:droste` delivers it, and `distrobox.ini` has
  no key for exec-time flags;
- rootless userns also blocks gaining it at runtime (`sg`/`newgrp` → EPERM).

So `resolve::_own_dirs` chowns **directories only** to the box user right after
each overlay mounts. Ownership is uid-based, which sidesteps group semantics,
userns gid mapping and exec credentials in one move. It is cheap **because it
never touches files**: a directory carries no payload, so overlay copy-up of a
chowned dir is metadata-only — measured at 3719 dirs in 0.47s with no
measurable growth in the upper, where a recursive walk over *files* copies every
payload (2.7 GB in an earlier test). `! -uid` makes re-runs a no-op and also
reclaims dirs a **server**-lane run left root-owned in the shared upper, so the
two lanes stop contaminating each other. Never extend this to files.
(2026-08-14: with the lanes merged into one container the crossing is no longer
routine — it now takes a data dir ALSO driven by a direct `podman run`, or one
left behind by a pre-merge install. The reclaim stays precisely because those
dirs exist in the field, and it costs a no-op walk when they do not.)

### Model classification: signals and confidence
`model_scanner.py` asks every applicable measure and lets the weighted score
pick the answer, because the evidence it uses is not all worth the same; the
heuristic ladder it used to classify by is retained for two narrower jobs, and
the registry records how well-supported each answer is.

Evidence splits in two. **Embedded** signals live inside the weight file —
safetensors header, GGUF KV block, pickle opcodes — and cannot be changed
without rewriting the model. **Low-fidelity (LoFi)** signals live outside it:
sidecar files (`config.json`, `model_index.json`, CT2 vocabulary siblings) and
names (path segments, filename, repo name). Sidecars are independently
editable and *are* edited — someone forcing a class name to make a loader
accept a file produces a sidecar that points confidently at the wrong answer,
which is worse than no sidecar at all. LoFi ratings are therefore capped at
0.3 (`LOFI_MAX_RATING`, lowered from 0.6 by owner decision): they may hint,
never certify, and the cap is on the RATING — how sure this instance is — not
on the parts, so every LoFi measure still votes and is still recorded in
`signals`. The naming signals are also **not independent** of each other — a
mislabelled file usually has a matching bad path and repo — so their unanimity
is not six separate confirmations, and the ceiling is what keeps their
agreement below any single reading of the file's own bytes.

Each applicable measure votes with a rating; scores are computed **per
candidate category** (`Σ(parts × rating) ÷ Σ applicable parts`), since measures
vote for different answers and a pooled sum would only say how much evidence
exists. Parts (`MEASURE_PARTS`): safetensors 30, pickle 20, GGUF 20, each LoFi
measure 5. All six LoFi agreeing therefore tops out at 6 × 5 × 0.3 = 9, while
the weakest embedded vote a file can carry — a pickle rated at the generic 0.6
— already reaches 12, and a safetensors read runs from 18 (the generic
encoder+decoder inference) to 29.7 (a tensor prefix that names the model
outright). Embedded evidence consequently wins wherever it exists, and names
decide only where nothing embedded could be read.

The score picks the recorded category. The ladder is kept for exactly two jobs:
a fallback for a file no measure could judge, and the naming-vs-content
comparison — a ladder answer that differs from the winner is recorded as
**DISPUTED**, the companion report to UNCLASSIFIED. A dispute no longer means
the recorded answer is doubtful; it means the names and the data disagreed and
the names lost. It stays the most useful report we have, because that is where a
confident-but-wrong embedded reading surfaces — a multimodal LLM's vision tower
reads as `clip_vision` at 0.99, since the rule cannot tell "HAS a vision
encoder" from "IS one" — and such a file hides precisely where UNCLASSIFIED
cannot look, because it appears settled.

`.pt`/`.pth`/`.ckpt`/`.bin` are content-sniffed via `read_pickle_signals`, whose
reading is `model_formats.read_torch_container` — the one execution-free reader
the scanner and the two adopt tools share — and which **never executes the
payload**: `find_class` imports nothing, returning an inert stub type and
recording the module path, itself the strongest signal for object-pickles like
Ultralytics detectors, which carry no tensor keys at all. Only the pickle
*structure* is read — the zip's `data.pkl`, or, for the legacy non-zip
container, its leading pickles, stopping at the first payload that yields keys
and never past the storage-key list into the raw tensor bytes — so cost is
bounded regardless of file size. What stays in the scanner is its POLICY on the
result (`_signals_or_raise`): a read that succeeds and harvests nothing is a
finding rather than an absence, where the adopt tools want the opposite.
State-dict keys reuse the safetensors classifier rather than growing parallel
prefix rules.

### Per-port notes (bucket-B rework rationale)
- **comfyui** — the wan/qwen "studio" pip stacks were DROPPED with the studios
  (studios-only deps; ComfyUI implements Wan/Qwen natively — watch the first
  runtime test for anything that misses them). The 11 baked SD/SD2 config yamls
  moved out of `models/` to `/opt/resources/model_configs/` (registered back via
  the seeded `extra_model_paths.yaml`); `models/configs/` stays, empty, for user
  drop-ins on their own bind. `get_*.sh` downloaders are cache-native now (plain
  `hf download` into the shared HF cache, no staging/`mv`), and the old
  `clean-cache` verb was REMOVED — it would `rm -rf` the SHARED store. The
  benchmark helpers keep their private port-8000 assumption (they drive their own
  private instance). PRE_LAUNCH runs the model scanner (`model_scanner.py sync`)
  to refresh `/opt/data/model-tree`; a scanner failure logs and continues (stale
  tree, never a blocked server).
- **finetuning** — `chmod -R a+rwX /opt` RETIRED: the venv overlay + the user's
  workspace bind provide all needed writability. The multi-node worker's CWD vs
  script-path split is deliberate: helpers live at `/opt/resources/scripts/`
  (RO, on PATH/PYTHONPATH) while workers run with CWD=/opt/workspace, so relative
  `output-*/` adapters persist on the mount on every node. The baked
  `/opt/workspace` ships EMPTY (it is the user's bind mountpoint); the starter
  notebooks seed from templates only into a completely empty workspace —
  seed-if-empty semantics honor user deletions.
- **vllm** — the upstream TUI's MODEL_TABLE is vendored at toolbox sha
  `6446b9595273f289e11586c3c7d3e1e6f2945888` (`targets/vllm/upstream/models.py`).
  `vllm_config.yaml` is HAND-AUTHORED (`targets/vllm/templates/`) and ships on the
  ordinary `COPY templates/`. It was GENERATED AT IMAGE BUILD until s57, which made
  the authored file inert — same defect and same fix as llama below. The vendored
  table stays as the record of where the MODEL_TABLE stanzas came from, and drift
  between it and the YAML is caught at a pin bump by `scripts/vllm-models.py`, a
  report that cannot write the YAML (no output path exists). The config carries no
  `port:` key, deliberately (2026-08-14): the launcher owns the
  listen port (`droste-serve.sh::serve::apply_port` appends `--port $PORT` from
  `vllm.cfg`'s `DROSTE_VLLM_PORT`), and setting it in both places made vLLM log
  `Found duplicate keys --port` at every start. `VLLM_NO_USAGE_STATS=1` is baked
  instead of persisting `~/.config/vllm` (do-not-track > carrying state). The
  `cache/vllm` bind IS present (owner decision 2026-07-09, resolving the old
  VERIFY-at-test note that had it omitted): `~/.cache/vllm` — vLLM's
  compile/artifact cache — joins the shared compute-cache store under the
  v0.2.0 cache policy. `/opt/fp8` is trimmed to the runtime import surface
  (top-level `*.py` + LICENSE/NOTICE + `licenses/` kept for compliance; bench/
  docs/serve scripts dropped).
- **llama** — `llama.cfg` is HAND-AUTHORED (`targets/llama/templates/`). It was
  BUILD-generated until s52; `llama-server --help` cannot run on a GPU-less
  runner, so that shipped a degraded file. Drift is now caught at a pin bump by
  `scripts/llama-options.sh` (run on the hardware), and the build still FAILS
  LOUDLY if `LLAMA_ARG_{HOST,PORT,MODEL}` vanish upstream — by scanning the
  binary for the literals, which needs no GPU.
  `LLAMA_ARG_PORT` is emitted COMMENTED, not active (2026-08-14, same rule as
  vllm's missing `port:` key): the launcher appends `--port $PORT` from
  `llama.cfg`'s own `DROSTE_LLAMA_PORT` and llama.cpp silently resolves the CLI
  flag over the env var, so an active line here would look authoritative and do
  nothing. It stays in the
  generator's `REQUIRED_VARS` drift gate regardless — that gate checks the
  PINNED BINARY's arg table, not what the template emits active.
  `LLAMA_CACHE` is deliberately UNSET — it is first in llama.cpp's
  cache-path resolution and setting it would re-separate the shared HF cache.
  Slot save/restore: the pinned fork ships `--slot-save-path` with NO env
  annotation (verified by the first CI run failing loudly, as designed), so
  the entrypoint launch line passes `--slot-save-path /opt/program-cache/slots`
  (user override = own flag in DROSTE_LLAMA_EXTRA_ARGS; later flags win); the dir is
  pre-created in PRE_LAUNCH. (The slots were on `/opt/data` until the
  2026-08-15 storage taxonomy moved them to the program-cache root.)
- **ds4** — ds4 has no native per-flag env vars, so PRE_LAUNCH translates
  `DROSTE_DS4_*` → argv (arity source-verified against pinned kyuz0/ds4
  `@00e64ea`); NATIVE `DS4_*` vars (DS4_THREADS, …) pass through untouched — the
  binary reads them itself. `DROSTE_DS4_PORT` and `DROSTE_DS4_HOST` sit in that
  translation table AND are two of the five SERVE settings, so both paths reach the
  argv: PRE_LAUNCH emits a flag from the ENVIRONMENT copy of the value, and
  `serve::apply_port` / `serve::apply_host` — which run after it — overwrite that
  flag with what `serve::read_config` PARSED out of `ds4.cfg`. The parsed value is
  the authoritative one; the translation is what makes the spec self-sufficient
  under other callers. (Until s60 the authority was a separate droste-owned
  `server.env` and this template carried only a comment pointing at it, per the
  2026-08-14 rule that kept an active port line out of every per-port config file.
  That rule ended with the second file: there is one surface now, so the setting
  is documented where the user already looks.) Backend shorthands
  (`--rocm`/`--cpu`/…) and the distributed/multi-node flags are left to
  `DROSTE_DS4_EXTRA_ARGS`. The whole `~/.ds4` (kvcache sessions + browser
  profile) is surfaced from `/opt/data/internal` — renamed from `/opt/data/ds4`
  in s47, because on this box the app's dot-dir name collides with the box's own
  and the host path read `~/droste/data/ds4/program/ds4` (or, pre-s41,
  `~/droste/data/ds4/ds4`, which looks like a directory made twice); the dest is
  the app's to dictate, the source name is ours
  (sessions are user WORK, top-level, not cache/); the cockpit conf is a FILE, so
  it persists via symlink `~/.ds4-cockpit.conf → /opt/data/cockpit/…`.
  `download_model.sh` was reworked cache-native (`hf download` into the shared HF
  cache, prints the snapshot path for `DROSTE_DS4_MODEL`); the upstream copy is
  REMOVED from `/usr/local/bin` — it downloaded via `--local-dir`, bypassing the
  cache on the project's biggest files (80–430 GB quants).

### 2026-07-09 — first hardware validation of the contract (Raiju, gfx1151, rootless podman)

The contract's mount mechanics had only been proven under `unshare -Urm` on
bifrost before this. Running the real images under rootless podman on real
hardware surfaced three findings and one decided design change.

- **Finding 1 (capability): the server lane REQUIRES `--cap-add sys_admin`.**
  Rootless podman strips `CAP_SYS_ADMIN` from the container's capability set,
  so EVERY in-container mount the entrypoint performs — overlays AND plain
  binds — fails with `mount: <path>: permission denied`. The bifrost proof
  missed this because namespace root under `unshare -Urm` implicitly holds
  SYS_ADMIN over its own mount namespace; podman deliberately strips it, so
  parity requires granting it back. The nuance worth recording: under ROOTLESS
  podman the grant is namespaced-only — container root maps to the invoking
  user's uid, so the cap confers nothing the user couldn't already do via
  `unshare -Urm`. Under ROOTFUL podman/docker it is real host SYS_ADMIN — a
  bigger ask, though still confined by the container's private mount
  namespace. The distrobox lane was unaffected at the time (the init hook
  mounted nothing) — superseded by the lane unification below.
  On EPERM the resolver fails FAST with a message naming `--cap-add
  sys_admin` — deliberately no fallback, because without mount capability the
  plain binds are just as broken as the overlays; there is nothing sane to
  fall back to.
- **Finding 2 (filesystem): overlay uppers constrain where `/opt/data` may
  live.** Kernel overlayfs requires the UPPERDIR filesystem to support
  O_TMPFILE + RENAME_WHITEOUT. Overlay uppers live inside `/opt/data`, so it
  must sit on ext4/btrfs/xfs/tmpfs-class storage; on ecryptfs (encrypted
  homes), NFS, or virtiofs the mount fails (`wrong fs type, bad option, bad
  superblock`; dmesg: `overlayfs: upper fs missing required features`). Plain
  binds (input/output, HF cache, workspace, `~/.ds4`) have NO filesystem
  requirement and can live anywhere, including encrypted homes.
- **Finding 3 (groups): rootless GPU access needs `--group-add keep-groups`.**
  Without it the invoking user's render/video group membership does not reach
  the container: `/dev/kfd` is present but inaccessible and torch dies with
  `RuntimeError: No HIP GPUs are available` — AFTER a fully-successful
  resolver/scanner startup, which makes it easy to misread as a ROCm problem.
  It's a flag problem.
- **Decided change (Jei, 2026-07-09): two-layer overlay fallback in the
  resolver** — kernel overlay → fuse-overlayfs → copy-mode, env knob
  `DROSTE_OVERLAY_MODE` = `auto|kernel|fuse|copy` (default `auto`).
  - fuse-overlayfs is the PRECEDENTED remedy: podman itself auto-falls-back to
    fuse-overlayfs for its own storage on exactly these filesystems — observed
    live on the validating host's ecryptfs storage (graphStatus: `Backing
    Filesystem: ecryptfs / Native Overlay Diff: false`). We mirror that: the
    binary is now baked in the runtime base and used automatically when kernel
    overlay rejects the upper fs; it needs `--device /dev/fuse` on the run.
    Cost is userspace I/O — slower ONLY on the overlaid paths (venv,
    custom_nodes); models and caches are plain binds, unaffected.
  - copy-mode is the LAST resort when fuse is unavailable too: copy the baked
    content to `/opt/data/copy/<name>` once and bind-mount it, with a LOUD
    warning — baked content is frozen at first-copy and disk is duplicated;
    deleting the copy dir forces a re-copy. That frozen-content tradeoff is
    exactly why s20 REJECTED copy-up as the primary mechanism; accepting it
    here is NOT a reversal — it sits behind two better options purely so a
    hostile filesystem degrades service instead of blocking it.
- **check-rocm.sh hardening:** the sweep now self-carries `--cap-add
  sys_admin` and a tmpfs `/opt/data` for its probes (tmpfs is always a valid
  overlay upper), so validation results are host-filesystem-agnostic.

### 2026-07-09 — lane unification (v0.2.0: distrobox gets the server lane's mounts)

> Amended 2026-08-14: the mount unification decided here STANDS unchanged, but
> the two-CONTAINER shape it assumes is gone — one container per box now
> carries both doors. See "2026-08-14 — one container, two doors" below.

The v0.1.0 "distrobox lane mounts nothing in-container" design is REVERSED.
Decision (Jei, 2026-07-09): the two lanes' mounts are now MOSTLY IDENTICAL —
the init hook runs the same resolver mounts as the server entrypoint, with
deviations allowed only where there is a real engineering reason ("there may
be necessary deviations — and that's ok"), justified case-by-case, never
assumed.

- **Provenance, recorded honestly:** the shipped no-overlay distrobox design
  was NOT an owner decision. It was a proposal of this project's AI assistant
  that got written into the design record with a false "Direction (Jei)"
  attribution, and shipped on that basis; when the record was challenged, Jei
  disowned it ("Yeah, I never said that"). Worse than the bad paper trail, the
  design contradicted the project's FOUNDING requirement: the project exists
  because Jei lost data to a distrobox wipe, yet under the shipped design
  in-box state (pip installs into `/opt/venv`, custom nodes) lived in the
  container layer and died on box recreation — recreating exactly that
  prior failure mode. This entry keeps the mistake on the record so neither
  the false attribution nor the requirement it violated gets papered over.
- **What unifies:** OVERLAYS (venv, comfyui custom_nodes — uppers on
  `/opt/data`; the kernel→fuse→copy fallback chain applies as-is), SURFACES
  (including comfyui's model-tree and `user/` — so M4's "the ini carries both
  lanes' binds" workaround dissolves and the comfyui ini drops its special
  model-tree/user `volume=` lines), and CACHES (the compute-cache binds land
  over `~/.cache/*` in-box instead of leaking into the real `$HOME`; their
  source is the shared `/opt/caches` volume — see the shared compute-cache
  entry below). Consequences: every `distrobox.ini` gains
  `additional_flags` with `--cap-add sys_admin` + `--device /dev/fuse`, and
  the `/opt/data` filesystem rule (plus its automatic fallback) now applies to
  the distrobox lane too.
- **Deliberate deviations** (the sanctioned class; each has a reason):
  - HF cache: NO bind in distrobox — the real home is auto-bound, so
    `~/.cache/huggingface` is natively persistent and the critical check
    passes as-is. (Dotfile/config state likewise stays `$HOME`-native — that
    is the lane's purpose.)
  - `/root/` remap: init_hooks run as root (`HOME=/root`), so destinations
    under `/root/` remap to the box user's home before mounting.
  - Ownership: dirs the hook creates (overlay uppers, cache dirs) are chowned
    to the box user — a root-run hook serving a non-root user.
  - Idempotent re-entry: hooks fire on every cold start, so every mount is
    skip-if-bound.
- **Migration:** boxes created from v0.1.0 inis do NOT pick this up in place —
  `distrobox rm` + `distrobox assemble create` is required.
- **Acceptance test** (the founding requirement, made executable): pip-install
  a package inside a box → destroy the box → recreate it → the change
  survived.
- **Poisoned upper (2026-08-14), the one failure mode this design can hand
  you:** a data dir written before the lanes merged holds a COMPLETE venv, not
  a delta — as the overlay upper it SHADOWS the baked stack, and the symptoms
  never name it (vLLM: a numpy metadata error; Jupyter: `/lab` 404s). Detected
  by the venv ROOT in the upper (`pyvenv.cfg` + `bin/python*`): warned at every
  box start (`resolve::_report_env_upper`) and offered as a wipe by the
  installer (`venv_upper_review` — a hand-kept mirror). Cure, with the box
  stopped: `rm -rf ~/droste/<box>/data/venv`; opt-out per box with
  `KEEP_OLD_VENV=1` in its `server.env` (silences the report, changes nothing
  about the mount). The warning text itself is the user-facing documentation;
  this bullet only records that it exists.
  **Superseded 2026-08-15 (storage taxonomy):** the venv upper lives on the
  per-box program-cache root now, so the trap is a stale CACHE the installer
  offers to clear BY LOCATION, and the hand-kept pair retired with it —
  `venv_upper_review`, `serve_env_keep_venv` and the `KEEP_OLD_VENV` key are
  all gone (a `KEEP_OLD_VENV=1` line left behind in an old `server.env` is
  simply ignored — and since s60 nothing reads that file at all: the serve
  settings moved onto the box's own `<box>.cfg` and `server.env` was deleted,
  its legacy `SERVE=` arm with it). What survives in the box is
  `resolve::_upper_is_env`, reduced to one ungated WARN when an overlay upper
  turns out to be a whole environment, and mirrored nowhere.

### 2026-07-09 — shared compute-cache volume (`/opt/caches`, folded into v0.2.0)

Decision (Jei, 2026-07-09): the compute caches (MIOpen / Triton / torch-hub)
move from per-box `/opt/data/cache` to ONE shared volume, bound at
`/opt/caches` in every container and box (host default `~/droste/compute-caches`
since the 2026-08-15 rename below, user-overridable — it was `~/droste/caches`
until then). Rationale, his: "easier to make the caches all shared,
generally". The resulting mount story is TWO shared stores plus one private
volume — models (the HF cache) and compute caches (`/opt/caches`) shared
across all five ports; `/opt/data` stays strictly box-private.

- **Conflict profile, per cache** (why sharing is safe, and the one place it
  is only mostly safe):
  - Triton: the JIT cache is content-addressed — concurrent boxes writing the
    same key write the same artifact. Conflict-free.
  - torch-hub: downloads are byte-identical per URL — last-writer-wins is
    harmless. Safe.
  - MIOpen: the single concurrency caveat. Its user tuning DB is a real
    shared database, not a content-addressed blob store — boxes tuning
    concurrently can contend on it (lock waits, redone tuning work; not
    corruption of results). Accepted as the price of warm-starting every box
    with every other box's tuning; revisit only if it bites in practice.
- **Degrade semantics:** unbound `/opt/caches` → graceful fallback to the old
  per-box `/opt/data/cache` with a one-time INFO. This store is OPTIONAL —
  never a critical, never an error (nothing in it is irreplaceable, only
  recomputable).
- **What deliberately stays per-box:** llama's slot store remains on
  `/opt/data` (`/opt/data/slots`) — slot save/restore is session STATE, not a
  recomputable compute cache; sharing it across boxes would be semantically
  wrong, not merely contended. Same for ds4's kv-disk (`/opt/data/kv-disk`);
  both moved out of the `cache/` pathname on 2026-07-09 precisely because they
  are state, not cache. Migration note: a v0.1.0 box's existing `slots`/
  `kv-disk` dir under the old `/opt/data/cache/` location is left orphaned
  (safe to delete); llama/ds4 re-create the new dirs on demand.
- **Credit where due:** the build-spec's SURFACES ≠ CACHES row split exists
  because Jei insisted on it. In the s22 design round the two rows were
  structurally identical binds and the engineering lean was to merge them;
  Jei kept them separate for "future cache magic". This is that magic: the
  shared-cache retarget lands as a CACHES-row semantics change — no SURFACES
  touch, no build-spec format change — because the seam was already there.
  His foresight, on the record as his.
- **Partly superseded 2026-08-15 (storage taxonomy):** the sharing rationale
  and the MIOpen caveat stand unchanged, but three paths in this entry moved.
  The unbound fallback is the box's own `/opt/program-cache/compute/`, not
  `/opt/data/cache`; llama's slots and ds4's kv-disk went with it to
  `/opt/program-cache` — still per-box and still never shared, but cache CLASS
  by location, which is the whole point of that round; and the mount story is
  now two shared stores plus TWO per-box roots.

### 2026-08-14 — one container, two doors (the compose lane is retired)

The TWO-ARTIFACT shape is gone. Until this date every box shipped a server-lane
compose file (`<box>-halo-srv.cmp.yaml` — podman compose, root entrypoint,
published ports) AND a distrobox ini (`<box>-halo-dbox.ini`): two containers,
two records, one shared data dir. After the lane unification above they ran the
SAME mounts, so the second container bought nothing and cost plenty — two
definitions to keep in sync, two things to recreate, and one overlay upper
written by both uid regimes (the `_own_dirs` reclaim above is that scar).

What ships instead: ONE container per box, named `droste-<box>-halo`, created
by `distrobox assemble` from ONE record, `<box>-halo.ini`, with two doors.

- **Serve door** — `podman start droste-<box>-halo` replays the ini's
  `init_hooks` line; the hook ends in `serve::maybe_launch`, which reads
  `<data dir>/<box>.cfg` and launches the build-spec's SERVICE as the box
  user on the recorded `PORT` and `HOST`. It is deliberately `|| true`: a serve
  problem must never fail the hook, because distrobox reports a failed hook as a
  generic error and the box would become hard to ENTER — the opposite of what
  you want when the service is the broken part.
- **Enter door** — `distrobox enter droste-<box>-halo`. Same container, so the
  environment a user pip-installs into is the one the service runs. Entering a
  stopped box starts it, which opens the serve door with it when
  `DROSTE_<APP>_STARTUP_ENABLED=yes`.
- **The box's own `<box>.cfg` is the single authority** for all five serve settings
  (`DROSTE_<APP>_{STARTUP_ENABLED,HOST,PORT,TLS_CERT,TLS_KEY}`). It lives on
  the per-box data volume, so it survives image updates and box recreation,
  and it is re-read at EVERY start (edit + `podman restart`, no recreate).
  That authority is why the NATIVE port spellings stay inert wherever else they
  could reach the server: `serve::apply_port` puts our value on the COMMAND LINE,
  and a CLI flag outranks a YAML key and an environment variable, so an active
  native line would look authoritative and do nothing. See the vllm (`port:` key)
  and llama (`LLAMA_ARG_PORT`) notes above, both dated 2026-08-14 for this reason.
  **Superseded s60:** the authority was `server.env`, a
  droste-owned SECOND file on the same volume holding only STARTUP_ENABLED and
  PORT. It was deleted — a user should not have to learn that the port lives
  somewhere other than every other setting the box has — and its two settings
  moved onto the surface that already existed, joined by HOST and the TLS pair.
  `STARTUP_ENABLED` reads `{yes, no}` there, the vocabulary of the menu it sits
  under; the legacy `SERVE=1` spelling went with the file.
- **Ports are BOUND, not published.** distrobox containers use HOST
  networking, so there is no `HOST:CONTAINER` remap to make: `PORT` is the
  host port. ds4's installer default is nudged to 8001 because vllm owns 8000.
  (Host networking is also why the healthcheck has to prove OWNERSHIP of the
  port — see the `droste-healthcheck.sh` bullet in the runtime contract.)
- **Supervision is wired at CREATE time**, into the ini's `additional_flags`:
  `--health-cmd` + `--health-interval` + `--health-retries` +
  `--health-start-period` (per box, generous — it must cover a multi-GB model
  load) + `--health-on-failure=restart`, plus `--stop-timeout`. The images
  bake no `HEALTHCHECK` of their own, so those flags are the whole contract;
  droste-setup.sh emits them unconditionally, interactive-only boxes included,
  because the probe answers HEALTHY for a box that is not configured to serve.
- **Host boot is a systemd USER unit** per box (`droste-<box>.service`,
  oneshot `podman start` + `RemainAfterExit`) plus `loginctl enable-linger` —
  not a podman restart policy. Lingering is load-bearing twice over: without
  it the user manager exits at logout and takes both the unit AND podman's
  healthcheck timers with it.

The server-lane ENTRYPOINT is NOT removed: `podman run <image>` behaves exactly
as the runtime contract describes, and `check-rocm.sh` drives it. It simply is
not something the installer creates any more, so "server lane" now means "the
image run directly", never "the box's other container".

Migration: a pre-merge install's `-srv.cmp.yaml` / `-dbox.ini` pair and the
containers made from them are superseded, and the installer neither reads nor
removes them — it looks only for `<box>-halo.ini`. Re-running droste-setup.sh
writes the single ini, merges the port and startup answers it just asked for into
the box's `<box>.cfg` (`cfg_set`, one line at a time — every other byte of that
file is the user's and comes out as it went in), and reuses the data dir as-is;
delete the old files and containers by hand. The one data-dir hazard is the
pre-merge venv upper — see the poisoned-upper bullet in the lane-unification
entry above.

### 2026-08-15 — storage taxonomy (three roots, classification by LOCATION)

ONE per-box volume was doing two jobs. `/opt/data` held both the things a user
would mourn (configs, the model tree, custom nodes, saved sessions, the
finetuning workspace) and the things a box rebuilds without being asked (the
venv upper, slots, KV disk, scratch), so anything that wanted to clear the
second had to GUESS which was which from a path's CONTENTS — the s36 heuristic,
and that guess is what lost here. The split makes the mount point the class:
what a thing IS decides where it lives, and no consumer has to infer it again.

Three roots, container-side (host defaults in parentheses):

- **`/opt/data`** (`~/droste/data/<box>/program`) — per-box PERSISTENT. Configs
  (the box's `<box>.cfg`, plus vllm's `vllm_config.yaml` and finetuning's
  `jupyter_server_config.py`), comfyui `user/` + the
  custom_nodes upper + the model tree, ds4 `sessions/` + `cockpit/`, the
  finetuning workspace, the `.droste-*.log` files.
- **`/opt/program-cache`** (`~/droste/caches/<box>`) — per-box PROGRAM CACHE,
  re-obtainable by construction: the venv upper and its `.work`, copy-mode
  materializations, `tmp`, llama's slots, ds4's kv-disk, comfyui's seeded
  `extra_model_paths.yaml`, the `state/` server state dir, and the
  per-box compute-cache fallback under `compute/`. The installer may empty this
  ROOT WHOLE on consent, so nothing a user would miss may ever be put here.
- **`/opt/caches`** (`~/droste/compute-caches`) — the shared compute caches,
  unchanged in role and renamed on the HOST side only: the old shared default
  `~/droste/caches` is now the per-box program-cache PARENT, and leaving both
  meanings on one path would have been unreadable.

Resolver contract delta (`base/resolve/droste-resolve.sh`):

- `DROSTE_PCACHE_DIR` (default `/opt/program-cache`) joins `DROSTE_DATA_DIR`
  and `DROSTE_CACHES_DIR` under the same override discipline, and
  `ensure_pcache` mirrors `ensure_data` — but WARNs only, never fatal, because
  nothing on the root is irreplaceable (`resolve::critical` is for the paths
  that are). There is deliberately NO `VOLUME /opt/program-cache` in any
  Containerfile, same stance as `/opt/caches`: an anonymous volume would
  silently hoard multi-GB venv uppers under a name nobody goes looking for.
  The bind in the emitted ini is therefore the ONLY thing keeping in-box
  installs off the container's writable layer.
- The shared-cache src rewrite now keys on the prefix
  `$DROSTE_PCACHE_DIR/compute/` (it was `$DROSTE_DATA_DIR/cache/`): a CACHES
  row under `compute/` re-sources from `$DROSTE_CACHES_DIR` when that volume is
  bound, and everything else on the program-cache root — slots, kv-disk, tmp,
  the venv upper — is cache CLASS but never SHARED (one box's KV state means
  nothing to another) and never rewrites. The `compute/` prefix is load-bearing
  and the build-specs say so at the CACHES row.
- **The work dir is always a sibling of its own upper**, which is why `.work`
  follows the upper's root rather than the class table's "all `.work` is cache"
  line: the venv's lands on the program-cache root, comfyui's `custom_nodes`
  `.work` stays on data. Kernel constraint (workdir and upperdir must be on the
  same filesystem), not a taste call — the two roots may well be different
  filesystems, which is the whole point of asking for them separately (the
  installer mock sends one box's caches to `/fast/caches/llama`).
- The overlay-hostile-fs probe follows BOTH roots — the venv upper moved, the
  custom_nodes upper did not — and either one objecting settles ONE
  `DROSTE_OVERLAY_MODE` for the box: a per-root mode would be two answers to a
  question the user was asked once.
- The whole-environment-upper machinery is gone but for one survivor:
  `resolve::_upper_is_env` is now a single ungated WARN fired BEFORE the mount
  is attempted, so it speaks in every overlay mode — copy included, where the
  old report deliberately stayed silent because it fired only at the
  kernel/fuse SUCCESS sites — and it is mirrored NOWHERE. See the supersession
  note in the poisoned-upper bullet above for the KEEP_OLD_VENV retirement it
  replaces.
- Installer side, for the record: the per-box program-cache clear (offered once
  install-wide, then per box for whatever a global "no" left) is now the ONLY
  deletion droste-setup.sh can perform, and it never reaches outside a box's
  program-cache dir. (**Amended 2026-08-20:** the move work below adds two more —
  the vacated cache dir after a re-point, and the `remove data at new path` answer
  to a collision. Both are consent-gated and name the directory first.)

Migration: NONE, deliberately. The old paths — `~/droste/<box>/data`,
`~/droste/finetuning/workspace` and the old shared `~/droste/caches` — are
simply no longer read; NOTES.md and the README name them as safe to move or
delete by hand. `parse_existing_ini` TOLERATES the old ini shape (it seeds the
data path and hands the box a factory program-cache path), so a modify run is
not a re-typing exercise. The one sharp edge is the compute-cache prompt, whose
default seeds from the old ini's `/opt/caches` host path — which under the new
names is the program-cache ROOT, and wants re-pointing at `compute-caches`.

### 2026-08-17 — the spelling the user typed (and the ini's two path lines)

`expand_path` did two jobs in one breath: it made a path absolute and it
expanded `~` to `$HOME`. The second destroyed information. A path typed at a
prompt or read back from an ini was stored expanded, so the installer could
only ever show a path it had reconstructed, never the one its owner wrote —
and `home_disp` then re-abbreviated that to `~`, which on a host whose home is
reached by an unusual name displayed a spelling appearing nowhere in the user's
files. The rule this round settles on (Jei): what the user types is ALWAYS what
the program shows.

- **The split.** `abs_path` absolutizes and is what STORAGE uses; `fs_path`
  resolves, at the filesystem boundary and nowhere else — every mkdir, test,
  glob, redirect and `volume=` source goes through it, and its result is never
  stored, compared or printed. A relative answer is still made absolute against
  `$HOME`, at input, because it is unresolvable later without a cwd the
  installer refuses to guess; after that the absolute form IS what the user
  typed. `~/foo` and `/srv/foo` are both resolvable as they stand, so both
  survive verbatim. `home_disp` is deleted — nothing compresses `$HOME` to `~`
  any more, and the factory defaults are literal `~` strings (`~/droste`,
  `~/.cache/huggingface`) that disappear the moment the user types over them.
- **A `~` is late binding**, so the spelling has to survive the FILE, not just
  the session. `volume=` keeps resolved absolutes because that is what
  distrobox and podman act on: podman 5.4.2 binds a source only when it starts
  with `/` or `./`, anything else silently becomes a NAMED VOLUME of that name,
  and distrobox 2.x expands nothing of its own (1.x expanded only as a side
  effect of `eval`-ing the assembled command). The authored spelling is
  therefore recorded beside it — same `<src>:<dest>` shape, in a
  `# droste-setup: spelled="…"` comment — so the two lines read against each
  other by destination.
- **Precedence, ruled: `volume=` WINS.** It is authoritative for the value,
  always; the comment only ever contributes a spelling, and only while it still
  names the same directory (`same_dir`, so an aliased or symlinked home still
  matches). When they disagree the comment is describing some other directory —
  a hand-edited `volume=`, most likely — and the `volume=` string is taken
  verbatim. Every write re-resolves from the spelling rather than copying the
  previous expansion forward, so a home that moves is followed at the next write
  or create (podman bakes the source absolutely at create time, so a run is the
  only moment a `~` can be re-read).
- **Machine decisions are spelling-independent.** Comparisons that were string
  `==` are physical (`same_dir`) now: the program-cache wipe guard would not
  have matched a HuggingFace cache recorded absolute against one spelled with a
  `~`, and would have emptied it.
- **A defect in generated advice, fixed.** An ini with no `/opt/models` bind
  used to tell the reader to append `~/models:/opt/models:ro` to the `volume=`
  value — which under the podman rule above is a named volume literally called
  `~/models`, not a bind. It prints an absolute path now.
- **Where the reader meets it.** The emitted ini explains the record line in
  place (it is the one machine-looking comment in a file users are invited to
  edit), NOTES.md gained an "Editing a box ini by hand" section, and the README
  states the storage rule in the installer section.

Migration: NONE. An ini written before this carries no `spelled=` line, so its
`volume=` string is taken verbatim and the next write adds the record.

---

### 2026-08-20 — moving the data when the answer moves (and why `mv` is the whole design)

Answering yes to "store persistent data at a common base path" re-pointed every
box's ini at `<base>/<box>` and left the bytes where they were: the box came up
bound to an empty directory, and nothing said so. That the answer beats the
recorded path is the earlier F8 fix and is correct — this is the other half,
what happens to the files once it does. Jei: *"Don't do what is being done and
(somehow) ignore what the user says."*

- **The mover is `mv` itself, and its behaviour and its errors are ours.** Jei:
  *"mv copies across boundaries and removes the old. We should do the same,
  unless we know in advance that it will fail."* coreutils already does
  `rename(2)`, falls back to copy+unlink on `EXDEV`, preserves mode and
  timestamps, and leaves the source intact when a copy dies partway; a
  hand-rolled copy-verify-delete would be a second, worse implementation of a
  tool the user already knows. Refusals are printed in mv's own words rather
  than paraphrased.
- **`-T` is mandatory.** Plain `mv src dst` onto an existing directory moves src
  *inside* it, so the whole feature would silently produce `<base>/<box>/<box>`
  — a layout that then reads as the user's own mistake.
- **What "merge" can mean, measured (coreutils 9.7).** `mv -T` onto a NON-EMPTY
  directory is refused, same-device (`cannot overwrite 'x': Directory not
  empty`) and cross-device (`inter-device move failed: …; unable to remove
  target: …`) alike; onto an EMPTY one it succeeds. So merge is per-entry
  `mv -T`: a file landing on a file is replaced silently, and a directory
  landing on a non-empty directory is reported and left where it is. Recursing
  into that collision and unioning it is a thing mv will not do, and for the
  files inside it is indistinguishable from "replace". A merge that empties its
  source `rmdir`s it, because that is the step mv would have taken.
- **Two questions, not one, and the second one is the way out.** Jei's shape:
  `Move <bind> to new path (<new>) [Y/n]?` — defaulting to YES, because it only
  ever appears after the user has said where the family should live, so it
  confirms a consequence of an answer already given — and then, only when a
  destination has something in it, `There are existing files at new …` with four
  courses of action: **M**erge existing, active data into new path (replace when
  overlapping) · **r**emove data at new path, then move · **u**se the data
  already at the new path (stop using existing data) · **k**eep old path as-is.
  The last two move nothing and differ only in where the BOX ends up pointing,
  which is what makes them the answer to a disclosure the reader could not have
  seen when answering question one. An earlier "back the old one up as
  `<name>.backup`" option was cut here, and with it the `.backup.1`/`.2` rule.
- **Both questions batch, at two levels.** After the first answer:
  `Do this for all data paths for <box>?` — carrying THAT answer, yes or no
  alike — and then, only if that was taken, `Do this for all boxes?`. Decline the
  box-wide one and each remaining path is asked in turn. The collision decision
  has its own pair (`Apply this decision to all overlapping new <box> paths?` /
  `… to all boxes?`). A box with a single data path is not asked the box-wide
  question at all — a set of one has nothing to apply to — and goes straight to
  the all-boxes offer.
- **One pass per box, after every path of that box is settled.** Not one
  question per bind as they are asked: when a base places the family the paths
  are known before anything is asked, but when the base is DECLINED the new
  paths ARE the answers to the per-box prompts, so the moves cannot be discussed
  until those prompts are done. The pass opens by disclosing where the files are
  now — `Current data file paths in <dir>:` with bind names when they share one
  directory, one full path per line when they do not.
- **Everything destructive is disclosed first.** A non-empty destination is
  named with WHAT IS IN IT — the bind names, or one full path per line when they
  do not share a directory — *and* with whether it is where that same box keeps
  its other binds — which it usually is on the shape that produced this bug
  (comfyui's data dir lands on the directory holding its own input and output),
  and which decides what these four answers mean in practice. The destination
  may belong to ANOTHER box; that is asked about, not vetoed (Jei: *"that's the
  user's call"*), and the disclosure is the guard.
- **Order matters where it costs data.** The device/space check sits AFTER the
  four-way choice (two of those answers move nothing and would not have cared)
  and BEFORE the `rm -rf` that `remove` performs, so a shortfall can never be
  discovered once the old content is already gone. `remove` also gets credited
  with the space it is about to free, or it would decline a move that fits.
- **Refusals say why.** A cross-device move is priced before it is offered (size
  of the source, free space at the destination) so a shortfall is stated up
  front instead of discovered half a copy later — *"a reported shortfall is the
  difference between 'left my data alone' and 'ignored me'"*. A running box is
  refused with the reason, the same shape as the program-cache wipe.
- **s42: the two questions are independent, and only one of them needs a
  record.** "Your data is at X, the box will read from Y — move it?" needs
  something recorded to move. "There are files where the box will now read"
  needs only a destination, so it applies to a **first install** as much as to a
  modify. Both used to live behind one `ACTION == modify` gate, and the
  collision walk was scoped to accepted moves — so a fresh create silently
  adopted a directory full of somebody's models, a recreate silently orphaned a
  box's data at its old path, and declining a move skipped the destination check
  entirely. **Declining a move therefore no longer means "keep the old path"
  unconditionally**: an empty destination keeps it, a destination with content
  earns the shorter `[U]se` / `[c]hange` question.
- **s42: fresh, recreate and modify ask the same questions on the same path.**
  The only thing that differs is where a prompt's DEFAULT comes from — a
  recreate follows the fresh-create defaults, a modify follows what was recorded
  and falls back to fresh. One function keeps that distinction; nothing else
  gates on the run type.
- **s42: the block is drawn if and only if a prompt will follow it.** The
  collision menu used to be printed unconditionally while the "already answered,
  carry it" short-circuits sat in the loop below, so a box carried by the batch
  got the whole four-option menu with no prompt, no selector line and no echoed
  answer — in colour indistinguishable from a live menu, default highlight and
  all. Writing the rule as a property rather than patching the reported case
  also closed the same hole in the shorter form, where a box-wide answer settled
  in an earlier round was missed. A carried box now gets a receipt naming what
  was decided, which is what the move question already did.
- **s43: what that receipt says.** One line per bind, naming the decision and
  the path it came from — `Merging current <leaf> path [<old>] into new path.`,
  `Replacing new path with current <leaf> path [<old>].`, `Using data at new
  path for <leaf>; leaving old path as-is.`, `Continuing to use current <leaf>
  path [<old>] as-is.` No box name (the box banner is a few lines up), no new
  path (the summary block prints it just below), and no separate "will be moved
  to" line — each sentence names the old path itself, and for *use* and *keep* a
  move line would be false. `use` is the one decision the move pass also reports
  on, so its clause stays generic and that report does the naming; the asymmetry
  with the other three is deliberate. The shorter form's receipt is the same
  sentence without the trailing clause, because nothing is moving onto that
  destination and a fresh install has no old path to leave behind.
- **s42: `[c]hange` re-enters the ordinary path route.** It is not a bespoke
  re-ask: the answer goes through the same settle-and-check the box takes when a
  family base was declined, so a newly typed path that also holds data asks
  again. Changing the program-data path re-derives its siblings, which are then
  re-checked too. Moves are deferred until every round is done — a move executed
  in an early round could be aimed at a destination a later one walks away from.
  The batching questions are suppressed after a change, because "apply this
  decision to all boxes" has no meaning for a decision that needs a different
  answer per box.
- **Program caches are exempt.** They regenerate, so they are re-pointed in
  silence; the only question is whether to delete the vacated directory, and
  that reuses the s38 consent-gated clear (same safety test, same running-box
  refusal). The HF cache is NOT one of these — Jei excluded it explicitly
  (*"I'm not counting huggingface here"*): it is the model store, and it takes
  the ordinary move offer.
- **The box is pointed where its data actually is.** Refused, failed outright,
  or a merge in which nothing moved: the box keeps its recorded path. A partial
  merge takes the new path — what moved is there — and names the directory the
  rest is still in. ⚠️ **s42 refined the "declined" case, and the principle is
  what forced it:** declining the move leaves the files at the old path, so the
  box keeps that path — UNLESS the new location has files of its own, in which
  case the user is asked which set the box should use, and answering `[U]se`
  points it at the new path. The box still follows the data; there is simply
  more than one set of it to follow.

Same round, and part of the same defect: a family with no common base used to
offer a FACTORY example at the base prompt while the inis knew perfectly well
where the data lived, and the note explaining why the family would be asked per
box printed a single well-formed path as its evidence. The prompt now offers the
base most of the recorded paths agree on (Jei: the default has to match the
file), and the note names both sides of the disagreement.

Same round: **the nesting was an oversight** (Jei), so the box's data dir is no
longer the parent of its siblings. `program` — short for "program data", which
is what its prompt has always called it — joins `input`, `output` and
`workspace` as a leaf under a per-box directory that is not itself a bind:

    <data base>/<box>/program   → /opt/data
    <data base>/<box>/input     → /opt/ComfyUI/input
    <data base>/<box>/output    → /opt/ComfyUI/output

Host side only; no container path moves. **Read tolerantly, write strictly:** a
data path recorded as `<base>/<box>` is the older shape and still names a base,
because reporting "these do not share a common base" about paths that plainly do
would be a lie about the user's own file. Nothing rewrites it. A box in the old
shape derives `<base>/<box>/program`, which is INSIDE its recorded path, and mv
refuses to move a directory into its own subdirectory — so it is reported and
left alone rather than asked about, since the only answer such a question could
earn is an error. Migrating one means moving the contents of `<box>` into
`<box>/program` while stepping around its other binds; Jei ruled that out of
scope ("I can manually fix my boxes").

Also this round, and visible before any of the above: **Storage Paths became
three blocks** — the two elections (persistent data first, then program caches),
then `Host Data Paths` (the data base, the model share, the HF cache) and `Host
Cache Paths` (the cache base, the compute caches, the stale-cache offer). The
old single run of prompts put the model share between two caches and left each
base prompt three questions away from the election that decided it.

Migration: NONE, and nothing moves that was not asked about by name.

---

## The installer is ASSEMBLED — `installer/` + `scripts/assemble-droste-setup.sh`

🚨 **`droste-setup.sh` IS A BUILD PRODUCT. DO NOT EDIT IT.** Its sources are
`installer/*.sh` (fourteen fragments) plus `installer/py/*.py` (the two programs
the image pull runs), and `scripts/assemble-droste-setup.sh` concatenates them in
the order `installer/MANIFEST` gives. Hand-edit the artifact and `lint-shell.yml`
goes red on the next push, telling you so — but the edit is still lost the first
time anyone regenerates.

**Why it exists at all.** The file is what a stranger pipes into bash, so it has
to stay ONE self-contained script with no checkout behind it. Being one file is a
distribution requirement; being one *source* file was only ever a consequence, and
at 6.7k lines it had become the reason nothing about it was navigable. Assembly
keeps the shipped shape and gives the sources a structure.

**The assembler is deliberately boring — a `cat` with guards.** No `#include`
resolution, no dependency graph, no conditional inclusion, no per-fragment
banners, no synthesized shebang (it is the first line of the first fragment). A
build step clever enough to transform things is a build step clever enough to be
wrong, and the whole correctness argument rests on `cat` of the parts BEING the
whole:

    scripts/assemble-droste-setup.sh | cmp - droste-setup.sh

⭐ **That is the acceptance test, and it admits no partial credit.** While both
shapes are tracked, CI asserts it on every push.

**STDOUT is the product.** Nothing lands anywhere unless the caller redirects —
CI does `> droste-setup.sh`, the g1lab suites redirect into their own `mktemp -d`,
and `--ref <branch|tag|sha> | bash` runs a ref without writing a file at all. The
interview still works down a pipe because the prompt layer opens the terminal on
its own fd rather than reading answers from stdin.

**The assembler is SILENT ON SUCCESS** — no progress, no summary, nothing. That
makes *"anything on stderr means something went wrong"* true by construction
instead of by convention, and testable in one line
(`assemble 2>&1 >/dev/null` must be empty). There is deliberately no `--verbose`
and no `--quiet`: a verbosity knob reintroduces exactly the bug class the silence
eliminates, and the failure it prevents — a stray `echo` corrupting the artifact —
would otherwise surface at a user's terminal.

**It BUFFERS.** A pipe means a half-finished assembly has already fed a truncated
script to bash, so the whole artifact is built and checked before a byte reaches
stdout. Defence in depth: the artifact's last line is a bare `main`, so a
truncated stream would define functions and call nothing.

### The Python is its own file, and that was not tidiness

`installer/py/pull_manifest.py` and `installer/py/pull_progress.py` are real `.py`
files; the assembler re-embeds them into the same `<<'PY'` heredocs the artifact
has always carried, so the shipped bytes are unchanged. Two things this buys:

1. **The Python is CHECKABLE.** Inside a heredoc it was a string as far as every
   tool was concerned — a syntax error shipped and surfaced as a failed image pull
   on a user's machine. `python3 -m py_compile` now runs in CI.
2. ⭐ **It killed a split hazard outright.** A `# ── ` section divider lived
   *inside* the progress program's heredoc and read as a bash section boundary;
   splitting there would have cut the heredoc in half. It is now a Python comment
   in a Python file, which is what it always was.

Two assembler requirements, **both silent failures if missed**, both guarded:

- **the heredoc stays QUOTED (`<<'PY'`)** — the progress program receives a
  registry-supplied label, and an unquoted heredoc would expand `$`-bearing
  content at assembly time;
- **a fragment is refused if the embedded file contains a line equal to the
  terminator** — a lone `PY` truncates the program, and the result still parses as
  bash and still runs, so the pull breaks pointing nowhere near the cause.

### The closed lists, in both directions

Every guard here is the `emitguard` idiom — a list checked from both ends,
because the failure that matters is silent: an unlisted fragment does not error,
it **vanishes**, and the artifact still builds and still runs, missing whatever
that file defined. So: every manifest entry exists on disk **and** every
`installer/*.sh` is in the manifest; every `installer/py/*.py` is embedded by some
fragment **and** every embed names a file that exists; nothing is listed or
embedded twice; the buffer passes `bash -n`; the last line is exactly `main`.

### The UI layer, and why the split has a checker

One fragment boundary rests on a MEASUREMENT rather than on taste. `ui.sh` is the
display/prompt layer — measured at 157 inbound edges and **zero** outbound — and
Jei's ask is that the drawing stay clean enough to lift into another project. The
three properties that make that possible (it names no global of ours, calls
nothing defined below it, and its display half never calls its prompt half) were
all true before anyone stated them, and all three would die quietly to one
reasonable-looking edit. `scripts/check-installer-layering.sh` derives the
forbidden set from the file on every run rather than carrying a list, and CI runs
it against the **assembled** artifact. `contract.sh` holds the two values the
layer is told about us (`UI_PROG`, `UI_INPUT_VAR`), so the kit itself names
nothing droste-specific.

⚠️ **Never cite a line number in `droste-setup.sh`.** It is generated output —
a citation into it is a claim about a build product that regenerates on every
change. Cite the fragment and an anchor within it.

## Host adopt tooling — scripts/droste-hf-adopt.sh / scripts/droste-civitai-adopt.sh

The two adopt tools move already-downloaded model files into the shared stores
the containers mount — the HF hub cache, and a webui-style CivitAI tree suited
to the `/opt/models` bind. Both are host-side, stdlib-only, dry-run by default.
Both live at `targets/comfyui/scripts/`, beside `model_scanner.py` and the
`model_formats.py` execution-free readers all three share, and ride into the
comfyui image with them; the two files under `scripts/` are forwarding stubs
that keep the documented host invocation working. The design rationale:

### 2026-08-23 — one set of key-signature rules (and the uv migration finishes)

Two tools in this repo read tensor names to decide what a weight file is:
`model_scanner.py`, which answers in ComfyUI loader directories, and
`droste-civitai-adopt.py`, which answers in the A1111 layout CivitAI's ecosystem
assumes. They shared the knowledge and not the code, and the copies had drifted
in both directions — the adopt tool had seven upscaler-architecture rules the
scanner lacked entirely, the scanner had DiT-era ControlNet spellings and the
whole pickle-module signal set the adopt tool lacked.

- **The rules live in `model_formats.py` now, once, behind an internal
  vocabulary.** Neither tool's directory names are the domain model: a file in
  the wrong ComfyUI directory is not found by any loader, and CivitAI's layout is
  not ours to redefine. So the shared rules answer in `KIND_*` and each tool
  keeps only its edge mapping. **The trees are renderings; the kind is the domain
  model.** Same argument that put the restricted unpickler there, and there is a
  test that greps for a re-fork of either.
- **Matching is anchored; architecture fingerprints are the exception, and the
  exception is what explains the drift.** A ROLE announces itself at the root of
  a state dict (`control_model.`, `first_stage_model.`), so anchoring costs
  nothing and stops `enc.` matching `encoder.`. An ARCHITECTURE is a component
  name inside the module tree — `relative_position_bias_table` lives at
  `layers.0.residual_group.blocks.0.attn.…` — so anchoring it would delete the
  rule. The scanner mostly asked "what role does this play"; the adopt tool
  mostly asked "which architecture is this upscaler". Neither matching style was
  wrong, and nobody had written down that they answer different questions.
- **`KIND_TO_TYPE` stays a whitelist.** The shared classifier answers for far
  more kinds than the adopt tool routes on, and the API knows things tensor names
  cannot: LoRA versus LyCORIS versus DoRA is not distinguishable from keys today,
  yet three directories are fed by the API's word for it. Content asserts the
  family, the API asserts the sub-type, and an uncertain architecture abstains
  rather than returning a weak kind — the adopt tool stamps whatever it receives
  as absolute for routing.
- **Heuristics 13, and what it buys.** Upscaler architectures (ScuNET, SwinIR,
  HAT, DAT, ESRGAN, RealESRGAN) and T2I adapters classify by content in the
  scanner now. Before this, an ESRGAN whose filename carried no `esrgan` or `4x`
  token got no content vote at all and ended unclassified. The bump
  re-classifies every registry in the field on next sync; the renames ledger
  survives it.
- **A legacy torch checkpoint was being read as empty, and the emptiness
  recorded as a fact.** The shared reader's `max_objects` defaults to 1 and both
  of its legacy behaviours are gated on it being greater than 1, so the adopt
  tool harvested torch's magic number, found no keys, and wrote
  `tensor_count: 0` at confidence absolute about a file it had never read — along
  with losing every routing signal the file carried.
- **`double_blocks.` did not mean FLUX.** It was carried as an absolute
  base-model signature and HunyuanVideo has 480 of those keys, so a correct
  baseModel was being rewritten. They are the same DiT family, so the blocks
  cannot separate them; the text pathway does — FLUX projects text once
  (`txt_in.weight`/`txt_in.bias`), HunyuanVideo refines it through
  `txt_in.individual_token_refiner.`. Both files were read over HTTP range
  requests rather than argued about, which is how key-signature questions get
  settled here.

**The uv migration finished in the same batch.** Every "no uv equivalent" reason
recorded a day earlier was wrong: wheel building is `uv build --wheel` (a
different verb), `--reinstall-package` is narrower than pip's
`--force-reinstall`, uv resolves the vLLM graph in seconds where pip
RecursionErrors on it (so `PIP_USE_DEPRECATED=legacy-resolver` is deleted), and
`--prefer-binary` turned out to be inert — uv's default resolves that media batch
to the identical 22 packages. Exactly one pip install line remains, the venv
bootstrap, which is the line that installs uv. The `pip check` gate stays on pip
deliberately: its allowlist matches pip's exact output wording.
⚠️ Dropping `--prefer-binary` leaves one exposure worth naming. If an upstream in
that batch ever ships a version as an sdist only, pip would fall back to an older
wheel and uv's default will build it: green, but slow. The tell is a comfyui job
whose duration jumps for no other reason.

### The hash-proof adoption gate
- Content enters a shared store ONLY on cryptographic proof, NEVER on
  filename similarity — a shared cache poisoned by a name-guessed adoption
  poisons every consumer at once. scripts/droste-hf-adopt.sh matches the file's digest
  against the repo manifest from the HF API (`?blobs=true`, metadata only:
  the LFS content sha256 — the live API spells it `lfs.sha256`, older
  payloads `lfs.oid`, both accepted — for LFS files, git blob sha1
  (`blobId`) for small ones; one streamed pass computes both). scripts/droste-civitai-adopt.sh matches sha256 via the
  CivitAI batch by-hash API (one round trip per directory).
- IDENTIFICATION is exactly as strict as a claimed identity. Without
  `--repo` (HF) four signals, tried in priority order, only PROPOSE candidate
  repos — a sibling transformers `config.json` carrying an absolute
  `_name_or_path`, the curated `ECOSYSTEM_MAP` of ubiquitous ComfyUI aux-model
  filenames a name search cannot find, provenance embedded in a GGUF header,
  and finally the HF model-search API fed terms derived from the filename — and
  the published hashes decide; a CivitAI `--version-id` (the escape hatch for
  old uploads CivitAI never hashed) is accepted only if our sha256 appears in
  that version's file list. Refused files are not failures to fix by hand-placing
  them in the cache — their home is the `/opt/models` bind.
- Never partial, never destructive: placements stage as `.tmp-*` and rename
  into place; existing content is never overwritten (identical content =
  ALREADY, different content = refused); `--move` deletes the source only
  after successful placement. Hardlink is the default placement (free when
  cache and download share a filesystem; falls back to copy across).

### The three-file sidecar scheme + the 4-outcome field policy
- Each adopted CivitAI model gets up to three sidecars; the namespace suffix
  sits LAST so the terminal extension is the unique `.droste`:
  `.civitai.info` (the live CivitAI API response — shareable, tool-owned,
  regenerated), `.meta.droste` (our objective block: sha256, normalized
  name, IDs, api/resolved type, routing, sniff verdicts, fine `sub_type`),
  and `.user.droste` (user curation — written only when non-empty, and
  MONOTONIC: sync never drops preserved data).
- Pre-existing source sidecars next to the download (a1111 `.json`, ComfyUI
  `.metadata.json`, Stability Matrix `.cm-info.json`) are mined field by
  field under a 4-outcome policy: user curation → `.user.droste` (tags and
  trigger words kept as the user-distinct DELTA vs CivitAI's own
  trainedWords/tags); model metadata with no CivitAI home (e.g. a fine
  functional subtype like text_encoder/bbox) → `.meta.droste`; metadata that
  COMPLETES a blank/missing CivitAI field → enriches `.civitai.info` (blank
  scalars filled, local preview URLs unioned into `images[]`); tool-internal
  or redundant state → dropped. A single `extensions.droste.enriched` marker
  records exactly what was completed — and is ABSENT when nothing was, so an
  unenriched `.civitai.info` stays byte-pure API output. Fields no table
  knows land in an `unmatched` discovery bucket surfaced on screen — the
  taxonomy grows from evidence instead of silently eating unknowns.
- Every run (new placement AND already-cached) is an idempotent SYNC: each
  sidecar is recomputed, canonically serialized, and written only on
  difference. A conflicting incoming user field refuses that file's ENTIRE
  adoption with a side-by-side diff unless `--force` — user curation is the
  one thing the tool must never silently rewrite.

### Content-sniff routing (and why the unpickler is safe)
- The hash pass buffers a prefix of the file, from which the sniffer derives
  facts (ControlNet vs T2I-Adapter, upscaler architecture, base model,
  dtype), each tagged `absolute` or `uncertain`. safetensors is trivial (the
  header is JSON). Pickled checkpoints go through a RESTRICTED unpickler
  that executes none of the payload: `find_class` never imports or resolves
  a real class — it returns a single inert stand-in — and `persistent_load`
  (torch tensor storages) returns the same, so every REDUCE/instantiation
  calls the inert stub instead of attacker code; the stub only records dict
  keys assigned to it, which is exactly what a state dict's tensor names
  are. Both modern torch zip pickles and legacy bare pickles are covered.
- An ABSOLUTE sniff that contradicts the API's declared type wins the
  ROUTING (a mislabelled T2I-adapter lands in `T2IAdapter/`, not
  `ControlNet/`); an uncertain sniff defers to the API. Sniffing never
  overrides the hash-proven identity — only the placement directory.

### Long filenames — byte budget, advisory cascade, --rename
- Normalized `<Model>_<Version>` names can outgrow NAME_MAX (255 bytes on
  ext4 — BYTES, so CJK costs 3 per character). The budget is computed per
  destination via `os.pathconf` (walking up past not-yet-created components;
  255 when it cannot say), minus the WIDEST family member built over the
  stem — the model file, the widest sidecar (`.civitai.info`), the widest
  carried preview, and the `.tmp-<name>-<pid>` staging form of each.
- The fit check runs in bytes and BEFORE any `exists()`/stat — a too-long
  name would make even `Path.exists` raise ENAMETOOLONG — so an over-budget
  name is refused untouched and the batch continues.
- The recommendation is ADVISORY ONLY — the tool never truncates a name
  itself; the user pastes the suggested stem into `--rename`. It is a
  CUMULATIVE cascade of ever-blunter filters, each narrowing the previous
  step's candidate: NFKC-normalize + drop historic/archaic-script
  characters, then drop Unicode planes 2–16, plane 1, 3-byte UTF-8 (all
  CJK), non-ASCII, and finally right-truncate keeping the last 8 characters.
  Deleted characters leave their surrounding punctuation intact — no
  re-collapse — so the result stays honest about what was removed.
- `--rename NAME` (the run must match exactly one file) is recorded as the
  guarded `filename` field in `.user.droste` and READ BACK on later runs:
  the routed directory's `*.meta.droste` sidecars are scanned for the file's
  sha256 and the paired `.user.droste` name is reused, so a plain re-run
  lands on ALREADY instead of re-refusing — and because the read-back record
  is the guard's basis, a DIFFERENT `--rename` cannot silently shed the
  previously recorded name.

---

## Base images

### base/Container.runtime
Root of the unified ROCm lineage — replaces the old `amd-runtime-base` +
`therock-torch-base`. TheRock gfx1151 ROCm RUNTIME kernels on canopy (no init).
The build base builds FROM this, so the de-divert (see cross-cutting) runs
exactly once and compiled artifacts ABI-match the runtime libs shipped here.

- Re-add exactly what canopy purges, plus the venv toolchain. Canopy KEEPS
  bash/coreutils/libstdc++6/libgcc-s1/libgomp1/ca-certificates/python3 (3.13) —
  do NOT re-add those. It PURGES `sudo`/`procps`/`libnss-myhostname`: sudo+procps
  for interactive use, `libnss-myhostname` for distrobox host-name resolution.
  `radeontop` is a Debian-main GPU monitor (not in any gemet base).
  `python3-venv`/`python3-pip` are NOT present in canopy and are needed to build
  `/opt/venv` and pip-install the ROCm wheels.
- Python venv with the TheRock gfx1151 RUNTIME kernels: Debian 13 is PEP668
  externally-managed, so install into a venv (preferred, matches the old
  therock-torch-base) rather than `--break-system-packages`. Install the `rocm`
  meta with the `[libraries]` extra: `rocm[libraries]` == `rocm` (provides the
  `rocm-sdk` CLI + `rocm_sdk` module) + `rocm-sdk-core` (rocminfo/rocm-smi/hipcc
  console scripts + the HIP runtime `.so` / `_rocm_sdk_core` tree) +
  `rocm-sdk-libraries-gfx1151` (rocBLAS/hipBLASLt/MIOpen in its own
  `_rocm_sdk_libraries_gfx1151` tree). Installing the meta (not the bare leaves)
  is what makes `rocm-sdk path` work.
- Pinning `/opt/rocm`: NOTE that `rocm-sdk path --root` CANNOT be used here — it
  routes through the devel module and errors without `rocm[devel]`, which this
  runtime image does not carry. The core tree is deterministically
  `<venv-site-packages>/_rocm_sdk_core`, so derive it directly (no CLI, no
  devel). ld.so wiring lets the runtime `.so` resolve for non-venv procs: emit
  `/opt/rocm/lib{,64}` FIRST, then every sibling `_rocm_sdk_*/lib` tree (so the
  split rocBLAS/hipBLASLt/MIOpen libraries wheel resolves too), then `ldconfig`.
- `/etc/profile.d/rocm.sh` is a real script here (the OLD llama Containerfile
  wrote an EMPTY file here — that was a bug). It activates the venv and exports
  `ROCM_PATH` from the stable `/opt/rocm` symlink, then the HIP/PATH/LD env for
  interactive shells.
- Bakes the shared runtime contract: `/opt/resources/resolve/` (resolver +
  entrypoint + init hook + templates applier, on PATH) and `VOLUME /opt/data`
  (auto-anonymous-volume when unbound; the resolver warns). See "Runtime
  contract" above.
- No `CMD` and no base `ENTRYPOINT` (ports opt in to `droste-entrypoint.sh`).

### base/Container.build
TheRock gfx1151 ROCm SDK (`rocm-sdk-devel`) + host toolchain for native gfx1151
builds. Replaces the old `amd-build-base`. NOT a shipped image — builder stage
only. Builds FROM the runtime base so it inherits the de-divert + GNU coreutils,
the `/opt/venv`, and the runtime kernels; `rocm-sdk-devel` installs into the SAME
venv, so devel headers/compilers sit next to the runtime wheels, and anything
compiled here ABI-matches the runtime libs it ships against.

- Host compilers + build tools are Debian-main (NOT ROCm) — the ROCm compiler
  (amdclang++/hipcc) comes from the `rocm-sdk-devel` wheel. Kept broad from the
  old amd-build-base for now (trim later): `lld`/`clang` + `libclang{,-rt}-dev`
  give a host clang alongside ROCm's; `libcurl4-openssl-dev` / `libomp-dev` are
  direct build deps of the ports (llama curl; ds4 rocWMMA OpenMP at
  `/usr/lib/x86_64-linux-gnu/libomp.so`). `libomp-dev` pulls the correct
  `libomp5-N` runtime on trixie (there is no bare `libomp1`). `git`/`patch`/
  `rsync` for clone+patch+collect.
- TheRock ROCm SDK devel (amdclang++/hipcc, HIP headers, device bitcode, cmake
  configs) via the `rocm` meta's `[devel]` extra. Installing the meta (not the
  bare `rocm-sdk-devel` leaf) also pulls the `rocm` package that provides the
  `rocm-sdk` CLI — `rocm[devel]` == `rocm` + `rocm-sdk-core` + `rocm-sdk-devel`.
  The devel tree is packed and expanded by `rocm-sdk init` (which drives the
  `rocm_sdk` module); no GPU is needed (do NOT run `rocm-sdk test`).
  `rocm-sdk-core` came in via the runtime base; the meta is additive here.
- Point `/opt/rocm` at the SDK root via `rocm-sdk path --root` (available from
  the meta; after `init` the root is the full expanded tree — headers + hipcc +
  cmake configs at `lib/cmake`). Do NOT create a separate `/opt/rocm-cmake`
  symlink to `path --cmake`: `hip-config.cmake` computes its package prefix by
  walking UP from its own location (`<root>/lib/cmake/hip` -> `../../..` ->
  `<root>`), so a flattened symlink to the cmake dir makes that walk-up overshoot
  to `/`, yielding an empty prefix (`hip_INCLUDE_DIR=//include` -> CMake Error).
  Pointing `CMAKE_PREFIX_PATH` at the tree ROOT lets cmake find `lib/cmake/hip`
  AND resolve the prefix back to `<root>/include`.
- Build env so `cmake -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151` / ds4
  `make ROCM_PATH=` resolve the pip-installed compiler + device libs.
  hipcc/amdclang++ are on `/opt/venv/bin` (PATH). The device-lib + clang paths
  are best-effort under the SDK root (validate on-host — see notes).
- `GFX_TARGET` is gfx1151-only. It is NOT re-exported as an image `ENV` here
  (that would be a second copy of the pin's truth, and the old `ENV
  GFX_TARGET=${GFX_TARGET}` needed an `ARG` to feed it): it lives in the
  inherited `/etc/droste/rocm-version.env`, and each carrier `RUN` sources that
  file to pass `-DAMDGPU_TARGETS` / `--offload-arch=${GFX_TARGET}`.
- No `CMD`: builder stage only.

### base/Container.torch
Shared torch layer. `FROM` the runtime base + one
`. /etc/droste/rocm-version.env && uv pip install torch==$TORCH_VERSION`
from the gfx1151 index, plus the one apt layer torch's own triton demands at GPU
init (`gcc` + `python3.13-dev`, last bullet) — nothing else. The three Python
targets (comfyui, vllm,
finetuning) build FROM this instead of installing torch themselves; llama and ds4
stay torch-free on the runtime base and do NOT go through here.

- **Why it exists:** all three consumers pinned the *identical*
  `torch==2.9.1+rocm7.13.0a20260501`, but each installed it in its own `RUN` →
  three distinct layer digests → OCI stored the ~1 GiB wheel 3× in GHCR and 3× on
  any host pulling all three. Installing once here gives ONE layer digest that all
  three share.
- **What it does NOT do:** it does not shrink any single image (comfyui/vllm/
  finetuning still need torch, so each is still ~torch-sized). The win is
  cross-image dedup — one stored copy instead of three (~2 GiB saved in the
  registry / on a host with all three) — plus the three stop rebuilding and
  re-pulling torch on changes unrelated to the torch pin.
- **Scope = torch only.** torchvision/torchaudio stay with the ports that need them,
  NOT here: comfyui installs both, vllm re-pins torchvision alone (2026-08-14, see
  its section), finetuning wants neither. gguf/transformers likewise stay in comfyui.
- No pin `ARG`s at all: the version comes from the file the runtime base baked
  in, sourced inside the `RUN`, so this layer is pinned by its own base.
- No `CMD`: intermediate base, never run directly.
- **Triton's GPU-init-time C compile — `gcc` + `python3.13-dev`, the one apt
  layer this base carries** (hardware 2026-08-15; the deepest layer of the
  onion and the first one only a GPU could find). Triton's AMD backend
  (`triton/backends/amd/driver.py`, `HIPUtils`) runtime-compiles a small C
  helper module, `hip_utils`, through `compile_module_from_src` the FIRST time
  the GPU driver is initialised. That is SERVE/run time on a GPU host — never
  import time — so every gate we own runs upstream of it: the compiler-less
  `import aiter` smoke test passes, `pip check` passes, the build is green, and
  the service then dies with `RuntimeError: Failed to find C compiler` (triton
  probes `gcc`, then `clang`, and these images had neither). Adding gcc alone
  moves the failure exactly one step, to `fatal error: Python.h: No such file
  or directory`.
  **Why the fix lives here and not in a port:** the trap is a property of the
  torch stack (torch ships triton), so it belongs to whoever ships torch — and
  on 2026-08-15 BOTH triton-carrying children reproduced it verbatim, same two
  steps, same order: vllm (found first; cure verified by `vllm serve` coming
  up) and finetuning (independently confirmed on the same box; cure verified
  by driving a full triton JIT kernel launch, which printed `True`). Of the
  three children of this base, that is two bitten and one — comfyui —
  self-covered, because it already installs the FULL toolchain
  (gcc/g++/make/binutils) at runtime for ComfyUI's own Triton JIT; its list is
  now partly duplicative of this layer and is kept verbatim on purpose (apt is
  a no-op on what is installed, and comfyui's list should stay a self-contained
  statement of comfyui's needs). `llama`/`ds4` never come through here, carry
  no torch and no triton, and are immune. One install, two cures, zero reach
  into the immune images.
  In both cases those two packages were the WHOLE bill measured live — no HIP
  headers beyond what the images already carry, nothing else missing. Baked as
  the exact `python3.13-dev` rather than the `python3-dev` metapackage: the
  venv is Debian 13's system python3.13, triton's include path comes from
  `sysconfig` (`/usr/include/python3.13`), and the exact name is what the build
  stages already pin — the metapackage would silently follow a future Debian
  python3 default away from the venv's interpreter. Placed ABOVE the torch pip
  layer so a pin bump does not re-run apt.
  **`gcc`, NOT `g++` — and no `c++` on this base at all.** vllm's aiter probes
  `shutil.which("c++")` and must keep finding nothing, so its prebuilt
  `module_aiter_enum.so` (see the vllm section) stays load-bearing; a `g++`
  here would silently re-arm that lazy JIT path in a child image. The C++/hipcc
  toolchain still belongs to the build images.
  The generalisation: **build != import != serve**. CI can only ever reach the
  first two, so anything that fires on GPU-driver init is hardware-only by
  construction — found on the box and fixed by baking, never by a gate.

---

## Scaffolding (build carriers)

### scaffolding/Container.ds4-build
Compile ds4 (`kyuz0/ds4`) against the pinned SDK and emit ONLY ds4's own outputs
as a scratch carrier under `/artifacts/{bin,lib64,share}`. FIRST of the five ROCm
toolbox ports — sets the artifacts pattern the other four copy. `ds4-runtime`
consumes this via `COPY --from`.

- rocWMMA is a BUILD-ONLY dependency: its headers/device templates are baked into
  the ds4 binaries at compile time and are NOT shipped in the carrier. ROCm
  itself (hipcc/amdclang++, rocblas/hipblas/hipblaslt/hipcub headers+libs) is
  already provided by the build base's pip `rocm-sdk-devel`, so — unlike the
  Fedora source — this port apt-installs NO ROCm/`-dev` packages (`libomp-dev`/
  `libomp1`, the only genuine Debian-main build dep, already ships in the base).
- Pinned refs (never float HEAD): `DS4_REF` is `00e64ea8…` — the head of kyuz0/ds4's
  `rocm-multi-node` branch when `c756385` (2026-07-05) resolved it, and that branch
  is the one the Fedora source built. It was the bare branch name until then.
  NOTE: the earlier `84a580d8…` default was the
  strix-halo-ds4-toolbox HEAD — a DIFFERENT repo, wrong for the ds4 app; it
  remains correct as `COCKPIT_REF` in ds4-runtime, which is the toolbox repo.
- `ROCWMMA_REF`: upstream used branch `release/rocm-rel-7.2`; `c756385`
  (2026-07-05) pinned it to `48b7db12…`, that branch's head at the time, so the
  "pin to a SHA" half of this FLAG is closed. The other half stands: our SDK is
  `7.13.0a` (TheRock nightly), and rocWMMA-vs-SDK version alignment still wants an
  on-host build test.
- rocWMMA (build-only) is installed from source into `$ROCM_PATH`: its version
  header is generated by cmake, so a raw header copy won't work — it must be
  `cmake --install`ed. Compiled with the SDK's amdclang/amdclang++
  (`$HIP_CLANG_PATH` = `/opt/rocm/lib/llvm/bin` and `/opt/venv/bin` on PATH,
  `CMAKE_PREFIX_PATH` set so `find_package(hip)` resolves). Tests/samples OFF.
  Debian OpenMP fix vs the Fedora source: `/usr/lib64/libomp.so` ->
  `/usr/lib/x86_64-linux-gnu/libomp.so` (`libomp-dev`). Installed into
  `$ROCM_PATH`, then discarded with the builder stage — nothing from rocWMMA
  reaches the carrier.
- ds4 build: full clone (not `--depth 1`) so an arbitrary pinned commit is
  reachable for checkout. The ds4 Makefile's `rocm` target drives hipcc under
  `ROCM_PATH`; `ROCM_ARCH=gfx1151` -> `--offload-arch=gfx1151`.
- Collect ONLY ds4's own outputs into the seam: the three binaries + the
  model-download helper are what the Fedora source shipped; also sweep any
  `lib*.so` ds4 produced into `lib64` (none today, but keeps the pattern honest;
  the `find` matches zero files harmlessly).

### scaffolding/Container.finetuning-build
gfx1151 native builds for the LLM-finetuning toolbox, on a scratch carrier
consumed by `finetuning-runtime`. Two things are built here (translated from the
upstream multistage Dockerfile `github.com/kyuz0/amd-strix-halo-llm-finetuning`):
1. bitsandbytes (ROCm/hip backend, gfx1151) → a wheel in `/artifacts/wheels`
2. a custom RCCL for gfx1151 → `librccl.so.1` in `/artifacts/lib64`

Deliberate upstream deltas:
- The upstream `/opt/rocm-7.0` TheRock S3 TARBALL fetch is DROPPED entirely. The
  build base already provides the pip TheRock SDK at `ROCM_PATH=/opt/rocm`
  (`rocm-sdk-devel`: hipcc/amdclang++ + HIP headers + device bitcode). All
  `/opt/rocm-7.0` references become `${ROCM_PATH}` = `/opt/rocm`.
- Upstream does NOT build RCCL — it `COPY`s a prebuilt `librccl.so.1.gz` produced
  by a separate CI workflow (`build-rccl.yml` in the vllm-toolboxes repo). We
  instead build RCCL from source here, using that workflow's recipe
  (`scripts/build_rccl_gfx1151.sh`: `kyuz0/rocm-systems` @ branch
  `gfx1151-rccl`, `projects/rccl`). This makes the port self-contained.
- bitsandbytes is packaged as a WHEEL (not `pip install`ed) so the runtime stage
  installs it into its own venv. The runtime version-parse symlink fixup happens
  in the runtime Containerfile (after install), not here.
- Clone pins (this FLAG closed at `c756385`, 2026-07-05): `BITSANDBYTES_REF` is
  `8ab26f75…` off bitsandbytes-foundation/bitsandbytes `main` (ROCm v0.46.1+), and
  `RCCL_REF` is `a2686c9f…` off kyuz0/rocm-systems `gfx1151-rccl`. Both were moving
  branch heads until that commit resolved them to the shas that had just built
  green; neither floats now.
- Pinned torch into the build venv: bitsandbytes' hip build/packaging detects the
  installed ROCm (and, for the runtime lib name, the torch/ROCm version) via the
  same interpreter it ships for. Thrown away with the builder stage — only the
  wheel + librccl reach the carrier.
- Carrier layout mirrors the other ports: `wheels/` for pip-installables,
  `lib64/` for raw `.so`.
- PEP517 build backends: bitsandbytes `main` uses
  `scikit_build_core.setuptools.build_meta`, and `uv build --wheel
  --no-build-isolation` requires the backend importable in the venv already
  (torch does not pull it) — hence the `scikit-build-core setuptools wheel`
  upgrade. Same requirement `pip wheel` had; the wheel step moved to `uv build`
  in s46 (plan item 1).
- `libdrm-dev`: RCCL's rocm_smi headers include `<libdrm/drm.h>`, and torch's
  `LoadHIP.cmake` runs `pkg_check_modules(libdrm)` via `rocm_smi-config.cmake`.
  Provides the headers + `libdrm.pc` (the build base ships neither).
- bitsandbytes (ROCm/hip): in-source cmake (`COMPUTE_BACKEND=hip`) emits
  `libbitsandbytes_rocm*.so` into the package tree; the wheel build then bundles
  that prebuilt `.so`. OpenMP: `find_package(OpenMP)` resolves Debian's `libomp-dev`
  (`/usr/lib/x86_64-linux-gnu/libomp.so`) — no Fedora `/usr/lib64` path.
- Custom RCCL: recipe lifted from the upstream build-rccl CI. hipcc is resolved
  from PATH (`/opt/venv/bin`) rather than the upstream's hardcoded
  `$ROCM_PATH/bin/hipcc`, whose presence under the pip SDK root is unconfirmed
  (see notes). Collect the real SONAME file (`cp -L` dereferences the
  `librccl.so.1` symlink) into `lib64`.

### scaffolding/Container.llama-build
gfx1151 llama.cpp (`TheTom/llama-cpp-turboquant` fork) compiled against the SDK,
captured as a scratch carrier consumed by `llama-runtime`. NO ROCm/`-dev`
installs — hipcc/amdclang++, HIP headers, rocblas/hipblas/hipblaslt and the
device bitcode all come from the build base's pip SDK (all inherited as ENV).

- llama.cpp source pin: the fork carries the turboquant quant kernels; upstream
  ships no BRANCH arg (fork default branch). `LLAMA_REF` pins the source to a
  fixed commit, defaulting to `337f08e82a861194fd5fc93121205c7c6bc81ddf`. The
  toolbox repo that vendors these assets was itself at submodule commit
  `6318f02422ebcc40829d222107352934a6cc2fae` — that is the provenance of the
  patches/helper, NOT a llama.cpp sha.
- The pinned commit is **fetched by sha, not cloned** — and the reason is worth
  keeping, because it will recur with any pinned fork whose owner rebases.
  `git clone --single-branch` retrieves only the fork's default branch, so when
  upstream force-pushed that branch (2026-08-08) the pinned `LLAMA_REF` stopped
  being reachable and the build died with `fatal: unable to read tree`. The
  commit object is still served by sha, so `git init` + `git fetch --depth 1
  origin <sha>` + `git checkout FETCH_HEAD` restores the build **without moving
  the pin**, and is immune to any future branch rewrite. With no `LLAMA_REF` the
  same path fetches `HEAD`.
- `hip-rocm7rc.patch` was DROPPED as non-upstream (no upstream Dockerfile applies
  it; the turboquant build succeeds on ROCm 7.x / HIP 7 without it). Re-add it
  (and its COPY) only if an on-host HIP7 build failure shows it's needed.
- The consumed patches (`llama-grammar.patch`, `llama-api-prefix-auth.patch`) live
  in `scaffolding/llama-artifacts/` — this stage's build CONTEXT (`art_ctx` in
  `build-halo.yml`), not the directory the Containerfile itself sits in.
  `llama-grammar.patch` was copied from the upstream toolbox submodule so the
  context is self-contained; `llama-api-prefix-auth.patch` is ours. Both patch
  relative to the repo root (`-p1`).
- The shallow fetch brings no submodules, so materialize them after the
  checkout (`git submodule update --init --recursive`).
- Apply the turboquant grammar patch: `llama-grammar.patch` raises
  `MAX_REPETITION_THRESHOLD` from 2000 to 100000 for complex tool schemas. This is
  the ONLY patch upstream's turboquant Dockerfile applies.
  🚨 **PERMANENT, NOT A STOPGAP, and ANCHOR-GUARDED.** It was never filed with
  llama.cpp — `kyuz0/amd-strix-halo-toolboxes#70` asked a third-party image project
  to raise the constant, and its `completed` status means *he rebuilt his images*,
  not that upstream changed anything. ggml-org master and the turboquant fork's own
  default branch both still say 2000 (verified 2026-09-01), the two upstream PRs
  that would make the constant configurable (#21003, #21139) are open and unmerged,
  and we are not pursuing it.
  ⭐ **The failure this guards is INVISIBLE from outside**: both gates that read the
  macro throw at *grammar-parse* time, so a patch that silently applied nothing
  still builds, still starts, still answers `/health` 200 and still passes the
  healthcheck — and returns "failed to parse grammar" to every tool-calling request.
  So the `RUN` does exact whole-line counts before AND after, `patch -F0` (a drifted
  hunk lands at fuzz 2 with default settings — measured), and a refusal to patch
  twice. ⚠️ **One count is a FLOOR on purpose**: the number of lines that READ the
  macro is 2 at our pin and 3 on the fork's head, so pinning it exactly would go red
  on a bump that changes nothing. Every other count is exact and IS the contract —
  when one moves, re-derive the hunk at the new SHA rather than adjusting the count.
- ⚠️ **`scaffolding/_fedora-src/llama.Containerfile` applies the same patch UNGUARDED
  and stays that way, deliberately.** It is a frozen translation reference ("DO NOT
  BUILD", CI-excluded), it is not buildable from its own directory (the patch it
  `COPY`s is not there), and it clones the fork's default branch with **no ref** — so
  a counts contract against it would pin a moving head and rot silently. A guard
  nobody runs reads as coverage and is not.
- Apply the api-prefix auth patch: `llama-api-prefix-auth.patch` builds
  llama-server's api-key-exempt endpoint set from the configured `--api-prefix`
  instead of from bare literals.
  ⭐ **WHAT BREAKS WITHOUT IT, and it is bigger than our probe.** Each flag is fine
  alone; the PAIR fails. Every route is registered as `path_prefix + path`
  (`server_http_context::get`/`::post`, and the Web UI block registers
  `params.api_prefix + "/"`, `+ "/index.html"` and `+ "/" + a.name` per asset), but
  the exempt set is built from BARE literals — `/health`, `/v1/health`, `/models`,
  `/v1/models`, `/`, plus each UI asset — and the middleware tests
  `get_public_endpoints.count(req.path)`: an EXACT match on the RAW WIRE PATH from a
  `set_pre_routing_handler`, so it runs BEFORE routing and nothing has stripped the
  prefix. With both flags set, `/<prefix>/health` 401s — **and so do `/<prefix>/` and
  `/<prefix>/index.html`, i.e. the user's Web UI is unusable.** The healthcheck half
  is the loud one: `HEALTH_ACCEPT="ok"` passes only 2xx/3xx, so 401 reads UNHEALTHY
  and `--health-on-failure=restart` bounces the container, ejecting every interactive
  shell.
  ⚠️ **This is NOT a probe bug and cannot be fixed in the probe.** `read_health_spec`
  already prepends the configured prefix to `HEALTH_PATH`, so the probe asks the
  CORRECT URL and gets 401 anyway. Teaching the probe more about prefixes buys
  nothing; the exempt set is the defect.
  ✅ **IT WIDENS NOTHING — it restores parity.** Verified in the pinned source: with a
  key set and NO prefix, `/health` is already in the exempt set and the middleware
  returns early, so those endpoints are public by upstream's design. `api_prefix`
  defaults to `""` (`common/common.h:608`), so `path_prefix + "/health"` is
  byte-identical to `"/health"` on an unprefixed server. The LIST is untouched: same
  five paths, same UI assets, relocated to where they are actually served.
  🚨 **PERMANENT, NOT A STOPGAP, AND A PIN BUMP WILL NOT FIX IT.** Upstream
  `ggml-org/llama.cpp` #22474 was labelled `stale` and then closed `not_planned` **by
  `github-actions[bot]`** — the only comment on the issue is the bot's own, and no
  maintainer ever responded. We do not file upstream. Verified 2026-09-01: master
  still declares the set `static const` from bare literals and still exact-matches
  `req.path`, so the defect is present there today.
  ⚠️ **DO NOT RE-DERIVE FROM ggml-org MASTER.** Master has DROPPED `/models`,
  `/v1/models` and `/` from the exempt set and replaced the asset loop with a
  `frontend_paths` set; copying its list would silently change WHICH endpoints are
  public on our pin. Derive from the pinned fork's own source.
- **Its anchor guard: 7 exact counts before, 5 after, `-F0`, and a refusal to patch
  twice** (`scaffolding/Container.llama-build`). Five of the seven pin lines the patch
  itself rewrites; **two are assumption pins** — that `path_prefix` is still assigned
  from `params.api_prefix`, and that routes are still registered as `path_prefix +
  path` (2 sites at our pin) — because without them a drifted source would fail
  confusingly rather than loudly. ⭐ **Unlike the grammar guard, every count here is
  EXACT; there are no floors.** A moved count means **re-derive the hunks at the new
  SHA**, never adjust the count. Concretely, that will happen: master registers three
  route sites now (`Get`/`Post`/`Delete`) against our pin's two.
  🚨 **`-F0` IS DOING WORK THE TWELVE COUNTS CANNOT DO, and this is the non-obvious
  part.** Measured host-side against the real pinned `tools/server/server-http.cpp` at
  `337f08e8`: drift ONE trailing context line of hunk 1 and the unguarded `patch`
  applies it **at fuzz 1, exits 0, and lands all 6 prefixed paths** — so every one of
  the twelve counts still passes and the build goes green on a hunk placed by fuzz.
  A reader who sees twelve checks will assume the counts are the protection. They are
  not, on their own. (Drifting a LEADING context line instead is rejected until fuzz
  3 — the ends are not symmetric, which is why the strictness is set at the patch call
  and not inferred from the counts.)
  ⚠️ The `patch -F0` call carries its own `|| die`, so a hunk that stops applying
  reports what to DO — re-derive at the new SHA, do not relax `-F0` — instead of
  dying on GNU patch's bare `Hunk #1 FAILED`. **Nobody is watching for this patch to
  become unnecessary, so this guard is the only mechanism that will ever report it
  stopping.**
  ✅ The same host-side harness runs the guard body extracted verbatim from the
  Containerfile against a pristine tree fetched by SHA: all 7 before-checks, both
  hunks and all 5 after-checks pass at `337f08e8`, which is the only verification of
  those counts that exists outside a CI run.
- ⭐ **TURBOQUANT IS OPT-IN — the kernels are compiled in, nothing selects them.**
  Measured at the pin (`common/arg.cpp:390`): the fork's contribution here is three KV
  CACHE quant types, `GGML_TYPE_TURBO2_0/3_0/4_0`, added to `kv_cache_types` — the list
  consumed by `-ctk/--cache-type-k` and `-ctv/--cache-type-v`. The default stays F16, so a
  box that sets neither flag never uses them (Jei observed exactly this on hardware before
  it was confirmed in the source).
  ⚠️ **The accepted STRINGS are `turbo2` / `turbo3` / `turbo4`** (`ggml.c` `type_name`),
  NOT the enum spellings — an unknown value throws `Unsupported cache type` and the server
  does not start. Both flags carry env annotations (`LLAMA_ARG_CACHE_TYPE_K` / `_V`), so
  they arrive as commented lines in the generated `llama.cfg`:

      LLAMA_ARG_CACHE_TYPE_K=turbo4
      LLAMA_ARG_CACHE_TYPE_V=turbo4

  On a large MoE at long context the KV cache is where the headroom goes, so this is the
  knob that matters most on a 128 GB machine. The quality cost of turbo3/turbo2 has NOT
  been measured here.
- **How to prove the running binary IS the fork:** `llama-server --version` reports the
  build commit; it must match `LLAMA_REF`. The build also fails if the required
  `LLAMA_ARG_*` names are missing from the binary — `targets/Container.llama` scans it for
  the literals. ⚠️ It no longer EXECUTES llama-server: `--help` dies with SIGILL on a
  GPU-less runner. Nothing installs llama.cpp from apt (the runtime's only
  apt install is `libgomp1`), so `/usr/local/bin/llama-server` can only be the built
  artifact.
- HIP build for gfx1151: `ROCM_PATH`/`HIP_PATH` resolve the pip SDK root;
  `AMDGPU_TARGETS=${GFX_TARGET}`. RPC + HIP UMA + unified memory are the
  turboquant/Strix-Halo flags (128 GB unified mem). FLAG (on-host): confirm HIP
  cmake resolves `hip-config.cmake` / amdgcn bitcode from the pip SDK.
- Collect ONLY llama.cpp's own outputs into `/artifacts/{bin,lib64,share}` (ROCm
  runtime `.so` come from the runtime base, not this carrier): `bin` = build/bin/*
  incl the `rpc-*` binaries; `lib64` = every `lib*.so*` under build
  (libllama/libggml*).
- The vram helper ships from the build context (not the repo) — copied into
  `share/` (the runtime installs it to `/usr/local/bin`) and marked executable.

### scaffolding/Container.vllm-build
HEAVIEST port. Compiles the heavy ROCm/gfx1151 wheels for the vLLM toolbox —
flash-attention (ROCm fork), aiter (`amd_aiter*.whl`), and vLLM itself — from
source against the pinned TheRock torch, then ships them alone from `scratch`.
Toolbox submodule provenance (droste-ai-halo):
`6446b9595273f289e11586c3c7d3e1e6f2945888`.

- KEY DEVIATION vs upstream: upstream installs a Fedora ROCm-SDK TARBALL via
  `scripts/install_rocm_sdk.sh` (into `/opt/rocm`) — DROPPED. The build base
  already provides the pip TheRock SDK (`rocm-sdk-devel`) at `ROCM_PATH=/opt/rocm`,
  with the ROCm clang under `/opt/rocm/lib/llvm/bin` (NOT the Fedora
  `/opt/rocm/llvm/bin`). We build against that.
- Clone pins: `VLLM_REF` is pinned to `v0.16.0` — the newest vLLM stable tag that
  targets torch 2.9.1 (its `requirements/cuda.txt`: `torch==2.9.1`). v0.16.1rc0+
  bump to torch 2.10.0 and add the `csrc/libtorch_stable` extension, which needs
  `torch/csrc/stable/device.h` (torch-2.10 ABI) and fails to compile against our
  pinned 2.9.1. flash-attention no longer floats `main_perf`: `c756385`
  (2026-07-05) pinned `FLASH_ATTENTION_REF` to `3f94643f…` off that branch, an
  upstream commit of 2026-03-12 — the v0.16.0 era the FLAG here asked for, that
  tag having been published 2026-02-25 (and a flash-attn sha transitively pins its
  aiter + composable_kernel submodules via the gitlink).
  `FLASH_ATTENTION_BRANCH=main_perf` survives beside it only as the fallback for
  an empty REF. FP8 kernels are pinned to upstream's default.
- Torch (pinned TheRock nightly) into the base venv: vLLM + flash-attn + aiter all
  compile their C++/HIP extensions against this torch's headers/ABI. ✅ **The old
  FLAG here — "`TORCHVISION_VERSION`/`TORCHAUDIO_VERSION` are unset" — is STALE and
  was corrected s45.** Both have been locked in `base/rocm-version.env` for a while
  (`0.24.0+rocm…` / `2.9.0+rocm…`, same date as torch), and `targets/Container.vllm`
  reinstalls the ROCm torchvision over whatever the wheel's own dependency
  resolution pulled in.
- Python build backends (mirrors upstream): `setuptools<80` avoids the vllm/
  flash-attn `setup.py` breakage on the newer editable-install API.
- flash-attention (ROCm fork) + aiter: upstream installs flash-attn in-place; we
  instead build BOTH aiter and flash-attn as WHEELS into `/artifacts/wheels`.
  aiter must be built+installed FIRST (flash-attn's `setup.py` builds against it)
  and its bundled ck_tile headers patched for RDNA3.5 (gfx1151) scalar fallbacks
  (`patch_aiter_headers.py`) before flash-attn compiles. The Fedora `lib/` vs
  `lib64/` site-packages merge is DROPPED — Debian venvs have a single
  `lib/pythonX.Y/site-packages` (no lib64 split). Steps: clone flash-attn -> init
  aiter + composable_kernel submodules -> build the aiter wheel and install it ->
  patch installed aiter ck_tile headers for gfx1151 (needed by the flash-attn
  build AND by aiter's runtime JIT; vllm-runtime re-patches its own copy) ->
  neutralize flash-attn `setup.py`'s aiter-submodule build subprocess (aiter
  already built) -> build the flash-attn wheel (upstream pip-installs; we ship
  the wheel).
- aiter JIT prebuild (2026-08-14): `import aiter` runs `aiter/ops/enum.py` at
  module scope, which JIT-compiles `module_aiter_enum` — so merely importing
  aiter needs a COMPILER, which the runtime image deliberately lacks. Built here
  (`python -c "import aiter"`) and staged to `/artifacts/aiter-jit`; the runtime
  drops the `.so` into its own `site-packages/aiter/jit/`. Three details: the
  source is a `.cu`, so hipcc wants device bitcode -> set
  `HIP_DEVICE_LIB_PATH="$(find -L /opt/rocm ... -name bitcode ...)"` (the pip SDK
  does not put it where clang looks by default). **`-L` is load-bearing**:
  `/opt/rocm` is a symlink and find(1) will not descend into a symlinked start
  point, so the vLLM step's bare `find` below actually yields `""` — harmless
  there only because it compiles with `/opt/rocm/lib/llvm/bin/clang`, which
  self-locates its bitcode, while plain `hipcc` does not. `GPU_ARCHS` must
  be pinned to `${GFX_TARGET}` because aiter's `native` default shells out to
  `rocminfo` and no CI runner has a GPU; and the bare import is the NARROWEST
  trigger — every other op builds lazily on first call, while aiter's official
  `PREBUILD_KERNELS` hook is coarser (even mode 3 also codegens
  `module_fmha_v3*`). Placed BELOW the vLLM apt layer rather than up with aiter:
  it is the first step in this stage that compiles a pybind11 module, so the
  first to need `Python.h`, and `python3.13-dev` arrives in that layer (nothing
  above compiles against Python — aiter's wheel is pure packaging, flash-attn
  skips its C++ extension under Triton). Learned the hard way in CI run
  31849687656: `hipcc ... -isystem /usr/include/python3.13` -> not found. Costs
  one rebuild of the vLLM layer below it, then caches again.
- vLLM: Rust toolchain (`rustc`/`cargo`, Fedora `dnf install rust cargo` ->
  Debian) for vLLM's PyO3/`_rust_*.so` parser extensions (setuptools-rust
  backend). Kept after the flash-attn/aiter layers so those stay cacheable.
  `python3.13-dev` supplies `Python.h` + the cp313 dev components CMake
  `FindPython(Development.Module/SABIModule)` needs to configure vLLM's C++/HIP
  extensions against the venv interpreter (the build base ships no python dev
  headers; only vLLM compiles `_C` here). `libdrm-dev`: torch's `LoadHIP.cmake`
  runs `pkg_check_modules(libdrm)` via `rocm_smi-config.cmake` when vLLM does
  `find_package(Torch)`.
- Clone + patch vLLM: `patch_strix.py` (amdsmi stub, forced gfx1151, aiter/MoE/
  rmsnorm gating, clang-safe spinloop include) + `patch_fp8_kernels.py` (opt-in
  FP8 Triton dequant-GEMM shim). ⚠️ Read the FP8 bullet below before believing
  anything about the second one.
- Build the vLLM wheel with the ROCm clang host compiler (ABI-aligns vLLM's C++
  extensions with torch — avoids the GCC-host segfault). NOTE the SDK layout
  difference: pip TheRock ships clang under `/opt/rocm/lib/llvm/bin` (Fedora
  tarball used `/opt/rocm/llvm/bin`).
- Pure-python FP8 Triton kernels (leonyurko): NOT a wheel — the modules live on
  `PYTHONPATH` at serve time (`patch_fp8_kernels.py`'s shim does
  `from fp8_triton import fp8_gemm`, opt-in via `VLLM_STRIX_FP8_TRITON=1`).
  Carried as a source tree; vllm-runtime `COPY`s it to `/opt/fp8`.
  🚨 IT NEVER RAN, IN ANY BUILD THIS REPO HAS PRODUCED, UNTIL s61 part 2. The
  script targeted `vllm/model_executor/kernels/linear/scaled_mm/pytorch.py`, the
  layout vLLM adopted AFTER our pin — the kernel-directory reorg (upstream
  `6af03f23`) landed on main ONE DAY after the v0.16.0 release branch was cut —
  so at `VLLM_REF=v0.16.0` that path has never existed. The script printed
  "skipping" and RETURNED 0 every time. Everything around it looked configured
  (/opt/fp8 cloned, trimmed and shipped; `PYTHONPATH=/opt/fp8` baked; the setting
  documented) and the feature was simply absent: on and off ran identical stock
  `torch._scaled_mm`.
  ⭐ NOT DRIFT — BORN BROKEN. The script and the pin have been byte-identical
  since the initial import. "It has always been this way" is evidence FOR a
  defect here, not against one.
  ✅ s61 part 2 re-points it to `vllm/model_executor/layers/quantization/kernels/
  scaled_mm/pytorch.py` (byte-identical to the file at the newer path, so this is
  a path fix and not a version jump) and replaces every quiet `return` with a
  guard: existence, refuse-twice, reachability against the sibling `__init__.py`
  kernel registry, exact counts before and after, and a `compile()` so a rewrite
  that does not parse cannot reach the wheel.
  ⚠️ STILL UNVALIDATED, AND EXPECT NO SPEEDUP YET. All three
  `output = torch._scaled_mm(` sites are routed (as leonyurko's own overlay does),
  but `TorchFP8ScaledMMLinearKernel.get_output_padding()` returns 17 under the
  `--enforce-eager` these kernels require, and vLLM pads the quantized activation
  to that many rows — so decode reaches the kernel at M=17 and the rows-mapped
  M==1 GEMV that carries the upstream win is unreachable. Overriding that is a
  change to vLLM's kernel-selection contract and is HELD as a separate,
  hardware-gated item.

---

## Targets (runtimes)

### targets/Container.comfyui
ComfyUI server on the unified ROCm base. Ported from the Fedora source and the
real upstream Dockerfile (submodule commit
`c2ef528b05e474491845fe27715315cec287d80c`), then reworked to the shared runtime
contract (bucket B).

- SINGLE image — NOT split build/runtime — because it keeps a compiler toolchain
  (gcc/g++/make/binutils/python3-dev) for Triton JIT AT RUNTIME.
- Server by default: `ENTRYPOINT` = the shared `droste-entrypoint.sh`, which
  applies `build-spec` (mounts, critical checks, template seeding, model-scanner
  PRE_LAUNCH) and execs ComfyUI on :8188; a user command still wins, and
  distrobox/toolbx replace pid1 and run the resolver from init_hooks instead.
  See "Runtime contract" above.
- FROM the TORCH base (canopy + de-divert + venv with the gfx1151 runtime
  kernels + the pinned torch). It adds torchvision/torchaudio pinned from the
  SAME index into the base venv. torch's own bundled ROCm coexists with the base
  runtime kernels — do NOT add a system ROCm SDK, and do NOT re-add
  `libnss-myhostname` (the base already provides it for distrobox).
- Pin nuance (**corrected s45 — the old text said they were "left blank in the pin
  (not yet locked)", which has been false for a while**): `TORCHVISION_VERSION` and
  `TORCHAUDIO_VERSION` ARE locked in `base/rocm-version.env`, on the same `+rocm`
  date as torch. The Containerfile keeps its `${TORCHVISION_VERSION:+==…}`
  conditional as a FALLBACK — when a field is empty it installs unpinned (`--pre`)
  so pip's resolver picks the wheel matching the pinned torch — but that is the
  degraded path, not the current one. `transformers` is pinned by the app; `gguf`
  floats.
- App deps + Triton runtime toolchain + pip. The base already ships
  python3-venv/pip, but pip is re-listed for explicitness.
  gcc/g++/make/binutils/python3-dev are the Triton JIT toolchain kept at runtime
  (this is why comfyui is not split). Since 2026-08-15 the torch base carries
  `gcc` + `python3.13-dev` of its own (Triton's GPU-init `hip_utils` compile —
  see `base/Container.torch`), so this list partly duplicates the base; kept
  verbatim, because only comfyui wants the FULL toolchain (g++/make/binutils)
  and the list should stay a self-contained statement of comfyui's needs. This
  port is also why comfyui was the one torch child NEVER bitten by that trap.
  Fedora translations: `ffmpeg-free`->
  `ffmpeg`, `libdrm-devel`->`libdrm2` (runtime, not `-dev`), `gcc-c++`->`g++`,
  `python3.13-devel`->`python3-dev`; `python3.13(-venv)` dropped (interpreter +
  venv already in the base).
- ComfyUI + 3 custom nodes (essentials, AMDGPUMonitor, GGUF): sha-pinned clones
  (`--depth=1` + fetch of the pinned ref), ARG `*_REF` overrideable. The three node
  pins are still the ones `c756385` set on 2026-07-05; `COMFYUI_REF` is the only
  one of the four that has moved since, to v0.33.3 at `5f73f76` (2026-08-22).
  The wan/qwen AMD "studios" (`QWEN_STUDIO_REF`/`WAN_STUDIO_REF`
  clones + their pip stacks) were DROPPED with the bucket-B rework — rationale
  in "Per-port notes (bucket-B rework rationale)" above.
- The 11 baked SD/SD2 config yamls are moved OUT of `models/` to
  `/opt/resources/model_configs/` (the runtime model-tree bind replaces
  `models/`); they register back via the seeded `extra_model_paths.yaml`.
- Runtime-contract assets: helper scripts (get_*.sh downloaders,
  benchmark/perf helpers, model_manager, model_scanner) baked RO at
  `/opt/resources/scripts/` (PATH + PYTHONPATH); API-format workflows at
  `/opt/resources/api_workflows/`; `build-spec` + `templates/` (demo inputs, UI
  workflow set, extra_model_paths.yaml, /opt/models marker body) baked under
  `/opt/resources/`. The baked `user/` ships EMPTY (surfaced from
  `/opt/data/user`, seeded if_empty).
- Interactive login-shell wiring (see cross-cutting): adds torch/AOTriton env,
  the login banner, a PATH-last guard, and core-dump suppression; the Fedora
  `venv.sh` is intentionally NOT ported (base already writes rocm.sh).

### targets/Container.ds4
The shippable ds4 toolbox. FROM the runtime base + ds4's compiled outputs COPY'd
from the ds4-artifacts carrier. FIRST of the five ports — sets the runtime
pattern the other four copy. Layers only ds4's binaries + the huggingface CLI +
the ds4 cockpit TUI; re-adds NO ROCm libs (hipblaslt included — the runtime
kernels already live in the base).

- Pinned cockpit ref (reproducibility): default = strix-halo-ds4-toolbox submodule
  HEAD (`git -C upstream/ds4 rev-parse HEAD`); the cockpit pip package is the
  repo's subdirectory.
- Seam: `bin` -> `/usr/local/bin`, `lib64` -> `/usr/local/lib64`. `share` is
  carried for pattern parity (empty for ds4 today).
- Make ds4's shared libs resolvable without touching env (mirrors the Fedora
  runtime's `local.conf`): the base already wires `/opt/rocm/lib{,64}`; this adds
  the COPY'd `/usr/local/lib{,64}` via `ds4-local.conf` + `ldconfig`.
- App-level Python runtime into the base venv: huggingface CLI for model
  downloads (the `hf_xet` extra flips on `HF_XET_HIGH_PERFORMANCE=1`).
  `python3-pip` is NOT re-added — the runtime base already installs it, and `pip`
  here is the venv pip (PEP668-safe).
- ds4 cockpit TUI from the PINNED git ref, isolated via `pipx --global`: `git` is
  a genuinely-missing runtime dep here (canopy/runtime-base ship none) and is
  required to resolve the `git+https` spec — added minimally. pipx is
  pip-installed into the base venv, then invoked with `--global` so the cockpit
  gets its OWN isolated venv at `/opt/pipx` and its launcher at
  `/usr/local/bin/ds4-cockpit` — both container-owned (NOT the distrobox-shared
  host `~/.local`, which `PYTHONNOUSERSITE` also guards against). Mirrors droste's
  kento `pipx install --global`.
- Server by default: `ENTRYPOINT` = the shared `droste-entrypoint.sh` (build-spec:
  whole-`~/.ds4` surface, HF-cache CRITICAL, `ds4.cfg` seeding, the
  `DROSTE_DS4_*` → argv translation in PRE_LAUNCH, then execs `ds4-server`);
  distrobox/toolbx override the entrypoint for the interactive lane. The
  upstream `download_model.sh` is REMOVED from `/usr/local/bin` (superseded by
  the cache-native rework at `/opt/resources/scripts/`); `PYTHONNOUSERSITE=1` +
  helper scripts on PATH. See "Runtime contract" above.

### targets/Container.finetuning
The shippable LLM-finetuning toolbox — torch + HF/unsloth stack on the gfx1151
runtime kernels, with the compiled bitsandbytes + custom RCCL COPY'd from the
finetuning-artifacts carrier. JupyterLab server by default (shared
`droste-entrypoint.sh`, :8888; distrobox/toolbx override it for the interactive
lane), NOT a minimal service image. Translated from the upstream single-stage
Dockerfile
(`github.com/kyuz0/amd-strix-halo-llm-finetuning @
093a23c0d49418aef08e5053aa19faf65b35236a`).

Deliberate upstream deltas:
- `/opt/rocm-7.0` TheRock S3 tarball DROPPED — runtime kernels come from the base
  (`rocm-sdk-libraries-gfx1151` in `/opt/venv`, `ROCM_PATH=/opt/rocm`).
- torch is installed from the UNIFIED pin, ABI-matched to the runtime kernels,
  replacing upstream's v2-staging `--pre torch torchaudio torchvision`.
- The upstream `librocm_smi64` overwrite hack is DROPPED: torch and
  rocm-sdk-libraries share the same `+rocm` date here, so there is no SMI symbol
  mismatch to patch. Likewise the Fedora `LD_PRELOAD=libtcmalloc_minimal.so.4:
  …/librocm_smi64` line is dropped (gperftools/tcmalloc is not installed; base
  `profile.d/rocm.sh` + the triton env script provide the runtime env).
- bitsandbytes + RCCL are COPY'd from finetuning-artifacts instead of built
  inline.
- Clone pins (this FLAG closed at `c756385`, 2026-07-05): `FLASH_ATTENTION_REF` is
  `3f94643f…` off ROCm/flash-attention `main_perf` — the same sha the vllm carrier
  pins — and is no longer a moving branch head.
  `UNSLOTH_REF` is a fixed commit (upstream-chosen, Jan 31) + PR 4109 (RDNA
  fixes) applied on top; `unsloth_zoo` is version-pinned to match it. Do NOT bump
  unsloth without re-checking the `unsloth_zoo` pin (newer zoo drops
  `sanitize_logprob` / `device_synchronize` the commit relies on).
- Toolchain for the source installs (clone + patch); canopy ships none. git/curl
  clone flash-attention + unsloth and fetch the unsloth PR diff; `patch` applies
  it. Kept small — the HF wheels + flash-attn (Triton backend) + unsloth are
  pure-Python/prebuilt, so nothing in THIS image's apt layer compiles anything.
  At RUN time it is a different story: triton (which rides torch) compiles its
  own `hip_utils` helper on the first GPU-driver init, and on hardware
  2026-08-15 this image reproduced the vllm failure verbatim — `RuntimeError:
  Failed to find C compiler`, then `fatal error: Python.h: No such file or
  directory` — cured by `gcc` + `python3.13-dev` and verified through a full
  triton JIT kernel launch (printed `True`). That pair now comes from the torch
  base, installed once for both bitten children; see `base/Container.torch`.
  It is the second confirmation that the trap is the torch stack's, not vllm's.
- bitsandbytes: install the gfx1151 wheel (`--no-deps` — torch already present),
  then apply the upstream version-parse fixup — bitsandbytes searches fixed
  fallback names (`rocm7.12` / `rocm82`) that won't match our built lib's name,
  so symlink the real `.so` to those names.
- Custom RCCL: overwrite the SDK's stock librccl (both the `/opt/rocm` view and
  the real file(s) under the venv's `_rocm_sdk_libraries_gfx1151`). find-based so
  it's robust to the exact path.
- HF finetuning stack: pins carried verbatim from upstream. `datasets` added
  explicitly (needed by the training notebooks; otherwise transitive).
  `unsloth_zoo`/`tqdm`/`ipywidgets`/`ipykernel`/`traitlets`/`jupyter_core` pinned
  to match the checked-out unsloth commit (see `UNSLOTH_REF`).
- Flash-Attention (ROCm Triton backend): the Triton AMD backend flag
  (`FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE`) MUST be set at build time so
  `setup.py` skips the CUDA C++ extension and installs the pure-Python/Triton
  path (no nvcc, no host compiler needed).
- Unsloth: pinned commit + PR 4109 RDNA fixes.
- Runtime env scripts (profile.d): `01-rocm-env-for-triton.sh` derives Triton HIP
  lld/clang paths from `_rocm_sdk_core` + sets the flash-attn Triton flag;
  `99-toolbox-banner.sh` login banner; `zz-venv-last.sh` keeps `/opt/venv/bin`
  first on PATH.
- Jupyter kernel points at the venv python; friendly display name (upstream
  parity).

### targets/Container.llama
Thin gfx1151 llama.cpp toolbox on the runtime base. `COPY --from` the
llama-artifacts carrier (bins + libllama*.so + vram helper) onto the runtime
kernels the base carries — NO ROCm re-adds. The base already writes a real
`/etc/profile.d/rocm.sh`, so the upstream empty-profile bug does not apply.

- `libgomp1`: llama-server links `libgomp.so.1` (OpenMP); the lean runtime base
  doesn't carry it, so the binary fails at load with
  `libgomp.so.1: cannot open shared object file`. Verified on gfx1151 hardware
  2026-07-06.
- Drop llama.cpp's outputs onto the runtime: bins -> `/usr/local/bin`, libllama/
  libggml -> `/usr/local/lib64`, vram helper -> `/usr/local/bin` (executable).
  `/usr/local/lib{,64}` are already on the base's ld path via `rocm.conf` — add
  `local.conf` + `ldconfig` to be sure.
- Server by default: `ENTRYPOINT` = the shared `droste-entrypoint.sh` (build-spec:
  HF-cache CRITICAL, `llama.cfg` seeding + `set -a` source, SERVICE rebuilt in
  PRE_LAUNCH with `$DROSTE_LLAMA_EXTRA_ARGS`, then execs `llama-server`); distrobox/
  toolbx override the entrypoint for the interactive lane. `llama.cfg` is
  hand-authored and seeded from `targets/llama/templates/`; a build-time scan
  still fails if the active `LLAMA_ARG_*` names vanish upstream. See
  "Runtime contract" above.

### targets/Container.vllm
The shippable vLLM toolbox for Strix Halo / gfx1151. FROM the runtime base + the
pinned TheRock torch, then `COPY --from` the flash-attention/aiter/vLLM wheels
compiled in vllm-artifacts and pip-install them into the base venv. No ROCm
`-dev`, no C++ toolchain, and nothing compiler-shaped added HERE — the bare
`gcc` + `python3.13-dev` this image does rely on at serve time arrive from the
torch base (Triton's `hip_utils` compile; see `base/Container.torch`).
Toolbox submodule provenance (droste-ai-halo):
`6446b9595273f289e11586c3c7d3e1e6f2945888`.

- Torch (pinned TheRock nightly) into the base venv — must match the torch the
  wheels were compiled against (same pin). Installed FIRST so the vLLM wheel's
  torch requirement is already satisfied and pip does NOT pull a PyPI/CUDA torch
  over it. FLAG: if current vLLM main pins an exact torch that 2.9.1 doesn't
  satisfy, pip will try to replace it — reconcile on-host.
- Legacy resolver + `pip check`: the vLLM wheel was installed under
  `PIP_USE_DEPRECATED=legacy-resolver` until s46 (pip's resolvelib backtracker dies
  with RecursionError over the `torch==2.9.1` vs `2.9.1+rocm…` pin; uv resolves the
  same graph in seconds, which is what retired the flag — see the uv-migration entry
  above. The wheel installs with `uv pip install` now). The legacy
  resolver took the first satisfying candidate and never backtracked, so an
  upper bound owned by an EARLIER-resolved package was dropped silently. That
  shipped a broken image once: transformers requires
  `tokenizers>=0.22.0,<=0.23.0`, the build took PyPI's newer 0.23.1, pip
  reported success, and `vllm` then failed at IMPORT — the server could not
  start at all (found on hardware 2026-08-12, the first time the vLLM lane was
  ever run). CI never caught it because **build success is not import success**
  and no job imports vllm. Hence the explicit `tokenizers` range install plus a
  `pip check` gate that fails the BUILD on any NEW inconsistent set. The gate is
  ALLOWLIST-BASED, not bare: this env carries five known pre-existing conflicts
  (upstream pins the wheel set outruns — grpcio/grpcio-reflection/protobuf/
  numpy/setuptools), so a bare `pip check` is a permanent break. The gate prints
  the full raw output, filters exactly the five known lines (matched on package
  pair + bound direction, never installed versions), and fails on anything that
  survives. It has caught real drift already: the amd-aiter nightly grew a
  runtime `pybind11` dependency overnight (2026-08-13) — fixed by installing it,
  since satisfiable conflicts get pinned/installed and ONLY
  unsatisfiable-by-construction ones get allowlisted with a rationale. FLAG:
  when the gate goes red, read what it names; do not remove the check.
- Explicitly-installed runtime deps upstream leaves out (all satisfiable, so
  INSTALLED, never allowlisted): `pybind11` (aiter's JIT, gate-caught 2026-08-13)
  and `pycountry` (hardware 2026-08-14: vllm -> gguf_utils -> gguf ->
  mistral_common -> pydantic-extra-types' `language_code`, which imports
  pycountry unconditionally while upstream ships it only as an extra —
  `RuntimeError: The language_code module requires "pycountry"` at serve time).
  Note the gate CANNOT catch the pycountry class: `pip check` audits declared
  metadata, and an extras-gated import declares nothing. Only running the thing
  finds those.
- torchvision re-pin (the sixth allowlist entry, RETIRED 2026-08-14): the vLLM
  wheel's deps pull `timm`, whose bare `torchvision` dep resolved from PyPI to
  0.28.0 — built against torch 2.13.0, so its C++ ops never registered against
  our 2.9.1+rocm and `vllm serve` died at startup with `RuntimeError: operator
  torchvision::nms does not exist` (hardware 2026-08-14; the second build-green,
  import-broken image, same lesson as tokenizers). Fix: after every install in
  that RUN, `uv pip install --no-deps --reinstall-package torchvision --index-url
  ${ROCM_INDEX_URL} "torchvision==${TORCHVISION_VERSION}"` (`pip install --no-deps
  --force-reinstall …` until s46 moved the RUN to uv) — same index + `+rocm`
  date as torch, so the pair is ABI-matched by construction (the pin file has
  owned `TORCHVISION_VERSION` all along; that `RUN` sources
  `/etc/droste/rocm-version.env`, so it reads the same date its own torch base
  was built from — no build-arg to forget).
  The ROCm torchvision wheel requires only a bare `torch`, and nothing bounds
  torchvision from below, so the old `torchvision … requires torch==…` allowlist
  line is gone with NO replacement: torchvision must now be silent in `pip
  check`, and any line naming it means the re-pin regressed.
- Prebuilt aiter JIT module + import smoke test (2026-08-14, the third layer of
  the same onion): vLLM inspects a model's architecture -> `import flash_attn`
  -> `import aiter` -> `aiter/ops/enum.py` JIT-compiles `module_aiter_enum`.
  This image ships NO C++ compiler by design (and shipped no compiler at all
  until the torch base gained `gcc`), so `shutil.which("c++")` returned None
  and blew up in `check_compiler_ok_for_platform` (`TypeError: expected str,
  bytes or os.PathLike object, not NoneType`) -> `RuntimeError: [aiter] build
  [module_aiter_enum] ... failed` -> pydantic `Model architectures
  ['Qwen2ForCausalLM'] failed to be inspected` -> server exits. Fix: the
  artifacts stage prebuilds the `.so` (see vllm-build above) and this image
  `cp`s it into `site-packages/aiter/jit/` right after the aiter wheel install,
  where aiter's `get_module` imports it as `aiter.jit.module_aiter_enum` and
  never reaches the compiler probe. It lands in the BAKED venv — the overlay
  lower layer — so a user's venv copy-up cannot shadow it. Deliberately NOT
  fixed by adding a C++ compiler to the runtime: the C++/hipcc toolchain
  belongs to the build images (comfyui is the sole exception, for Triton JIT).
  The bare `gcc` the torch base gained on 2026-08-15 does not weaken this —
  `gcc` ships no `c++`, so aiter's probe still finds nothing. The new
  `RUN python -c "import aiter"` is the durable half: it is the first thing in
  CI that imports any of this stack, it needs no GPU (aiter falls back to arch
  "cpu" when `rocminfo` finds nothing), and it fails the build if the prebuilt
  module is missing — the gap that let three import-broken images ship green.
- Triton's serve-time C compile — found HERE (hardware 2026-08-15: `vllm serve`
  died with `RuntimeError: Failed to find C compiler`, then with `fatal error:
  Python.h: No such file or directory`), FIXED in the torch base. The trigger
  rides the torch stack, not this port, and finetuning reproduced it verbatim
  the same day, so `gcc` + `python3.13-dev` are installed once in
  `base/Container.torch` — full write-up in that section. Nothing about it is
  vllm-specific EXCEPT the g++ half: the base ships `gcc` and no `c++`
  precisely so the prebuilt `module_aiter_enum.so` above stays load-bearing —
  aiter's probe is `shutil.which("c++")`, and it must keep finding nothing.
  The generalisation: **build != import != serve**, and CI can only ever reach
  the first two.
- Runtime libs: `libnuma` (vLLM numa lookup on `import vllm`) + `libgomp1` —
  torch links `libgomp.so.1` (OpenMP), which the lean runtime base does NOT
  carry, so `import torch` (and thus `import vllm`) fails without it. Verified on
  gfx1151 hardware 2026-07-06. Plus `git` (2026-08-14): aiter's
  `csrc/cpp_itfs/utils.py` runs `git rev-parse --short HEAD` at MODULE level on
  every `import aiter` and catches only `CalledProcessError`, so a missing binary
  is a hard `FileNotFoundError` (git present but no repo — our case — is fine).
  This port only: no other image installs aiter. NB finetuning's flash-attn does
  `from aiter.ops.triton... import ...` when `FLASH_ATTENTION_TRITON_AMD_ENABLE`
  is TRUE (it is), but its install_requires for the triton backend is only
  einops+triton, so no aiter is installed there — worth a look on hardware, but
  not this batch.
- The full kit a RUNTIME aiter JIT would need, measured in the box while
  debugging: g++, python3-dev, `HIP_DEVICE_LIB_PATH` pointing into the pip SDK's
  `lib/llvm/amdgcn/bitcode`, `LIBRARY_PATH` plus a hand-made
  `libamdhip64.so -> libamdhip64.so.7` symlink (the pip SDK ships only the
  versioned lib), and git. That is a build image, not a runtime — which is the
  argument for prebuilding the one module the import path needs.
- Prebuilt wheels + the pure-python FP8 kernel tree come from vllm-artifacts.
- Runtime shell env + banner (upstream ships in `/etc/profile.d`):
  `01-rocm-env-for-triton.sh` sets the gfx1151/Triton/vLLM serve-time env;
  `99-toolbox-banner.sh` prints the banner; `zz-venv-last.sh` keeps
  `/opt/venv/bin` first on PATH under distrobox user dotfiles.
- FP8 shim: `patch_fp8_kernels.py` (baked into the vLLM wheel) imports
  `fp8_triton` from `/opt/fp8` at serve time when `VLLM_STRIX_FP8_TRITON=1`. Also
  mirror the Triton/vLLM env into the image env (`PYTHONPATH=/opt/fp8`, etc.) so
  non-login shells (podman exec, distrobox) get it without sourcing
  `/etc/profile.d`.
  🚨 THE CARRIER HALF WAS ALWAYS FINE AND THE SHIM HALF WAS ALWAYS ABSENT. The
  clone, the trim, the COPY and `PYTHONPATH` all worked; the patch that puts a
  call to `fp8_triton` into the wheel targeted a path that does not exist at our
  pin, so no build before s61 part 2 shipped a shim at all. Re-pointed and
  guarded in s61 part 2; still unvalidated on hardware, and no decode win is
  expected until the output-padding gate is addressed (see the FP8 bullet in the
  vllm-build section).
- Startup-log noise, known and COSMETIC — `Op 'sparse_attn_indexer' not present
  in model, enabling with '+sparse_attn_indexer' has no effect` is UPSTREAM's
  own ROCm default, not ours (2026-08-14; nothing in this repo touches
  `custom_ops` except `patch_strix.py`'s gfx1x `+rms_norm` bypass). vLLM's
  `RocmPlatform.apply_config_platform_defaults` appends `+sparse_attn_indexer`
  to `compilation_config.custom_ops` UNCONDITIONALLY — at our `VLLM_REF=v0.16.0`
  pin that is `vllm/platforms/rocm.py:566-567` ("Default dispatch to rocm's
  sparse_attn_indexer implementation"), still unconditional on `main` — and
  `CompilationConfig.custom_op_log_check` (`vllm/config/compilation.py:1092` at
  the same pin) then warns for every listed op the LOADED model does not define.
  The op is part of the DeepSeek V3.2 sparse-attention path, so every other model
  logs it. It is `warning_once` with zero functional effect; do NOT try to strip
  it via config (a user `-sparse_attn_indexer` does not suppress the append —
  unlike `grouped_topk` just above, the sparse line is not guarded), and do not
  add a `patch_strix.py` patch for a log line. Revisit only if upstream makes it
  conditional.
