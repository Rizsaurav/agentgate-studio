#!/usr/bin/env python3
"""Compare a freshly built catalog with the committed one, for the nightly refresh (#90).

    catalog_diff.py OLD.json NEW.json --report report.md --score score.tsv [--max-score-bytes N]

Writes a Markdown report for the pull request and, one per line, the models to score with the
tool-calling suite: "<id>\t<repo>\t<file>\t<sha256>". Exit codes:
  0  no change
  1  changes to propose
  2  a file's checksum changed for an existing entry: the upstream file may have been replaced,
     so nothing is proposed until a person has looked
"""
import argparse
import json
import sys
from pathlib import Path

QUANTS = ["Q8_0", "Q6_K", "Q5_K_M", "MXFP4", "Q4_K_M", "Q3_K_M"]
# Hosted runners have about 7 GB of memory and no GPU: larger models are flagged for a run on a Mac.
DEFAULT_MAX_SCORE_BYTES = 3_000_000_000
# Scoring on a runner's CPU takes about half an hour for a 0.6B model: keep the nightly job bounded.
DEFAULT_MAX_MODELS = 2


def by_id(catalog):
    return {m["id"]: m for m in catalog["models"]}


def files(model):
    return {f["file"]: f for f in model["gguf"]["files"]}


def score_target(model, limit):
    """The best-quality ready-made file small enough to score on a runner, or None."""
    fitting = [f for f in model["gguf"]["files"] if f["bytes"] <= limit]
    fitting.sort(key=lambda f: QUANTS.index(f["quant"]) if f["quant"] in QUANTS else len(QUANTS))
    return fitting[0] if fitting else None


def compare(old, new, limit=DEFAULT_MAX_SCORE_BYTES, max_models=DEFAULT_MAX_MODELS):
    """Returns (checksum_changes, notes, to_score). Pure, for tests."""
    before, after = by_id(old), by_id(new)
    checksum_changes, notes, to_score = [], [], []

    for mid in sorted(set(before) - set(after)):
        notes.append(f"Removed from the catalog: **{mid}**.")

    for mid, model in after.items():
        old_model = before.get(mid)
        if not model["gguf"]["files"] and "source" not in model:
            notes.append(f"**{mid}**: no downloadable files. The repository `{model['gguf']['repo']}` may be gated or removed upstream.")
            continue
        if old_model is None:
            notes.append(f"New model: **{mid}** ({model['name']}, {model['licence']}).")
            changed = True
        else:
            changed = False
            noted = len(notes) + len(checksum_changes)
            old_files, new_files = files(old_model), files(model)
            for name in sorted(set(old_files) & set(new_files)):
                if old_files[name]["sha256"] != new_files[name]["sha256"]:
                    checksum_changes.append(
                        f"{mid}: {name} changed checksum {old_files[name]['sha256'][:12]}… → {new_files[name]['sha256'][:12]}…")
                elif old_files[name]["bytes"] != new_files[name]["bytes"]:
                    checksum_changes.append(f"{mid}: {name} changed size without a checksum change")
            added = sorted(set(new_files) - set(old_files))
            removed = sorted(set(old_files) - set(new_files))
            if added:
                notes.append(f"**{mid}**: new files {', '.join(f'`{n}`' for n in added)}.")
                changed = True
            if removed:
                notes.append(f"**{mid}**: files no longer upstream {', '.join(f'`{n}`' for n in removed)}.")
                changed = True
            if old_model.get("licence") != model.get("licence"):
                notes.append(f"**{mid}**: licence changed from `{old_model.get('licence')}` to `{model.get('licence')}`. Check it still allows use.")
            if old_model.get("source") and not model.get("source"):
                notes.append(f"**{mid}**: full weights `{old_model['source']['repo']}` are no longer available (gated or removed?).")
            if old_model != model and len(notes) + len(checksum_changes) == noted:
                notes.append(f"**{mid}**: other details changed; see the diff.")
        if changed and model.get("toolCalling"):
            target = score_target(model, limit)
            if target and len(to_score) < max_models:
                to_score.append((mid, model["gguf"]["repo"], target["file"], target["sha256"]))
            elif target:
                notes.append(f"**{mid}**: not scored, at most {max_models} models are scored per run. "
                             "Score it on a Mac with `agentgate-tooleval run`.")
            else:
                notes.append(f"**{mid}**: every file is larger than {limit / 1e9:.1f} GB, too large to score on the runner. "
                             "Score it on a Mac with `agentgate-tooleval run`.")
    return checksum_changes, notes, to_score


def report(checksum_changes, notes, to_score):
    lines = ["## Catalog refresh", ""]
    if checksum_changes:
        lines += ["### Checksum changed for an existing file", "",
                  "The upstream file may have been replaced. Nothing was scored or proposed.", ""]
        lines += [f"- {c}" for c in checksum_changes] + [""]
    lines += [f"- {n}" for n in notes] or ["- No changes."]
    lines.append("")
    if to_score:
        lines += ["Scored with the tool-calling suite on the runner (CPU only, so speed differs from a Mac; the "
                  "pass rate is what counts): " + ", ".join(f"`{m[0]}` ({m[2]})" for m in to_score) + ".", ""]
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("old")
    parser.add_argument("new")
    parser.add_argument("--report", required=True)
    parser.add_argument("--score", required=True)
    parser.add_argument("--max-score-bytes", type=int, default=DEFAULT_MAX_SCORE_BYTES)
    parser.add_argument("--max-models", type=int, default=DEFAULT_MAX_MODELS)
    args = parser.parse_args(argv)
    old = json.loads(Path(args.old).read_text())
    new = json.loads(Path(args.new).read_text())
    checksum_changes, notes, to_score = compare(old, new, args.max_score_bytes, args.max_models)
    Path(args.report).write_text(report(checksum_changes, notes, to_score))
    Path(args.score).write_text("".join("\t".join(m) + "\n" for m in to_score))
    for change in checksum_changes:
        print(f"::error title=Catalog checksum changed::{change}. The upstream file may have been replaced; check it before updating the catalog.")
    if checksum_changes:
        return 2
    return 1 if notes or old != new else 0


if __name__ == "__main__":
    sys.exit(main())
