# droste-ai-halo

Fedora → Debian/gemet port of the [Strix Halo ROCm toolboxes](https://github.com/kyuz0)
(kyuz0's llama / ds4 / comfyui / vllm / finetuning images). These are **gemet-derived**
(Debian 13 / trixie) OCI images for AMD **Strix Halo** APUs, targeting native **gfx1151**.

A branch of the [droste](https://github.com/doctorjei/droste) project (droste-core is the
central branch) under the kento → gemet → * umbrella; consumes the same gemet bases.

## Unified ROCm pin

Everything builds against **one** pinned TheRock nightly, installed via pip `rocm-sdk-*`
wheels from the gfx1151 per-arch index — **no apt ROCm repo, no S3 tarball**. The single
source of truth is [`base/rocm-version.env`](base/rocm-version.env), and it is the *only*
place these versions are written: `base/Container.runtime` (the root of the FROM tree)
`COPY`s it to **`/etc/droste/rocm-version.env`**, every other image inherits that exact
file through `FROM`, and each version-consuming `RUN` opens with
`. /etc/droste/rocm-version.env`. No version `ARG`s, no `--build-arg` plumbing, and no way
for a port to outrun the pin its base was built from. Bump the pin by editing this one
file; the baked copy also ships in every runtime image, so you can read the pin an image
was actually built from with `cat /etc/droste/rocm-version.env`.

| Piece | Pin |
|---|---|
| Index | `https://rocm.nightlies.amd.com/v2/gfx1151/` |
| ROCm SDK (`rocm-sdk-devel` / `-libraries-gfx1151`) | `7.13.0a20260501` |
| torch / torchvision / torchaudio | `2.9.1` / `0.24.0` / `2.9.0` (`+rocm7.13.0a20260501`, cp313) |
| Target | `gfx1151` only |

**Why nightly + why this date:** gfx1151 torch exists *only* as TheRock nightly wheels
(no stable/official gfx1151 torch until ROCm 8.0, ~mid-2026). torch is the binding
constraint — the newest Linux + Python-3.13 torch wheel is `7.13.0a20260501`, and both
`rocm-sdk-*` packages exist at that same date, so the whole set is ABI-consistent. This
is arch-specific, so it is also far leaner than the all-arch apt ROCm stack.

## Topology

Two bases feed everything; **torch is a shared layer added where needed**
(`droste-torch-base-halo`), not a base fork.

```
canopy ─ droste-runtime-base-halo   (de-divert + rocm-sdk-libraries-gfx1151 runtime kernels, venv)
           ├─ droste-llama-halo           ← COPY --from droste-llama-build-halo       (no torch)
           ├─ droste-ds4-halo             ← COPY --from droste-ds4-build-halo         (no torch)
           └─ droste-torch-base-halo  (+ shared torch wheel, installed once)
                 ├─ droste-comfyui-halo         (+ torchvision/audio; single interactive image, Triton JIT)
                 ├─ droste-vllm-halo            ← COPY --from droste-vllm-build-halo
                 └─ droste-finetuning-halo      ← COPY --from droste-finetuning-build-halo

droste-runtime-base-halo ─ droste-build-base-halo  (+ rocm-sdk-devel compilers + host toolchain)
           ├─ droste-llama-build-halo / droste-ds4-build-halo        [scratch: /artifacts/{bin,lib64,share}]
           └─ droste-vllm-build-halo / droste-finetuning-build-halo  [scratch: /artifacts/wheels]
```

torch is pip-installed once in `droste-torch-base-halo` and shared by comfyui/vllm/
finetuning (one stored layer instead of three identical copies). llama/ds4 stay
torch-free on the runtime base.

**Artifact-carrier pattern:** heavy compiles happen in `droste-build-base-halo`; outputs
are captured in minimal `FROM scratch` `-build` carriers (holding only `/artifacts`); thin
runtimes `COPY --from` them onto `droste-runtime-base-halo`. Shipped runtimes carry no
ROCm SDK and no C++ toolchain; the torch-based ones do carry a bare `gcc` +
`python3.13-dev`, which Triton needs to compile its own helper at GPU init.

## Images

Published as `ghcr.io/doctorjei/droste-<name>-halo`. Containerfiles are named
`Container.<name>` under `base/`, `scaffolding/`, and `targets/`.

| Image | Containerfile | Base | Notes |
|---|---|---|---|
| `droste-runtime-base-halo` | `base/Container.runtime` | `gemet/canopy` | ROCm runtime kernels (pip), de-divert, venv `/opt/venv` |
| `droste-build-base-halo` | `base/Container.build` | `droste-runtime-base-halo` | + `rocm-sdk-devel` (hipcc/clang) + host toolchain |
| `droste-torch-base-halo` | `base/Container.torch` | `droste-runtime-base-halo` | + shared `torch` wheel (installed once; comfyui/vllm/finetuning build FROM this) + `gcc`/`python3.13-dev` for Triton's runtime compile |
| `droste-llama-build-halo` | `scaffolding/Container.llama-build` | build base | llama.cpp turboquant fork, gfx1151 HIP build [scratch carrier] |
| `droste-llama-halo` | `targets/Container.llama` | runtime base | llama runtime (no torch); `COPY --from` build carrier |
| `droste-ds4-build-halo` | `scaffolding/Container.ds4-build` | build base | ds4 + rocWMMA build [scratch carrier] |
| `droste-ds4-halo` | `targets/Container.ds4` | runtime base | ds4 runtime (no torch); cockpit via pipx |
| `droste-comfyui-halo` | `targets/Container.comfyui` | torch base | single image; +torchvision/audio; keeps compilers for Triton JIT at runtime |
| `droste-vllm-build-halo` | `scaffolding/Container.vllm-build` | build base | flash-attn + aiter + vllm wheels [scratch carrier] |
| `droste-vllm-halo` | `targets/Container.vllm` | torch base | vllm runtime (torch from base) |
| `droste-finetuning-build-halo` | `scaffolding/Container.finetuning-build` | build base | bitsandbytes + custom RCCL wheels [scratch carrier] |
| `droste-finetuning-halo` | `targets/Container.finetuning` | torch base | HF/unsloth stack (torch from base) |

The `-build` carriers are `FROM scratch` images holding only `/artifacts`.

`scaffolding/_fedora-src/` holds the original Fedora Containerfiles as a translation
reference (not built).

## Running

Every port image is a **server by default**: a shared entrypoint (baked in the
runtime base) reads the port's `/opt/resources/build-spec`, surfaces persistent
state from the `/opt/data` volume at the paths the tools expect (overlay/bind
mounts — every tool runs on its DEFAULTS, zero destination env vars), checks the
critical binds, seeds first-run content, then execs the service. A user command
still wins (`podman run IMAGE bash` gets a shell). The critical-bind checks run
first even then, so a quick shell with no binds needs `-e ALLOW_EPHEMERAL=1`.
Full contract + rationale: [BUILD_NOTES](BUILD_NOTES.md).

The normal way in is `droste-setup.sh` (see [Host tools](#host-tools)): it
creates ONE container per app — `droste-<port>-halo` — with two doors, a
serve door and an interactive one (below). The `podman run` form in this
section is that same image driven directly; the mount contract is identical
either way.

| Image | Service | Port | Config file (seeded if missing, on `/opt/data`) |
|---|---|---|---|
| comfyui | ComfyUI web UI | 8188 | `extra_model_paths.yaml` |
| finetuning | JupyterLab | 8888 | — (token auth; see container log) |
| vllm | `vllm serve --config` | 8000 | `vllm_config.yaml` — set `model:` |
| llama | `llama-server` | 8080 | `llama.env` — set `LLAMA_ARG_MODEL` |
| ds4 | `ds4-server` | 8000 | `ds4.env` — set `DS4_DROSTE_MODEL` |

Those ports are the in-container defaults a direct `podman run` publishes. A
box binds the port recorded in its `server.env` instead (host networking, no
remap) — `droste-setup.sh` offers these values, nudging ds4 to 8001 so it and
vllm run side by side.

Mount contract (all ports):

- **`/opt/data`** — the box's PERSISTENT volume: the seeded config file you
  edit, comfyui's model tree + `user/` + its custom-node overlay upper, ds4's
  saved sessions, the finetuning workspace, `server.env`. Nothing on it is ever
  deleted by anything we ship. Unbound → anonymous volume + a warning. Because
  overlay uppers live here — and on `/opt/program-cache` below — the backing
  filesystem must be ext4/btrfs/xfs-class (tmpfs also works) — **not** ecryptfs
  (encrypted homes), NFS, or virtiofs, which kernel overlayfs rejects as an
  upper. On such hosts the resolver falls back to fuse-overlayfs automatically
  (add `--device /dev/fuse` to the run to enable it), with a copy-mode last
  resort; `DROSTE_OVERLAY_MODE=auto|kernel|fuse|copy` overrides (default
  `auto`). The rule and the fallback cover BOTH per-box roots, and a box runs
  ONE mode over the two.
  Plain binds (HF cache, `/opt/caches`, input/output, workspace) have no
  filesystem requirement.
- **`/opt/program-cache`** — the box's PROGRAM-CACHE volume: everything it can
  re-obtain by itself. The venv overlay upper (and its `.work` sibling),
  comfyui's scratch `temp/` and its seeded `extra_model_paths.yaml`, llama's
  slot store, ds4's KV disk, the serve-state record `.droste-serve.pid`, and
  the per-box compute-cache fallback under `compute/`. This root is the only
  thing `droste-setup.sh` ever empties, and only when you say yes to a question
  that names it. There is deliberately **no `VOLUME` declaration** for it in
  the images — an anonymous volume would silently hoard multi-GB venv uppers
  under a name nobody goes looking for — so the bind in the ini (or the `-v`
  below) is the only thing keeping your in-box `pip install`s off the container
  layer. Unbound → a warning, never an error.
- **Critical binds** — hard-error at start unless bound; `ALLOW_EPHEMERAL=1`
  downgrades that to a warning. Always the **HF cache** (`~/.cache/huggingface` —
  the SINGLE model store, shared across all five ports; bind the same host dir
  everywhere and any model one tool downloads is available to the rest); plus
  comfyui `input`/`output` and finetuning `workspace` (irreplaceable user work).
- **`/opt/caches`** — the shared compute-cache store (MIOpen / Triton /
  torch-hub). The story is TWO shared stores plus the two per-box roots above:
  models live in the HF cache, compute caches live here, and everything
  box-private stays on `/opt/data` or `/opt/program-cache`. Bind the same host
  dir (default `~/droste/compute-caches`; any dir you like) into every
  container/box and kernels tuned or JIT-compiled by one are warm for the
  rest. Optional: unbound → the resolver degrades
  gracefully to the box's own `/opt/program-cache/compute/` with an INFO, never
  an error. llama and ds4 declare no cache rows at all (neither uses Triton or
  MIOpen), yet their inis bind this volume anyway — uniformity, so every box's
  `volume=` line reads the same.
- **`/opt/models`** — optional read-only local model collection (comfyui scanner
  source #2; the llama/ds4/vllm config model path may point here). Unbound →
  one-time INFO + marker file, never an error.

Those container paths come off **three host roots**, and what separates them is
what may be thrown away:

- **`~/droste/data/<box>`** — persistent, per box. Your work and everything you
  authored; `droste-setup.sh` never deletes anything here. comfyui's
  `input`/`output` and the finetuning `workspace` nest inside it by default.
- **`~/droste/caches/<box>`** — that box's program caches and nothing else: the
  venv overlay, llama's slots, ds4's KV disk, scratch temp, the seeded
  `extra_model_paths.yaml`. Emptied only on consent, at the installer's
  stale-cache question; every one of those is re-seeded or rebuilt at the next
  box start.
- **`~/droste/compute-caches`** — the compiled GPU kernels, shared by every box
  because their content is keyed by version and architecture. Safe to delete
  anytime; kernels rebuild on next start. The installer never touches it.

```bash
podman run -d -p 8188:8188 --device /dev/kfd --device /dev/dri \
  --cap-add sys_admin --group-add keep-groups \
  -v ~/droste/data/comfyui:/opt/data \
  -v ~/droste/caches/comfyui:/opt/program-cache \
  -v ~/droste/data/comfyui/input:/opt/ComfyUI/input \
  -v ~/droste/data/comfyui/output:/opt/ComfyUI/output \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -v ~/droste/compute-caches:/opt/caches \
  ghcr.io/doctorjei/droste-comfyui-halo:latest
```

**Why `--cap-add sys_admin`:** the entrypoint performs its overlay/bind mounts
*inside* the container, and rootless podman strips `CAP_SYS_ADMIN` — without it
every mount fails with `permission denied`. Under **rootless** podman the grant
is namespaced-only: container root maps to your own uid, so the cap allows
nothing you couldn't already do with `unshare -Urm`. Under **rootful**
podman/docker it is real host `SYS_ADMIN` — a bigger ask, though still confined
to the container's private mount namespace. `--group-add keep-groups` carries
the invoking user's supplementary groups (render/video) into the container for
rootless GPU access — the invoking user must be in those host groups. A box
created by `distrobox assemble` has the same mount needs (its init hook runs
the same resolver), so every ini — the shipped `targets/<port>/distrobox.ini`
and the ones `droste-setup.sh` emits — carries `--cap-add sys_admin` and
`--device /dev/fuse` in `additional_flags`.

comfyui additionally runs a pre-launch **model scanner**: it classifies everything
in the HF cache (+ `/opt/models`) and maintains a ComfyUI-friendly symlink tree
(`/opt/data/model-tree`, surfaced at `/opt/ComfyUI/models`) — models any port
pulls into the shared cache appear in ComfyUI's pickers automatically.

The scanner reads the files themselves wherever it can — safetensors headers,
GGUF metadata, and pickle structure for `.pt`/`.pth` (without ever executing
them) — and falls back to names only when there is nothing embedded to read.
Because that evidence is not equally trustworthy, each classification is
recorded with a **confidence** score and the signals behind it; files whose
signals disagree are reported as **DISPUTED**, so a wrong answer that looks
settled is still visible. Names and sidecar files such as `config.json` are
deliberately capped low — they are editable, and an edited one points
confidently at the wrong answer.

**One box, two doors:** the same images double as `$HOME`-native interactive
toolboxes, and that is not a second container. Each app is ONE container,
`droste-<port>-halo`, created by `distrobox assemble` — from the record
`droste-setup.sh` writes for you, or by hand from
`targets/<port>/distrobox.ini` — with two ways in:

- **the serve door** — `podman start droste-<port>-halo`. Starting the
  container replays its init hook, which applies the mounts and then reads
  `server.env` from the box's data dir: `SERVE=1` launches the service on
  `PORT` (bound directly — boxes use host networking), `SERVE=0` brings up
  the box and nothing else. Edit that file and `podman restart` the box; no
  recreate, and it survives image updates. The boxes are created with a
  podman healthcheck (flags in the ini's `additional_flags`,
  `--health-on-failure=restart`) that requires the box's OWN service to be
  the thing answering — if something else already holds the port, the box
  refuses to start a second listener, appends the refusal to its serve log
  (`/opt/data/.droste-serve.log`) and reports UNHEALTHY rather than claiming
  a stranger's port. Boxes you ask to start at host boot get a systemd user
  unit plus lingering;
- **the enter door** — `distrobox enter droste-<port>-halo`, a shell in your
  own `$HOME` with the box's toolchain. Entering a stopped box starts it, so
  the serve door opens with it when `SERVE=1`.

Both doors are the SAME environment: a `pip install` you do interactively is
what the served process runs. The init hook performs the **same resolver
mounts as the server entrypoint** — the overlays (venv, comfyui
custom_nodes; kernel→fuse→copy fallback included), the surfaces (including
comfyui's model tree and `user/`, so the ini no longer carries its own volume
lines for those), and the cache binds (the inis carry the same shared
`~/droste/compute-caches` → `/opt/caches` volume). The payoff is the whole
point of this project: in-box changes **survive box deletion/recreation**
instead of dying with the container layer — a `pip install` into `/opt/venv`
rides the venv overlay on `/opt/program-cache`, custom nodes their own overlay
on `/opt/data`. Consequently the inis carry `additional_flags` with
`--cap-add sys_admin` and `--device /dev/fuse`, and the overlay filesystem
rule above (with its automatic fallback) applies to a box too. Deliberate
deviations from a directly-run container: the HF cache gets no bind (the
auto-bound real home already provides it), destinations under `/root/` remap
to the box user's home, and directories the hook creates are chowned to the
box user.
**Upgrading from v0.1.0:** existing boxes must be recreated (`distrobox rm`
then `distrobox assemble create`) to pick up the unified mounts. An install
predating the merge also has a separate server container and compose file per
box — those are superseded by the single box above; re-run `droste-setup.sh`,
which writes the one ini and leaves your data dirs untouched.
**Upgrading to the three-root layout:** nothing is migrated, on purpose. A
re-run simply stops reading the old paths, and all of them are safe to move or
delete by hand once you have moved anything you want to keep — the old per-box
data dir `~/droste/<box>/data`, `~/droste/finetuning/workspace`, and the old
shared cache dir `~/droste/caches`. Two traps live in that last one. (1)
`~/droste/caches` is the per-box PROGRAM-CACHE root now, so only the old
kernel caches inside it (`miopen*`, `triton`, `torch`, `vllm`) are leftovers —
the per-box directories beside them are live; and because a modify run seeds
its defaults from your old ini, the compute-cache question will offer you
`~/droste/caches` — re-point it at `~/droste/compute-caches`. (2) a `ds4.env`
seeded before the split still carries
`DS4_DROSTE_KV_DISK_DIR=/opt/data/kv-disk` and keeps writing KV cache into the
data root; seeded configs are never overwritten, so edit that line to
`/opt/program-cache/kv-disk` yourself (see Troubleshooting).

### Troubleshooting

- **`mount: <path>: permission denied` at startup** → the container lacks
  `CAP_SYS_ADMIN`, so the resolver cannot mount anything (overlays *or* plain
  binds). Fix: add `--cap-add sys_admin` to the run. In the distrobox lane the
  v0.2.0 inis pass it via `additional_flags` — if a box hits this, it was
  created from a v0.1.0 ini and must be recreated.
- **`wrong fs type, bad option, bad superblock`** (dmesg: `overlayfs: upper fs
  missing required features`) → `/opt/data` sits on an overlay-hostile
  filesystem (ecryptfs/NFS/virtiofs) that kernel overlayfs cannot use as an
  upper. Fix: move `/opt/data` to ext4/btrfs/xfs-class storage, or add
  `--device /dev/fuse` and the resolver falls back to fuse-overlayfs
  automatically (copy-mode is the last resort). This applies to both lanes —
  the distrobox init hook runs the same overlays, and the v0.2.0 inis already
  pass `/dev/fuse`. Note: podman's *own* image
  storage on such filesystems is a separate concern, solved by `storage.conf`
  `mount_program = "/usr/bin/fuse-overlayfs"` (relevant for VMs with the
  graphroot on virtiofs) — that config does not affect the entrypoint's mounts.
- **`RuntimeError: No HIP GPUs are available`** (or `rocminfo` finds nothing)
  despite `--device /dev/kfd --device /dev/dri` → the user's supplementary
  groups were not carried into the container, so `/dev/kfd` is present but
  inaccessible. Fix: add `--group-add keep-groups` and verify you are in the
  host `render`/`video` groups (`groups`); if it still fails, try
  `--security-opt seccomp=unconfined` (`check-rocm.sh`'s known-good flag set
  carries both).
- **`lchown …: invalid argument` part-way through a pull** (rootless podman) →
  your `/etc/subuid` and `/etc/subgid` entries were added *after* podman's
  first run. Podman caches the id map when it initialises its storage, so a
  grant made later never reaches it: the map still covers your own id alone,
  and the first layer carrying a foreign uid/gid fails to unpack — gigabytes
  into the download. Fix: confirm both files grant this user 65536 ids
  (`sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535
  <user>` if not), then `podman system migrate` so podman re-reads them, and
  pull again. `droste-setup.sh` checks both halves — the grant on paper and
  the map podman actually holds — in its preflight, before it pulls anything.
- **`Running distrobox-assemble via SUDO/DOAS is not supported`** → the shell
  you ran from came out of `sudo -iu <user>` or `su - <user>`. That is the
  natural way to reach a dedicated user the boxes belong to, and everything
  works there right up to box creation — the pulls included, so the refusal
  arrives *after* the images are on disk. Fix: get that user a real login
  session — `machinectl shell <user>@` (package `systemd-container`) or
  `ssh <user>@localhost` — and run from it. `droste-setup.sh` stops on
  `SUDO_USER`/`DOAS_USER` in its preflight, before pulling.
- **A config file that an image update did not change** — a new option missing
  from it, or vLLM logging `Found duplicate keys --port` at every start → the
  per-port config files are seeded ONCE (`if_missing`) and never overwritten,
  because after first start they are yours to edit. Nothing tells you when the
  baked original moves on, so after an image update compare yours against it
  inside the box: `/opt/resources/templates/`. Two known cases. An old
  `vllm_config.yaml` carries a `port:` key: delete the line — the container
  owns the listen port (`server.env`), and the same goes for `LLAMA_ARG_PORT`
  in `llama.env` or `DS4_DROSTE_PORT` in `ds4.env` if you re-add them. And a
  `ds4.env` seeded before the storage split still points
  `DS4_DROSTE_KV_DISK_DIR` at `/opt/data/kv-disk`, writing KV cache into the
  persistent volume: repoint it to `/opt/program-cache/kv-disk`.

## Host tools

Three helpers ship with the repo — `droste-setup.sh` at the root,
the two adopt tools under `scripts/`. They run on the **host** (plain bash /
python3, stdlib only — no container, no pip installs) and feed the mount
contract above: `droste-setup.sh` writes the run records; the two `*-adopt` tools
populate the shared model stores the containers mount.

### droste-setup.sh — interactive installer

One self-contained bash script with zero repo-checkout dependencies (safe as
`curl <url> | bash`). It guides which boxes you want, every bind in the mount
contract, the port each service binds — ds4 and vllm both default to 8000, so
ds4's is nudged to **8001** and the two run side by side out of the box — and
whether each box serves when it starts and whether it starts at host boot. It
**probes each data dir's filesystem** and, on an overlay-hostile one
(ecryptfs/NFS/…, see Troubleshooting), offers another location, the
fuse-overlayfs fallback, or copy-mode. It then emits per-box **recreation
records** into `~/droste/` — `<box>-halo.ini` (the single `distrobox assemble`
definition for that box, healthcheck flags and all), `server.env` in the box's
own data dir (`SERVE` + `PORT`, re-read at every start), and a `NOTES.md` guide
with your real paths baked in — and can pull images, create boxes, and start
servers. Boxes asked to start at host boot also get a systemd **user** unit
(`~/.config/systemd/user/droste-<box>.service`) doing `podman start`, and the
installer enables lingering for you (printing the `sudo` form if the session
will not let it).
**The storage questions** follow the three host roots. Two yes/no questions
decide whether the program caches and the persistent data each sit under one
common base — `Store program caches at common base path (e.g.,
~/droste/caches)`, then the same for `~/droste/data`; decline either and that
family is asked per box instead (`Please indicate the path for the
program-specific caches`). Then the paths every box shares: the compute caches,
the HF cache (labelled `"cache" - never wiped`, because it is the model store),
and `Path to bind as read-only share /opt/models` — a path-or-**None** prompt,
defaulting to None, since a local model collection has no default location
(name one, e.g. `~/models`, and it is bound read-only everywhere). Finally, if
it finds leftovers in a program-cache dir, it offers to clear them: once for
the whole install (`Clear all old / stale caches`), then per box (🔶 `Clear
stale caches`) for whatever a global "no" left behind. That clear is the ONLY
deletion droste-setup.sh performs, it never reaches outside a box's
program-cache dir, and it will not touch a box that is running.
**Safe to re-run:** existing definition files, containers and boxes are
detected and listed; per box you choose keep / recreate / modify — settings
files are never silently clobbered. Its **preflight** reports the host state
the run depends on (runtime, GPU devices, groups, lingering) and covers the
two traps that would otherwise only surface after a multi-GB pull:
subordinate id ranges podman never picked up, and a `sudo -iu` / `su -`
session distrobox will refuse — see [Troubleshooting](#troubleshooting) for
both cures.

```bash
./droste-setup.sh                  # interactive menu over all five boxes
./droste-setup.sh comfyui llama    # direct-to-box shortcut
./droste-setup.sh --ascii          # ASCII-only output (no emoji / ANSI)
```

### scripts/droste-hf-adopt.sh — local downloads → the shared HF cache

Adopts already-downloaded model files (browser, wget, rsync from another
machine) into the shared HF hub cache — the SINGLE model store from the mount
contract — with **no re-download**, stored exactly the way `hf download` would
have stored them. Adoption is **hash-proven**: only files byte-identical to
the repo's published content (per the HF API manifest) are adopted; everything
else is refused with a reason — its home is the `/opt/models` bind instead.
`--repo` is optional: without it each file is **identified** via the HF search
API, still hash-gated (a repo is only accepted when its published hashes prove
it contains this exact content, never on name similarity). **Dry-run by
default** — pass `--apply` to change the cache. Hardlink is the default
placement (`--copy` / `--move` alternatives); small repo files you don't have
locally are reported as GAP, filled cheaply by a later `hf download <repo>`.

```bash
# Adopt a GGUF you fetched with wget into the shared cache (dry-run first):
./scripts/droste-hf-adopt.sh --repo Qwen/Qwen2.5-0.5B-Instruct-GGUF \
    ~/Downloads/qwen2.5-0.5b-instruct-q4_k_m.gguf
./scripts/droste-hf-adopt.sh --apply --repo Qwen/Qwen2.5-0.5B-Instruct-GGUF \
    ~/Downloads/qwen2.5-0.5b-instruct-q4_k_m.gguf

# Don't know (or trust) the repo? Omit --repo: each file is IDENTIFIED
# via the HF search API and adopted only on hash proof:
./scripts/droste-hf-adopt.sh ~/Downloads/qwen2.5-0.5b-instruct-q4_k_m.gguf

# Adopt a whole diffusers checkout (nested dirs need --recursive),
# reclaiming the disk space afterwards:
./scripts/droste-hf-adopt.sh --apply --move --recursive \
    --repo stabilityai/stable-diffusion-xl-base-1.0 ~/sdxl-download/
```

Anything adopted here is immediately visible to every container that binds the
HF cache — including ComfyUI's pickers, via the model scanner.

### scripts/droste-civitai-adopt.sh — CivitAI downloads → a webui-style tree

Sibling to `scripts/droste-hf-adopt.sh`, same invariant, for CivitAI content (checkpoints,
LoRAs, VAEs, embeddings, …): each file is identified by its **sha256** via the
CivitAI API and adopted **only on hash proof**, into a cache dir laid out like
a webui root (default `$DROSTE_CIVITAI_CACHE` or `~/.cache/civitai`). During
the same hash pass the file's **content is sniffed** (safetensors header, or
state-dict keys via a restricted execution-free unpickler) to route it to a
fine-grained directory — ControlNet vs T2IAdapter, upscaler by architecture,
LyCORIS/DoRA split out of Lora, unknown types to `other/<Type>/`. Files are
placed under a normalized **`<Model>_<Version>`** name with **three sidecars**:
`.civitai.info` (the CivitAI API response, kept shareable), `.meta.droste`
(our objective block: sha256, routing, sniff verdicts), and `.user.droste`
(your curation — notes, trigger-word/tag deltas, a `--rename` choice — written
only when non-empty, guarded against overwrite unless `--force`). Sidecars are
re-synced idempotently on every run. **Dry-run by default** — pass `--apply`.
`--version-id` is the escape hatch for very old uploads CivitAI never hashed
(still sha256-gated against the version's file list).

A normalized name can exceed the filesystem's 255-**byte** name limit (CJK is
3 bytes/char): the tool refuses it with a recommended shorter stem — it never
truncates on its own — and `--rename` lets you pick the stem; the choice is
recorded in `.user.droste` and reused on later runs.

```bash
# Dry-run first (default), then adopt — routed + normalized + sidecars:
./scripts/droste-civitai-adopt.sh ~/Downloads/juggernautXL_v9.safetensors
./scripts/droste-civitai-adopt.sh --apply ~/Downloads/juggernautXL_v9.safetensors

# A whole mixed downloads dir: one batch API call identifies everything,
# files route per-file to different model/version dirs:
./scripts/droste-civitai-adopt.sh --apply --move ~/Downloads/mixed/

# A <Model>_<Version> name past the 255-byte limit is REFUSEd with a
# "recommend: --rename '<stem>'" line; adopt under your own name instead
# (recorded, and reused on re-runs):
./scripts/droste-civitai-adopt.sh --apply --rename 'Wan21-FLF2V-14B-720P' ~/dl/wan.safetensors
```

The resulting tree is webui-shaped (`models/Stable-diffusion`, `models/Lora`,
`embeddings/`, …), so it slots straight into the **`/opt/models`** bind from
the mount contract — the comfyui scanner's second source — and the llama/ds4/
vllm config model paths can point into it. That is also where both adopt tools
send you for files that fail the hash gate: provably-published content lives in
the caches, everything else on `/opt/models`.

## Building

ROCm/HIP is **ahead-of-time cross-compiled** — images build on any x86 host (no GPU).
Only runtime checks (`rocminfo`, `torch.cuda`, inference) need a real gfx1151 device.

CI (`.github/workflows/build-halo.yml`) builds the two bases, runs a
`hipcc --offload-arch=gfx1151` + `find_package(hip)` probe (the go/no-go that pip
`rocm-sdk-devel` compiles HIP for gfx1151), then builds all five ports — one isolated
job per port (artifacts → runtime). All jobs are green; every gfx1151 HIP compile
(rocWMMA, llama.cpp, vLLM, RCCL, bitsandbytes, aiter/flash-attn) succeeds on x86.

App-source clones are pinned to the SHAs that built green (per-image `ARG *_REF`);
override with `--build-arg <NAME>_REF=<sha>` to bump.

## Runtime validation

CI proves the images build + AOT-compile; it cannot prove they **run** (no GPU). On a
gfx1151 host that exposes `/dev/kfd` + `/dev/dri`, run the sweep:

```bash
scaffolding/check-rocm.sh              # checks :latest via podman
scaffolding/check-rocm.sh --tag <sha> --runtime docker --pull
scaffolding/check-rocm.sh --help       # all options
```

The sweep is host-filesystem-agnostic: it self-carries `--cap-add sys_admin` and a
tmpfs `/opt/data` for its probes (tmpfs is always a valid overlay upper), plus
`--group-add keep-groups` for rootless GPU access.

It skips the `*-build` carriers (they are `FROM scratch` — nothing to run) and checks the
runnable tiers in two tiers: **CORE** (deterministic — GPU enumerates as `gfx1151`; `torch.cuda`
sees it on comfyui/vllm/finetuning) and **APP** (per-toolbox smoke: `llama-server --version`,
ds4 binary+`ldd`, `import vllm`, `import bitsandbytes`). Exits non-zero on any failure. The
per-toolbox smoke commands are the first thing to adjust if a tool's CLI differs — see the
comments in `check-rocm.sh`.
