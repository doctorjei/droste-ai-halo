#!/usr/bin/env python3
"""gen_vllm_config.py — emit the default vllm_config.yaml at IMAGE BUILD time.

Runs DURING the vLLM image build (see targets/Container.vllm). It parses the
VENDORED, PINNED upstream MODEL_TABLE (targets/vllm/upstream/models.py, copied into
the image) and writes /opt/resources/templates/vllm_config.yaml — the template that
templates.yaml seeds to /opt/data/vllm_config.yaml on first run (if_missing).

The generated YAML mirrors `vllm serve` CLI args (each key = a long flag without the
leading `--`). Everything is COMMENTED except the active serving default (host):
the user uncomments a MODEL_TABLE stanza (or writes their own) to choose a model.
vLLM refuses to start without a model, so leaving it commented is a self-explanatory
"you must pick a model" gate rather than a silent wrong default.

Hermetic: parses the vendored file (no network at build). Drift is visible in git via
the vendored models.py. The MODEL_TABLE is executed (not regex-parsed) so structured
fields (valid_tp, env, extra_flags, ...) come straight from the upstream dict.
"""

import argparse
import os
import runpy
import sys

DEFAULT_MODELS = "/opt/resources/scripts/vllm_models_pinned.py"
DEFAULT_OUT = "/opt/resources/templates/vllm_config.yaml"

# Serving defaults that are ACTIVE (uncommented) in the emitted config.
ACTIVE_HOST = "0.0.0.0"
# NOT emitted as a `port:` key — the launcher owns the listen port (see emit_header).
# Kept only to name the default in the explanatory comment block.
DEFAULT_PORT = 8000


def load_model_table(models_path):
    """Execute the vendored models.py and return (MODEL_TABLE, globals-dict)."""
    ns = runpy.run_path(models_path)
    table = ns.get("MODEL_TABLE")
    if not isinstance(table, dict):
        raise SystemExit(f"{models_path}: MODEL_TABLE dict not found")
    return table, ns


def parse_extra_flags(flags):
    """Turn upstream extra_flags (argv-style list) into [(key, value_or_None)].

    A token starting with `--` is a flag; if the NEXT token is not a flag it is that
    flag's value, else the flag is boolean (value None -> `key: true`).
    """
    out = []
    i = 0
    n = len(flags)
    while i < n:
        tok = flags[i]
        if tok.startswith("--"):
            key = tok[2:]
            if i + 1 < n and not flags[i + 1].startswith("--"):
                out.append((key, flags[i + 1]))
                i += 2
            else:
                out.append((key, None))
                i += 1
        else:
            # stray positional; skip defensively
            i += 1
    return out


def emit_header(out):
    out.append("# vllm_config.yaml — vLLM serve configuration (passed as `vllm serve --config <this>`).")
    out.append("#")
    out.append("# This YAML mirrors the `vllm serve` command-line arguments: each key is a long")
    out.append("# CLI flag without the leading `--` (e.g. `max-model-len:` == `--max-model-len`).")
    out.append("#")
    out.append("# ⭐ EVERY long `vllm serve` flag is a legal key here — all ~211 of them, not just")
    out.append("# the dozen this file happens to name. Run `vllm serve --help=all` in the box to")
    out.append("# see the whole list, then add the ones you want as keys. The high-impact ones for")
    out.append("# this hardware are listed at the bottom of this header.")
    out.append("#")
    out.append("# 🚨 `key: false` DOES NOT TURN A SETTING OFF — it emits nothing at all, so the")
    out.append("# setting keeps its default. To turn OFF something that is on by default, write")
    out.append("# the negated flag as its own key:  `no-enable-prefix-caching: true`.  This bites")
    out.append("# on every one of vLLM's ~60 boolean options and it is upstream's behaviour, not")
    out.append("# ours.")
    out.append("#")
    out.append("# These values are the LOWEST precedence — anything you pass on the command line or")
    out.append("# via $VLLM_EXTRA_ARGS overrides what is set here (vLLM's config-merge order).")
    out.append("# $VLLM_EXTRA_ARGS and $VLLM_CONFIG are set in /opt/data/vllm.env, which is this")
    out.append("# box's other config file: it holds the ~209 runtime VLLM_* ENVIRONMENT VARIABLES,")
    out.append("# including the ROCm performance switches, which cannot be expressed as YAML keys.")
    out.append("#")
    out.append("# The container serves THIS file by default ($VLLM_CONFIG=/opt/data/vllm_config.yaml).")
    out.append("# Edit it in place; it lives on the persisted /opt/data volume.")
    out.append("#")
    out.append("# ⚠️ THESE FLAGS TAKE THE BOX DOWN, though vLLM accepts them. The box's healthcheck")
    out.append("# probes http://127.0.0.1:$PORT/health with the scheme hardcoded, and a failed probe")
    out.append("# restarts the container — so anything that stops that exact URL from answering")
    out.append("# produces a restart loop rather than an error:")
    out.append("#   ssl-keyfile, ssl-certfile, ssl-ca-certs, ssl-cert-reqs, ssl-ciphers,")
    out.append("#   enable-ssl-refresh   (TLS: the probe still speaks http)")
    out.append("#   uds                  (a unix socket: nothing answers TCP)")
    out.append("#   headless             (no API server at all)")
    out.append("# Terminate TLS in a proxy in front of the box instead.")
    out.append("#")
    out.append("# ✅ `api-key:` is safe: vLLM's auth middleware skips any path outside /v1, so")
    out.append("# /health still answers and the healthcheck keeps working.")
    out.append("#")
    out.append("# Stale compiled-graph note: this image sets VLLM_DISABLE_COMPILE_CACHE=1, so vLLM")
    out.append("# does not persist torch.compile graphs. If vLLM crashes right after a version bump,")
    out.append("# clear any leftover JIT cache with:  rm -rf ~/.cache/vllm")
    out.append("#")
    out.append("# " + "-" * 75)
    out.append("# REQUIRED: choose a model. vLLM will NOT start until `model:` is set. Uncomment one")
    out.append("# MODEL_TABLE stanza below (or add your own line); a model is a HuggingFace repo id")
    out.append("# or an absolute local path:")
    out.append("#")
    out.append("# model: meta-llama/Meta-Llama-3.1-8B-Instruct   # REQUIRED — vllm won't start until set")
    out.append("# " + "-" * 75)
    out.append("")
    out.append("# ── Active serving defaults (uncommented = in effect) ────────────────────────")
    out.append(f'host: "{ACTIVE_HOST}"')
    out.append("")
    out.append("# NO `port:` key here ON PURPOSE — the container owns the listen port and appends")
    out.append("# `--port` to the `vllm serve` command line (PORT in /opt/data/server.env, default")
    out.append(f"# {DEFAULT_PORT}). Setting it here too would be overridden anyway AND makes vLLM log")
    out.append('# "Found duplicate keys --port" at every start. Change the port in server.env.')
    out.append("")
    out.append("# Suggested global defaults (uncomment to apply; from the upstream toolbox):")
    out.append("# gpu-memory-utilization: 0.90")
    out.append("# max-num-batched-tokens: 8192")
    out.append("")
    emit_key_guide(out)


def emit_key_guide(out):
    """The keys a single-user Strix Halo box actually reaches for.

    Not a wish list and not the full 211 — a signpost, so a user who read upstream's
    docs can tell that the rest of the surface is legal here. Grouped the way vLLM's
    own config classes group them, since that is how `--help=all` prints.
    """
    out.append("# ══ Keys worth knowing on this box (all legal, none set) ═════════════════════")
    out.append("#   the full list is `vllm serve --help=all`; these are the ones that bite here")
    out.append("#")
    out.append("# Memory — the story does not stop at gpu-memory-utilization")
    out.append("#   kv-cache-memory-bytes  an ABSOLUTE figure, far more predictable than a")
    out.append("#                          fraction of a pool the GPU shares with the system")
    out.append("#   swap-space             silently reserves 4 GiB of host RAM by default")
    out.append("#   cpu-offload-gb, block-size, num-gpu-blocks-override, kv-cache-dtype")
    out.append("#   enable-prefix-caching  ON by default — to disable: no-enable-prefix-caching: true")
    out.append("#")
    out.append("# Compute")
    out.append("#   attention-backend      one key, its own group, and the most likely thing to")
    out.append("#                          try on a GPU architecture this new")
    out.append("#   optimization-level (-O), enforce-eager, compilation-config, dtype,")
    out.append("#   quantization, calculate-kv-scales")
    out.append("#   ⚠️ enforce-eager appears inside some model stanzas below as the documented")
    out.append("#      Strix Halo workaround; it is a global key too. To undo a stanza's, use")
    out.append("#      no-enforce-eager: true")
    out.append("#")
    out.append("# Local weights / air-gap")
    out.append("#   download-dir, load-format, ignore-patterns, safetensors-load-strategy,")
    out.append("#   hf-token, revision, served-model-name, model-impl")
    out.append("#   (VLLM_MODEL_REDIRECT_PATH in vllm.env maps repo ids to local paths)")
    out.append("#")
    out.append("# Scheduling")
    out.append("#   enable-chunked-prefill, async-scheduling, scheduling-policy,")
    out.append("#   long-prefill-token-threshold, max-num-partial-prefills, stream-interval")
    out.append("#")
    out.append("# Serving / frontend")
    out.append("#   api-key, chat-template, response-role, allowed-origins, max-log-len,")
    out.append("#   uvicorn-log-level, disable-fastapi-docs, enable-offline-docs")
    out.append("#")
    out.append("# Multimodal and LoRA")
    out.append("#   limit-mm-per-prompt, skip-mm-profiling, video-pruning-rate,")
    out.append("#   mm-processor-cache-gb   ⚠️ reserves 4 GiB by DEFAULT on a multimodal model")
    out.append("#   enable-lora, max-loras, max-lora-rank, lora-modules")
    out.append("#")
    out.append("# Advanced")
    out.append("#   speculative-config, structured-outputs-config, additional-config,")
    out.append("#   max-logprobs, generation-config, hf-overrides, enable-sleep-mode")
    out.append("")


def emit_model(out, repo, spec):
    out.append("# " + "=" * 75)
    out.append(f"# {repo}")

    valid_tp = spec.get("valid_tp")
    if valid_tp:
        out.append(f"#   valid tensor-parallel sizes on Strix Halo: {valid_tp}")

    env = spec.get("env") or {}
    if env:
        # These cannot be YAML keys, and telling the user to `export` them is advice
        # that does not survive a container restart. /opt/data/vllm.env is where an
        # env var for the SERVED process goes — before that file existed this stanza
        # named opt-ins the user had no way to take, and could not tell apart from the
        # ones the image already bakes.
        out.append("#   env (NOT yaml keys — put these lines in /opt/data/vllm.env):")
        for k, v in env.items():
            out.append(f"#     {k}={v}")
    else:
        out.append("#   env (lines for /opt/data/vllm.env): <none>")

    ctx = spec.get("ctx")
    if ctx:
        out.append(f"#   ctx (upstream field): {ctx}  (raise max-model-len below to use full context)")

    out.append("# " + "-" * 75)
    out.append(f"# model: {repo}")

    tp_default = valid_tp[0] if valid_tp else 1
    out.append(f"# tensor-parallel-size: {tp_default}")

    if spec.get("max_num_seqs") is not None:
        out.append(f"# max-num-seqs: {spec['max_num_seqs']}")
    if spec.get("max_tokens") is not None:
        out.append(f"# max-model-len: {spec['max_tokens']}")

    # ⚠️ NEVER emit `<key>: false`. vLLM's config reader drops a false boolean
    # instead of negating it, so such a line teaches an idiom that silently does
    # nothing (see the header). A boolean upstream records as False is simply the
    # default, so the honest rendering is to leave it out.
    if spec.get("trust_remote"):
        out.append("# trust-remote-code: true")
    if spec.get("enforce_eager"):
        out.append("# enforce-eager: true")

    for key, val in parse_extra_flags(spec.get("extra_flags") or []):
        if val is None:
            out.append(f"# {key}: true")
        elif str(val).lower() == "false":
            out.append(f"# no-{key}: true   # (upstream writes --{key} false; that is a no-op in yaml)")
        else:
            out.append(f"# {key}: {val}")

    out.append("")


def generate(models_path):
    table, _ = load_model_table(models_path)
    out = []
    emit_header(out)
    out.append("# ══ MODEL_TABLE — verified Strix Halo models (uncomment ONE stanza) ══════════")
    out.append(f"#   harvested at build from the pinned upstream scripts/models.py ({len(table)} models)")
    out.append("")
    for repo, spec in table.items():
        emit_model(out, repo, spec)
    return "\n".join(out) + "\n"


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--models", default=DEFAULT_MODELS,
                    help=f"vendored models.py to parse (default: {DEFAULT_MODELS})")
    ap.add_argument("--out", default=DEFAULT_OUT,
                    help=f"output yaml path (default: {DEFAULT_OUT})")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.models):
        raise SystemExit(f"models file not found: {args.models}")

    text = generate(args.models)
    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"gen_vllm_config: wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
