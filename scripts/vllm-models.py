#!/usr/bin/env python3
"""vllm-models.py — DEV-TIME drift report for vllm_config.yaml's MODEL_TABLE stanzas.

Renders what each stanza in the MODEL_TABLE section of
targets/vllm/templates/vllm_config.yaml WOULD say if it were derived from the
vendored upstream table (targets/vllm/upstream/models.py), and reports where the
authored file and the vendored table disagree. Run it when the vendored file is
re-fetched at a new toolbox pin; the output is a work list for editing the YAML by
hand.

⭐ WHY THIS IS NOT A BUILD STEP (it used to be, as targets/vllm/scripts/gen_vllm_config.py):
  1. Presentation of the config surface is ours to control, and vllm_config.yaml is
     now an authored, reviewed template. A build step that writes that path
     OVERWRITES the authored file with generated output and the template goes inert
     — see the warning block in targets/Container.vllm.
  2. Generating at build time bought one thing: stanzas that follow models.py
     automatically. That never fired, because models.py is a VENDORED file that only
     changes when a human re-fetches it at a new pin. The moment it changes is
     exactly the moment a human is already editing — which is a report's moment, not
     a build's.

🚨 THIS TOOL CANNOT WRITE THE YAML, BY CONSTRUCTION. It takes no output path, it has
no write mode, and the only open() below is read-only. That is deliberate: the whole
point of retiring the generator was that nothing may overwrite the authored template,
so "don't run it with --out" would have been the wrong guarantee to offer.

⚠️ WHAT IT DOES NOT DO. It compares the MODEL_TABLE section only. The other ~450
lines of vllm_config.yaml describe `vllm serve` FLAGS, which come from vLLM itself
and not from the toolbox's model table; nothing here notices a flag that upstream
renamed, retired or re-defaulted. It is also not a gate — it always exits 0.

Usage: vllm-models.py [--models FILE] [--yaml FILE] [--list]
"""

import argparse
import difflib
import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MODELS = os.path.join(HERE, os.pardir, "targets", "vllm", "upstream", "models.py")
DEFAULT_YAML = os.path.join(HERE, os.pardir, "targets", "vllm", "templates", "vllm_config.yaml")


def load_model_table(models_path):
    """Execute the vendored models.py and return its MODEL_TABLE dict.

    Executed rather than regex-parsed so structured fields (valid_tp, env,
    extra_flags, ...) come straight from the upstream dict.
    """
    ns = runpy.run_path(models_path)
    table = ns.get("MODEL_TABLE")
    if not isinstance(table, dict):
        raise SystemExit(f"{models_path}: MODEL_TABLE dict not found")
    if not table:
        raise SystemExit(f"{models_path}: MODEL_TABLE is empty — that is a broken vendor, not a shrunken upstream")
    return table


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


def render_stanza(repo, spec):
    """The stanza the vendored table implies, as a list of lines (no trailing blank).

    Lifted from the retired generator's emit_model(), where it was proven against
    this pin — that is what makes a line-for-line comparison with the authored file
    meaningful rather than approximate.
    """
    out = []
    out.append("# " + "=" * 75)
    out.append(f"# {repo}")

    valid_tp = spec.get("valid_tp")
    if valid_tp:
        out.append(f"#   valid tensor-parallel sizes on Strix Halo: {valid_tp}")

    env = spec.get("env") or {}
    if env:
        # These cannot be YAML keys, and telling the user to `export` them is advice
        # that does not survive a container restart. /opt/data/vllm.env is where an
        # env var for the SERVED process goes.
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

    # ⚠️ NEVER render `<key>: false`. vLLM's config reader drops a false boolean
    # instead of negating it, so such a line teaches an idiom that silently does
    # nothing. A boolean upstream records as False is simply the default, so the
    # honest rendering is to leave it out.
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

    return out


def read_yaml_stanzas(yaml_path):
    """Return {repo: [lines]} for every stanza in the authored YAML.

    A stanza is a contiguous run of comment lines containing a `# model: <repo>`
    line. Keying on that line rather than on the `# ====` banner is deliberate: the
    model line is the one a user uncomments, so it is the one that must be right.

    ⚠️ SCOPED TO THE MODEL_TABLE SECTION, and it has to be. The Model Selection block
    near the top of the file also carries a `# model:` line — it names the value vLLM
    itself defaults to — and reading the whole file counted that as a thirteenth
    stanza for a model upstream had "dropped".
    """
    with open(yaml_path, encoding="utf-8") as fh:
        lines = [ln.rstrip("\n").rstrip() for ln in fh]

    start = next((i + 1 for i, ln in enumerate(lines)
                  if ln.startswith("#") and "MODEL_TABLE" in ln), None)
    if start is None:
        print(f"vllm-models: WARNING: no '# … MODEL_TABLE …' banner in {yaml_path};"
              " scanning the whole file, so expect false stanzas.", file=sys.stderr)
        start = 0
    lines = lines[start:]

    stanzas = {}
    run = []
    for line in lines + [""]:
        if line.startswith("#"):
            run.append(line)
            continue
        if run:
            repo = None
            for entry in run:
                if entry.startswith("# model: "):
                    repo = entry[len("# model: "):].strip()
                    break
            if repo is not None:
                stanzas[repo] = list(run)
            run = []
    return stanzas


def report(title, body, hint):
    print(f"== {title} ==")
    if not body:
        print("   (none)\n")
        return
    for line in body:
        print(f"   {line}")
    print(f"   -> {hint}\n")


def main(argv):
    ap = argparse.ArgumentParser(
        description="Drift report: vendored MODEL_TABLE vs the authored vllm_config.yaml.")
    ap.add_argument("--models", default=DEFAULT_MODELS,
                    help="vendored models.py to parse (default: targets/vllm/upstream/models.py)")
    ap.add_argument("--yaml", default=DEFAULT_YAML,
                    help="authored config to compare (default: targets/vllm/templates/vllm_config.yaml)")
    ap.add_argument("--list", action="store_true",
                    help="print the stanzas the vendored table implies, and stop")
    args = ap.parse_args(argv)

    for path in (args.models, args.yaml):
        if not os.path.isfile(path):
            raise SystemExit(f"file not found: {path}")

    table = load_model_table(args.models)
    rendered = {repo: render_stanza(repo, spec) for repo, spec in table.items()}

    if args.list:
        for repo in table:
            print("\n".join(rendered[repo]))
            print()
        return 0

    print(f"vllm-models: {len(table)} model(s) in {args.models}", file=sys.stderr)
    authored = read_yaml_stanzas(args.yaml)
    print(f"vllm-models: {len(authored)} stanza(s) in {args.yaml}\n", file=sys.stderr)

    missing = [r for r in table if r not in authored]
    extra = [r for r in authored if r not in table]

    changed = []
    for repo in table:
        if repo not in authored:
            continue
        want = rendered[repo]
        have = authored[repo]
        if want == have:
            continue
        changed.append(f"{repo}:")
        diff = difflib.unified_diff(have, want, lineterm="", n=1,
                                    fromfile="vllm_config.yaml", tofile="models.py")
        changed.extend("  " + d for d in list(diff)[2:])

    report("models in models.py with no stanza in vllm_config.yaml", missing,
           "add a stanza by hand — `--list` prints the one the table implies")
    report("stanzas in vllm_config.yaml naming a model models.py does not have", extra,
           "upstream dropped it, or it is a stanza we added on purpose — decide which")
    report("stanzas whose lines disagree with the vendored table", changed,
           "'-' is what the yaml says, '+' is what models.py implies")

    n_bad = len(missing) + len(extra) + len(changed)
    print(f"vllm-models: {n_bad} item(s) need a decision", file=sys.stderr)
    # Exit 0 either way: this is a report a human acts on, not a gate.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
