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

### Reproducibility FLAG (recurring known issue)
- Several source clones default to a moving upstream branch HEAD. Each carries a
  `*_REF` ARG so a fixed sha/tag can be pinned at build time. These were pinned
  `2026-07-05`, but the notes repeatedly FLAG that they must be sha-pinned
  on-host for a truly reproducible release — the provenance sha in a header pins
  only the toolbox repo, not the upstream app/library repos.

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
- `droste-entrypoint.sh` — the server-lane ENTRYPOINT for every port. Sources the
  library + the port's `/opt/resources/build-spec`, runs `resolve::apply_spec` in
  the fixed design order (ensure `/opt/data` → SURFACES/OVERLAYS/CACHES → CRITICAL
  → OPTIONAL → templates → ENV_FILE → PRE_LAUNCH), then execs SERVICE — unless the
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
  merged one-container shape). maybe_launch reads `/opt/data/server.env`
  (`SERVE=1`, `PORT=<host port>`; shell-sourceable, read in a subshell so a bad
  file can never fail the box), rewrites the port into the SERVICE argv
  (replace-or-append `--port` — all five services take it), and starts the service
  in the background as the BOX USER via `setpriv --reuid/--regid` (supplementary
  groups inherited, so the GPU device groups survive; runuser/su would not).
  Re-entrant by construction: a pid file on the data volume records
  pid + process start time + a per-container-start token, so a re-run of the init
  line adopts, skips or replaces the previous instance instead of double-starting.
  **The server lane never reads server.env** — its ports are podman-published
  `HOST:CONTAINER` remaps, so rewriting the in-container bind would break them.
- `droste-healthcheck.sh` — the container-side probe for
  `--health-cmd` + `--health-on-failure=restart` (wired by droste-setup.sh at create
  time; the images bake NO `HEALTHCHECK`). Reads the same server.env for PORT and
  the build-spec's `HEALTH_PATH`/`HEALTH_ACCEPT` rows: comfyui `/`, llama `/health`,
  vllm `/health`, finetuning `/` with `accept=any` (jupyter only ever answers 302/403
  unauthenticated), ds4 `/v1/models` (source-verified: ds4-server has no `/health`
  and 404s `/`). A box with serving off is healthy by definition. `--health-start-period`
  MUST cover model load or the box restart-loops.
- **`is_bound` is an ancestor-walk**, not an exact mountinfo match: the longest
  component-aware mount-point prefix of the target decides (rootfs `/` → unbound;
  anything deeper → bound). Needed because distrobox binds the whole `$HOME` —
  an exact match would false-error every critical living under it.
- **`ENV_FILE` is sourced under `set -a`** so plain `VAR=` lines are exported and
  survive the exec into the service (llama-server reads `LLAMA_ARG_*` from its
  environment). llama/ds4 keep belt-and-braces export loops in PRE_LAUNCH so their
  specs stay self-sufficient under other callers.
- **The SERVICE-rebuild pattern:** build-spec is sourced bash, so `SERVICE=( … )`
  expands BEFORE ENV_FILE is sourced. Ports whose argv depends on env-file values
  (llama `$LLAMA_EXTRA_ARGS`, ds4's flag translation) declare a placeholder argv
  and rebuild `SERVICE` inside PRE_LAUNCH, which runs after ENV_FILE. Documented
  in `base/resolve/build-spec.example`.

### build-spec (the per-port declaration)
One sourced-bash file per port (`targets/<port>/build-spec`, baked at
`/opt/resources/build-spec`; the name is a placeholder pending a rename). Rows:
`SERVICE / ENV_FILE / OVERLAYS / SURFACES / CACHES / CRITICAL / OPTIONAL /
PRE_LAUNCH` — all paths explicit + absolute (`$HOME` allowed and preferred for
home-relative paths: it is the only form correct in BOTH lanes). SURFACES and
CACHES are structurally identical binds kept as separate rows by design (future
cache-specific behaviour — which arrived in v0.2.0, when CACHES retargeted to
the shared `/opt/caches` volume; see the 2026-07-09 shared compute-cache
entry). There is deliberately no DEFAULTS row — ALL content
seeding is owned by templates.yaml. Contract doc: `base/resolve/build-spec.example`.

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

### Model classification: signals and confidence
`model_scanner.py` classifies by a ladder, but the evidence it uses is not all
worth the same, and the registry now records how well-supported each answer is.

Evidence splits in two. **Embedded** signals live inside the weight file —
safetensors header, GGUF KV block, pickle opcodes — and cannot be changed
without rewriting the model. **Low-fidelity (LoFi)** signals live outside it:
sidecar files (`config.json`, `model_index.json`, CT2 vocabulary siblings) and
names (path segments, filename, repo name). Sidecars are independently
editable and *are* edited — someone forcing a class name to make a loader
accept a file produces a sidecar that points confidently at the wrong answer,
which is worse than no sidecar at all. LoFi ratings are therefore capped at
0.6: they may hint, never certify. The naming signals are also **not
independent** of each other — a mislabelled file usually has a matching bad
path and repo — so their unanimity is worth about as much as one of them.

Each applicable measure votes with a rating; scores are computed **per
candidate category** (`Σ(parts × rating) ÷ Σ applicable parts`), since measures
vote for different answers and a pooled sum would only say how much evidence
exists. Parts: safetensors 30, pickle 20, GGUF 20, each LoFi measure 5. All six
LoFi agreeing reaches 18, while any single embedded measure at ≥0.9 reaches
18–29.7 — confident embedded evidence always wins, and names decide only where
embedded evidence is weak or absent.

The ladder still picks the recorded category; the score only describes it and
flags disagreement as **DISPUTED**, the companion report to UNCLASSIFIED.
Misclassification hides precisely where UNCLASSIFIED cannot look, because those
files appear settled.

`.pt`/`.pth`/`.ckpt`/`.bin` are content-sniffed via `read_pickle_signals`, which
**never executes the payload**: `find_class` imports nothing, returning an inert
stub and recording the module path — itself the strongest signal for
object-pickles like Ultralytics detectors, which carry no tensor keys at all.
Only the pickle *structure* is read (the zip's `data.pkl`, or up to the legacy
format's STOP opcode), so cost is bounded regardless of file size. State-dict
keys reuse the safetensors classifier rather than growing parallel prefix rules.

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
  `6446b9595273f289e11586c3c7d3e1e6f2945888` (`targets/vllm/upstream/models.py`)
  and `vllm_config.yaml` is GENERATED AT IMAGE BUILD from it
  (`scripts/gen_vllm_config.py`) — hermetic, and upstream drift is visible as a
  vendored-file diff, not a silent build change. The generated config carries
  `host:` but deliberately NO `port:` key (2026-08-14): the launcher owns the
  listen port (`droste-serve.sh::serve::apply_port` appends `--port $PORT` from
  server.env), and setting it in both places made vLLM log `Found duplicate keys
  --port` at every start. `VLLM_NO_USAGE_STATS=1` is baked
  instead of persisting `~/.config/vllm` (do-not-track > carrying state). The
  `cache/vllm` bind IS present (owner decision 2026-07-09, resolving the old
  VERIFY-at-test note that had it omitted): `~/.cache/vllm` — vLLM's
  compile/artifact cache — joins the shared compute-cache store under the
  v0.2.0 cache policy. `/opt/fp8` is trimmed to the runtime import surface
  (top-level `*.py` + LICENSE/NOTICE + `licenses/` kept for compliance; bench/
  docs/serve scripts dropped).
- **llama** — `llama.env` is BUILD-generated from the pinned llama-server's own
  arg table (`scripts/gen_llama_env.sh`: `--help` parse with a binary-string-scan
  fallback), so the commented flag list can't drift from the pinned binary; the
  build FAILS LOUDLY if `LLAMA_ARG_{HOST,PORT,MODEL}` vanish upstream.
  `LLAMA_ARG_PORT` is emitted COMMENTED, not active (2026-08-14, same rule as
  vllm's missing `port:` key): the launcher appends `--port $PORT` from
  server.env and llama.cpp silently resolves the CLI flag over the env var, so
  an active line here would look authoritative and do nothing. It stays in the
  generator's `REQUIRED_VARS` drift gate regardless — that gate checks the
  PINNED BINARY's arg table, not what the template emits active.
  `LLAMA_CACHE` is deliberately UNSET — it is first in llama.cpp's
  cache-path resolution and setting it would re-separate the shared HF cache.
  Slot save/restore: the pinned fork ships `--slot-save-path` with NO env
  annotation (verified by the first CI run failing loudly, as designed), so
  the entrypoint launch line passes `--slot-save-path /opt/data/slots`
  (user override = own flag in LLAMA_EXTRA_ARGS; later flags win); the dir is
  pre-created in PRE_LAUNCH.
- **ds4** — ds4 has no native per-flag env vars, so PRE_LAUNCH translates
  `DS4_DROSTE_*` → argv (arity source-verified against pinned kyuz0/ds4
  `@00e64ea`); NATIVE `DS4_*` vars (DS4_THREADS, …) pass through untouched — the
  binary reads them itself. `DS4_DROSTE_PORT` is deliberately NOT among the
  seeded active lines (2026-08-14, same rule as vllm/llama): `apply_port` would
  overwrite the `--port` it produces with server.env's `PORT` anyway, so the
  template carries only a comment pointing at server.env. Backend shorthands
  (`--rocm`/`--cpu`/…) and the distributed/multi-node flags are left to
  `DS4_DROSTE_EXTRA_ARGS`. The whole `~/.ds4` (kvcache sessions + browser
  profile) is surfaced from `/opt/data/ds4`
  (sessions are user WORK, top-level, not cache/); the cockpit conf is a FILE, so
  it persists via symlink `~/.ds4-cockpit.conf → /opt/data/cockpit/…`.
  `download_model.sh` was reworked cache-native (`hf download` into the shared HF
  cache, prints the snapshot path for `DS4_DROSTE_MODEL`); the upstream copy is
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

### 2026-07-09 — shared compute-cache volume (`/opt/caches`, folded into v0.2.0)

Decision (Jei, 2026-07-09): the compute caches (MIOpen / Triton / torch-hub)
move from per-box `/opt/data/cache` to ONE shared volume, bound at
`/opt/caches` in every container and box (host default `~/droste/caches`,
user-overridable). Rationale, his: "easier to make the caches all shared,
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

---

## Host adopt tooling — scripts/droste-hf-adopt.sh / scripts/droste-civitai-adopt.sh

The two adopt tools under `scripts/` move already-downloaded model files into the
shared stores the containers mount — the HF hub cache, and a webui-style
CivitAI tree suited to the `/opt/models` bind. Both are host-side,
stdlib-only, dry-run by default. The design rationale:

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
  `--repo` (HF) the search API only proposes candidate repos — the published
  hashes decide; a CivitAI `--version-id` (the escape hatch for old uploads
  CivitAI never hashed) is accepted only if our sha256 appears in that
  version's file list. Refused files are not failures to fix by hand-placing
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
`. /etc/droste/rocm-version.env && pip install torch==$TORCH_VERSION`
from the gfx1151 index — nothing else. The three Python targets (comfyui, vllm,
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
- Pinned refs (never float HEAD): `DS4_REF` default = branch `rocm-multi-node`
  (matches upstream — the Fedora source built kyuz0/ds4's rocm-multi-node
  branch). NOTE: the earlier `84a580d8…` default was the
  strix-halo-ds4-toolbox HEAD — a DIFFERENT repo, wrong for the ds4 app; it
  remains correct as `COCKPIT_REF` in ds4-runtime, which is the toolbox repo.
- `ROCWMMA_REF`: upstream used branch `release/rocm-rel-7.2`, kept as default,
  but our SDK is now `7.13.0a` (TheRock nightly) — rocWMMA-vs-SDK version
  alignment needs an on-host build test. Pin to a SHA once a known-good commit is
  confirmed on-host.
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
- Clone-pin FLAG (on-host): `BITSANDBYTES_REF` (bitsandbytes-foundation/
  bitsandbytes @ `main`, ROCm v0.46.1+) and `RCCL_REPO`/`RCCL_REF`
  (kyuz0/rocm-systems @ branch `gfx1151-rccl`, a moving branch head) float
  upstream and must get immutable sha pins before a reproducible release.
- Pinned torch into the build venv: bitsandbytes' hip build/packaging detects the
  installed ROCm (and, for the runtime lib name, the torch/ROCm version) via the
  same interpreter it ships for. Thrown away with the builder stage — only the
  wheel + librccl reach the carrier.
- Carrier layout mirrors the other ports: `wheels/` for pip-installables,
  `lib64/` for raw `.so`.
- PEP517 build backends: bitsandbytes `main` uses
  `scikit_build_core.setuptools.build_meta`, and `pip wheel
  --no-build-isolation` requires the backend importable in the venv already
  (torch does not pull it) — hence the `scikit-build-core setuptools wheel`
  upgrade.
- `libdrm-dev`: RCCL's rocm_smi headers include `<libdrm/drm.h>`, and torch's
  `LoadHIP.cmake` runs `pkg_check_modules(libdrm)` via `rocm_smi-config.cmake`.
  Provides the headers + `libdrm.pc` (the build base ships neither).
- bitsandbytes (ROCm/hip): in-source cmake (`COMPUTE_BACKEND=hip`) emits
  `libbitsandbytes_rocm*.so` into the package tree; `pip wheel` then bundles that
  prebuilt `.so`. OpenMP: `find_package(OpenMP)` resolves Debian's `libomp-dev`
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
- The consumed asset (`llama-grammar.patch`) lives alongside the Containerfile
  (copied from the upstream toolbox submodule so the build context is
  self-contained). It patches relative to the repo root (`-p1`).
- The shallow fetch brings no submodules, so materialize them after the
  checkout (`git submodule update --init --recursive`).
- Apply the turboquant grammar patch: `llama-grammar.patch` raises
  `MAX_REPETITION_THRESHOLD` for complex tool schemas. This is the ONLY patch
  upstream's turboquant Dockerfile applies.
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
  pinned 2.9.1. flash-attention still floats `main_perf` — FLAG: pin
  `FLASH_ATTENTION_REF` to a ~Feb-2026 (v0.16.0-era) sha on-host for
  reproducibility (a flash-attn sha transitively pins its aiter +
  composable_kernel submodules via the gitlink). FP8 kernels are pinned to
  upstream's default.
- Torch (pinned TheRock nightly) into the base venv: vLLM + flash-attn + aiter all
  compile their C++/HIP extensions against this torch's headers/ABI. FLAG: the
  pin's `TORCHVISION_VERSION`/`TORCHAUDIO_VERSION` are unset — vLLM multimodal
  paths may want torchvision; add them once locked on the same `+rocm` date.
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
  FP8 Triton dequant-GEMM shim).
- Build the vLLM wheel with the ROCm clang host compiler (ABI-aligns vLLM's C++
  extensions with torch — avoids the GCC-host segfault). NOTE the SDK layout
  difference: pip TheRock ships clang under `/opt/rocm/lib/llvm/bin` (Fedora
  tarball used `/opt/rocm/llvm/bin`).
- Pure-python FP8 Triton kernels (leonyurko): NOT a wheel — the modules live on
  `PYTHONPATH` at serve time (`patch_fp8_kernels.py`'s shim does
  `from fp8_triton import fp8_gemm`, opt-in via `VLLM_STRIX_FP8_TRITON=1`).
  Carried as a source tree; vllm-runtime `COPY`s it to `/opt/fp8`.

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
- Pin nuance: `TORCHVISION`/`TORCHAUDIO` are left blank in the pin (not yet
  locked) — when empty, install them unpinned (`--pre`) so pip's resolver picks
  the wheel matching the pinned torch on the same `+rocm` date. `transformers` is
  pinned by the app; `gguf` floats.
- App deps + Triton runtime toolchain + pip. The base already ships
  python3-venv/pip, but pip is re-listed for explicitness.
  gcc/g++/make/binutils/python3-dev are the Triton JIT toolchain kept at runtime
  (this is why comfyui is not split). Fedora translations: `ffmpeg-free`->
  `ffmpeg`, `libdrm-devel`->`libdrm2` (runtime, not `-dev`), `gcc-c++`->`g++`,
  `python3.13-devel`->`python3-dev`; `python3.13(-venv)` dropped (interpreter +
  venv already in the base).
- ComfyUI + 3 custom nodes (essentials, AMDGPUMonitor, GGUF): sha-pinned clones
  (`--depth=1` + fetch of the pinned ref), ARG `*_REF` overrideable (pinned
  2026-07-05). The wan/qwen AMD "studios" (`QWEN_STUDIO_REF`/`WAN_STUDIO_REF`
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
  whole-`~/.ds4` surface, HF-cache CRITICAL, `ds4.env` seeding, the
  `DS4_DROSTE_*` → argv translation in PRE_LAUNCH, then execs `ds4-server`);
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
- Clone-pin FLAG (on-host): `FLASH_ATTENTION_REPO`/`REF` (ROCm/flash-attention @
  `main_perf`, a moving branch head) floats and must get a sha pin.
  `UNSLOTH_REF` is a fixed commit (upstream-chosen, Jan 31) + PR 4109 (RDNA
  fixes) applied on top; `unsloth_zoo` is version-pinned to match it. Do NOT bump
  unsloth without re-checking the `unsloth_zoo` pin (newer zoo drops
  `sanitize_logprob` / `device_synchronize` the commit relies on).
- Toolchain for the source installs (clone + patch); canopy ships none. git/curl
  clone flash-attention + unsloth and fetch the unsloth PR diff; `patch` applies
  it. Kept small — the HF wheels + flash-attn (Triton backend) + unsloth are
  pure-Python/prebuilt, no C toolchain.
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
  HF-cache CRITICAL, `llama.env` seeding + `set -a` source, SERVICE rebuilt in
  PRE_LAUNCH with `$LLAMA_EXTRA_ARGS`, then execs `llama-server`); distrobox/
  toolbx override the entrypoint for the interactive lane. `llama.env` is
  BUILD-generated by `gen_llama_env.sh` from the pinned binary's own arg table
  (fails the build if the active `LLAMA_ARG_*` names vanish upstream). See
  "Runtime contract" above.

### targets/Container.vllm
The shippable vLLM toolbox for Strix Halo / gfx1151. FROM the runtime base + the
pinned TheRock torch, then `COPY --from` the flash-attention/aiter/vLLM wheels
compiled in vllm-artifacts and pip-install them into the base venv. No compilers,
no ROCm `-dev` — pure runtime. Toolbox submodule provenance (droste-ai-halo):
`6446b9595273f289e11586c3c7d3e1e6f2945888`.

- Torch (pinned TheRock nightly) into the base venv — must match the torch the
  wheels were compiled against (same pin). Installed FIRST so the vLLM wheel's
  torch requirement is already satisfied and pip does NOT pull a PyPI/CUDA torch
  over it. FLAG: if current vLLM main pins an exact torch that 2.9.1 doesn't
  satisfy, pip will try to replace it — reconcile on-host.
- Legacy resolver + `pip check`: the vLLM wheel is installed under
  `PIP_USE_DEPRECATED=legacy-resolver` (the new resolvelib backtracker dies with
  RecursionError over the `torch==2.9.1` vs `2.9.1+rocm…` pin). The legacy
  resolver takes the first satisfying candidate and never backtracks, so an
  upper bound owned by an EARLIER-resolved package is dropped silently. That
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
  import-broken image, same lesson as tokenizers). Fix: after every pip install
  in that RUN, `pip install --no-deps --force-reinstall --index-url
  ${ROCM_INDEX_URL} "torchvision==${TORCHVISION_VERSION}"` — same index + `+rocm`
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
  This image ships NO compiler by design, so `shutil.which("c++")` returned None
  and blew up in `check_compiler_ok_for_platform` (`TypeError: expected str,
  bytes or os.PathLike object, not NoneType`) -> `RuntimeError: [aiter] build
  [module_aiter_enum] ... failed` -> pydantic `Model architectures
  ['Qwen2ForCausalLM'] failed to be inspected` -> server exits. Fix: the
  artifacts stage prebuilds the `.so` (see vllm-build above) and this image
  `cp`s it into `site-packages/aiter/jit/` right after the aiter wheel install,
  where aiter's `get_module` imports it as `aiter.jit.module_aiter_enum` and
  never reaches the compiler probe. It lands in the BAKED venv — the overlay
  lower layer — so a user's venv copy-up cannot shadow it. Deliberately NOT
  fixed by adding a compiler to the runtime: the toolchain belongs to the build
  images (comfyui is the sole exception, for Triton JIT). The new
  `RUN python -c "import aiter"` is the durable half: it is the first thing in
  CI that imports any of this stack, it needs no GPU (aiter falls back to arch
  "cpu" when `rocminfo` finds nothing), and it fails the build if the prebuilt
  module is missing — the gap that let three import-broken images ship green.
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
