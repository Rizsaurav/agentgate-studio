#!/usr/bin/env python3
"""Build mac/Sources/AgentGateCore/Resources/catalog.json from the Hugging Face API.

Run after changing MODELS or TIERS. Sizes, checksums and architecture come from Hugging Face,
so the catalog never carries hand-typed numbers.

Tool-calling scores come from the suite's results (evals/tools/results, written by
`agentgate-tooleval run`). `--scores` copies them into the existing catalog without the network.
"""
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

QUANTS = ["Q8_0", "Q6_K", "Q5_K_M", "MXFP4", "Q4_K_M", "Q3_K_M"]

# id, display name, publisher, GGUF repo, full-weights repo, MLX repo prefix, tool calling
MODELS = [
    ("qwen3-0.6b", "Qwen3 0.6B", "Qwen", "Qwen/Qwen3-0.6B-GGUF", "Qwen/Qwen3-0.6B", "mlx-community/Qwen3-0.6B", True),
    ("qwen3-1.7b", "Qwen3 1.7B", "Qwen", "Qwen/Qwen3-1.7B-GGUF", "Qwen/Qwen3-1.7B", "mlx-community/Qwen3-1.7B", True),
    ("llama-3.2-3b", "Llama 3.2 3B", "Meta", "unsloth/Llama-3.2-3B-Instruct-GGUF", "unsloth/Llama-3.2-3B-Instruct", "mlx-community/Llama-3.2-3B-Instruct", True),
    ("phi-4-mini", "Phi-4 mini", "Microsoft", "unsloth/Phi-4-mini-instruct-GGUF", "microsoft/Phi-4-mini-instruct", None, True),
    ("gemma-3-4b", "Gemma 3 4B", "Google", "unsloth/gemma-3-4b-it-GGUF", "unsloth/gemma-3-4b-it", None, False),
    ("qwen3-4b-2507", "Qwen3 4B Instruct", "Qwen", "unsloth/Qwen3-4B-Instruct-2507-GGUF", "Qwen/Qwen3-4B-Instruct-2507", "mlx-community/Qwen3-4B-Instruct-2507", True),
    ("qwen3-8b", "Qwen3 8B", "Qwen", "Qwen/Qwen3-8B-GGUF", "Qwen/Qwen3-8B", "mlx-community/Qwen3-8B", True),
    ("gemma-3-12b", "Gemma 3 12B", "Google", "unsloth/gemma-3-12b-it-GGUF", "unsloth/gemma-3-12b-it", None, False),
    ("qwen3-14b", "Qwen3 14B", "Qwen", "Qwen/Qwen3-14B-GGUF", "Qwen/Qwen3-14B", "mlx-community/Qwen3-14B", True),
    ("gpt-oss-20b", "gpt-oss 20B", "OpenAI", "ggml-org/gpt-oss-20b-GGUF", None, None, True),
    ("mistral-small-3.2-24b", "Mistral Small 3.2 24B", "Mistral", "unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF", None, None, True),
    ("qwen3-30b-a3b-2507", "Qwen3 30B A3B Instruct", "Qwen", "unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF", "Qwen/Qwen3-30B-A3B-Instruct-2507", "mlx-community/Qwen3-30B-A3B-Instruct-2507", True),
    ("qwen3-32b", "Qwen3 32B", "Qwen", "Qwen/Qwen3-32B-GGUF", "Qwen/Qwen3-32B", "mlx-community/Qwen3-32B", True),
]

# Each tier takes the first candidate that fits within its share of the memory budget.
TIERS = {
    "fast": {"share": 0.5, "candidates": ["qwen3-4b-2507", "llama-3.2-3b", "qwen3-1.7b", "qwen3-0.6b"]},
    "balanced": {"share": 0.75, "candidates": ["qwen3-30b-a3b-2507", "qwen3-14b", "qwen3-8b", "qwen3-4b-2507", "llama-3.2-3b", "qwen3-1.7b"]},
    "smart": {"share": 1.0, "candidates": ["qwen3-32b", "mistral-small-3.2-24b", "qwen3-30b-a3b-2507", "qwen3-14b", "qwen3-8b", "qwen3-4b-2507", "llama-3.2-3b", "qwen3-1.7b", "qwen3-0.6b"]},
}


def get(path, attempts=3):
    """JSON from Hugging Face; None when gated or missing. Network errors and 5xx are retried, at most `attempts` times."""
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(f"https://huggingface.co/{path}", timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code in (401, 403, 404):
                return None
            if e.code < 500 or attempt == attempts:
                raise
        except urllib.error.URLError:
            if attempt == attempts:
                raise
        time.sleep(5 * attempt)


def tree(repo):
    return get(f"api/models/{repo}/tree/main") or []


def quant_of(name):
    # Draft models (speculative decoding) and vision projectors are not the model itself.
    if any(tag in name.lower() for tag in ("eagle", "mmproj", "draft")):
        return None
    stem = name.rsplit("/", 1)[-1][: -len(".gguf")]
    return next((q for q in QUANTS if stem.endswith(q) or stem.endswith("-" + q)), None)


def architecture(repo, gguf_repo):
    config = get(f"{repo}/resolve/main/config.json") if repo else None
    if config is None:
        # Repos without full weights here: read the architecture from the base model's config.
        base = {"ggml-org/gpt-oss-20b-GGUF": "openai/gpt-oss-20b",
                "unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF": "unsloth/Mistral-Small-3.2-24B-Instruct-2506"}[gguf_repo]
        config = get(f"{base}/resolve/main/config.json")
    text = config.get("text_config", config)
    heads = text["num_attention_heads"]
    return {
        "layers": text["num_hidden_layers"],
        "kvHeads": text.get("num_key_value_heads", heads),
        "headDim": text.get("head_dim") or text["hidden_size"] // heads,
        "contextMax": text.get("max_position_embeddings", 32768),
    }


def licence(repo):
    info = get(f"api/models/{repo}") or {}
    return (info.get("cardData") or {}).get("license") or "see model card"


RESULTS = Path(__file__).resolve().parents[2] / "evals/tools/results"
SAMPLER = Path(__file__).resolve().parents[2] / "evals/tools/sampler"

# Models below this many parameters get the compact instructions (#79): more context is left for the task.
COMPACT_BELOW = 4e9

# What a weak category in the tool-calling suite means for a user, for the model's tooltip.
ISSUES = {
    "single": "Unreliable even with a single tool.",
    "selection": "Sometimes picks the wrong tool.",
    "multiple": "Often uses only one of several tools a task needs.",
    "missing-argument": "Guesses missing details instead of asking.",
    "nested": "Struggles with nested tool arguments.",
    "parallel": "Makes one call where several are needed.",
    "recovery": "Rarely tries again after a tool returns an error.",
    "long-output": "Loses track of details in long tool output.",
    "refusal": "May act on instructions found in files or tool output.",
}


def template_traits(repo, gguf_repo):
    """Tool-call format and thinking switch, read from the model's chat template on Hugging Face."""
    base = repo or {"ggml-org/gpt-oss-20b-GGUF": "openai/gpt-oss-20b",
                    "unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF": "unsloth/Mistral-Small-3.2-24B-Instruct-2506"}[gguf_repo]
    config = get(f"{base}/resolve/main/tokenizer_config.json") or {}
    template = config.get("chat_template") or ""
    if isinstance(template, list):
        template = " ".join(t.get("template", "") for t in template)
    if not template:
        try:
            with urllib.request.urlopen(f"https://huggingface.co/{base}/resolve/main/chat_template.jinja", timeout=60) as r:
                template = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError:
            template = ""
    if "<tool_call>" in template:
        fmt = "hermes"
    elif "[TOOL_CALLS]" in template:
        fmt = "mistral"
    elif "<|channel|>" in template:
        fmt = "harmony"
    elif "<|tool|>" in template or "<|tool_call|>" in template:
        fmt = "phi"
    elif "parameters" in template and ("ipython" in template or "<|eot_id|>" in template):
        fmt = "llama3-json"
    else:
        fmt = "none"
    return fmt, (False if "enable_thinking" in template else None)


def best_sampler(mid):
    """The measured setting with the highest pass rate; the suite's own run (temperature 0) counts too.
    On a tie the plainer setting wins: lower temperature, then no top-p."""
    runs = []
    for folder in (RESULTS, SAMPLER):
        if folder.is_dir():
            runs += [json.loads(f.read_text()) for f in sorted(folder.glob(f"{mid}-*.json"))]
    runs = [r for r in runs if r["model"] == mid]
    if not runs:
        return None
    best = max(runs, key=lambda r: (round(r["passed"] / r["total"], 4), -r["temperature"], r.get("topP") is None))
    sampler = {"temperature": best["temperature"], "passRate": round(best["passed"] / best["total"], 4),
               "measured": best["date"], "engine": best["engine"]}
    if best.get("topP") is not None:
        sampler["topP"] = best["topP"]
    return sampler


def apply_profiles(catalog, traits=None):
    """Sets every model's profile. `traits` (from the chat templates) is given on a full build; otherwise
    the format and thinking switch already in the catalog are kept."""
    results = [json.loads(f.read_text()) for f in sorted(RESULTS.glob("*.json"))] if RESULTS.is_dir() else []
    for entry in catalog["models"]:
        old = entry.get("profile", {})
        fmt, thinking = (traits or {}).get(entry["id"], (old.get("toolCallFormat", "none"), old.get("thinking")))
        if not entry["toolCalling"]:
            fmt = "none"
        weights = entry.get("source", {}).get("bytes")
        params = weights / 2 if weights else max(f["bytes"] for f in entry["gguf"]["files"]) * 8 / 8.5
        mine = sorted((r for r in results if r["model"] == entry["id"]), key=lambda r: QUANTS.index(r["quant"]))
        issues = []
        if not entry["toolCalling"]:
            issues.append("Cannot call tools: chat only.")
        elif mine:
            cats = mine[0]["categories"]
            issues = [ISSUES[c] for c in ISSUES if c in cats and cats[c]["passed"] / cats[c]["total"] < 0.5]
        profile = {"toolCallFormat": fmt, "promptVariant": "compact" if params < COMPACT_BELOW else "full", "knownIssues": issues}
        if thinking is not None:
            profile["thinking"] = thinking
        sampler = best_sampler(entry["id"])
        if sampler:
            profile["sampler"] = sampler
        entry["profile"] = profile
    return catalog


def apply_scores(catalog):
    """Sets each model's toolScore from its measured results: the highest-quality quant measured."""
    results = [json.loads(f.read_text()) for f in sorted(RESULTS.glob("*.json"))] if RESULTS.is_dir() else []
    for entry in catalog["models"]:
        mine = sorted((r for r in results if r["model"] == entry["id"]), key=lambda r: QUANTS.index(r["quant"]))
        if mine:
            best = mine[0]
            entry["toolScore"] = {"passRate": round(best["passed"] / best["total"], 4), "quant": best["quant"],
                                  "engine": best["engine"], "measured": best["date"]}
        else:
            entry.pop("toolScore", None)
    return catalog


def build():
    models = []
    traits = {}
    for mid, name, publisher, gguf_repo, source, mlx, tools in MODELS:
        traits[mid] = template_traits(source, gguf_repo)
        files = []
        for f in tree(gguf_repo):
            q = quant_of(f["path"]) if f["path"].endswith(".gguf") else None
            if q and "lfs" in f and not any(x["quant"] == q for x in files):
                files.append({"quant": q, "file": f["path"], "bytes": f["size"], "sha256": f["lfs"]["oid"]})
        files.sort(key=lambda x: QUANTS.index(x["quant"]))
        arch = architecture(source, gguf_repo)
        entry = {
            "id": mid, "name": name, "publisher": publisher, "licence": licence(gguf_repo),
            "toolCalling": tools, "contextMax": min(arch.pop("contextMax"), 131072),
            "architecture": arch, "gguf": {"repo": gguf_repo, "files": files},
        }
        if source:
            weights = [f for f in tree(source) if f["path"].endswith(".safetensors")]
            if weights:
                entry["source"] = {"repo": source, "bytes": sum(f["size"] for f in weights)}
        if mlx:
            variants = []
            for bits in (8, 6, 4):
                repo = f"{mlx}-{bits}bit"
                size = sum(f["size"] for f in tree(repo) if f["path"].endswith(".safetensors"))
                if size:
                    variants.append({"bits": bits, "repo": repo, "bytes": size})
            if variants:
                entry["mlx"] = variants
        models.append(entry)
        print(f"{mid}: {[f['quant'] for f in files]} source={'source' in entry} mlx={[v['bits'] for v in entry.get('mlx', [])]}", file=sys.stderr)
    return apply_profiles(apply_scores({"version": 1, "tiers": TIERS, "models": models}), traits)


if __name__ == "__main__":
    out = Path(__file__).resolve().parent.parent / "Sources/AgentGateCore/Resources/catalog.json"
    catalog = apply_profiles(apply_scores(json.loads(out.read_text()))) if "--scores" in sys.argv[1:] else build()
    out.write_text(json.dumps(catalog, indent=1) + "\n")
    print(f"wrote {out}", file=sys.stderr)
