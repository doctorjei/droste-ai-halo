## Droste MREs (Machines Ready to Execute)
**_Local Strix Halo AI Boxes_**

Quick & easy ComfyUI, llama.cpp, DS4, vLLM, & model finetuning boxes for **Strix Halo** (gfx1151). This is a Debian 13 (trixie) port of [Strix Halo ROCm toolboxes](https://github.com/kyuz0); also a branch of [droste](https://github.com/doctorjei/droste).

<br />

## Quick Start

On a Strix Halo machine with **podman** and **distrobox**:

```bash
curl -fsSLO https://github.com/doctorjei/droste-ai-halo/releases/latest/download/droste-setup.sh | bash
```

Images can also be directly pulled from `ghcr.io/doctorjei/droste-<name>-halo`.

<br />

## End-User Images

Each image works as both an independent server and/or interactive distrobox via a common entrypoint.

| Image | Service | Port | Config  | Notes |
|---|---|---|---|---|
| droste-comfyui-halo | ComfyUI web UI | 8188 | `comfyui.cfg` | with compilers<br /> (Triton JIT) |
| droste-finetuning-halo | JupyterLab | 8888 | `finetuning.cfg`  | HF/unsloth stack |
| droste-vllm-halo** | `vllm serve --config` | 8000 | `vllm.cfg`, `vllm_config.yaml` | Just vllm :) |
| droste-llama-halo | `llama-server` | 9931* | `llama.cfg` | with TurboQuant |
| droste-ds4-halo | `ds4-server` | 8001^| `ds4.cfg` | cockpit via pipx |

__*__ _llama.cpp default port is changing to 9931 in its next release; I went ahead with it for this release._

__**__ _Most servers have a behavior to determine a default model, but vllm ***requires*** a model setting._

__^__ _DS4 normally defaults to 8000; however, this is taken by vllm, so DS4 has been moved to 8001._

<br />

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `mount: <path>: permission denied`<br /> (startup) | no `CAP_SYS_ADMIN` | `--cap-add sys_admin` |
| `wrong fs type`, `bad option`, or<br /> `bad superblock` | incompatible base FS<br /> (ecryptfs, etc.) | use other storage, or<br /> `--device /dev/fuse` (fallback) |
| `RuntimeError: No HIP GPUs` | `render`/`video` not <br />carried to box (groups) | `--group-add keep-groups`<br /> `--security-opt seccomp=unconfined` |
| `lchown …: invalid argument`<br /> at pull (rootless) | `/etc/subuid`, `/etc/subgid`<br /> added late | `sudo usermod --add-subuids 100000-165535`<br />&emsp;`--add-subgids 100000-165535 <user>`<br /> `podman system migrate`; re-pull images |
| `…distrobox-assemble via`<br />`SUDO/DOAS is not supported` | shell from `sudo -iu <user>`,<br /> `su - <user>` | Fix: use real user login session, or<br /> `machinectl shell <user>@`) |

<br />

## Pinned Dependencies

Everything builds against a pinned "TheRock" nightly.

| Item | Version |
|---|---|
| ROCm SDK | `7.13.0a20260501`|
| torch | `2.9.1` |
| torchvision | `0.24.0` |
| torchaudio | `2.9.0` |
