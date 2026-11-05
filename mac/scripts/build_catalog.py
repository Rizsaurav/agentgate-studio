#!/usr/bin/env python3
"""Build mac/Sources/AgentGateCore/Resources/catalog.json from the Hugging Face API.

Run after changing MODELS or TIERS. Sizes, checksums and architecture come from Hugging Face,
so the catalog never carries hand-typed numbers.
"""
import json
import sys
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


def get(path):
    try:
        with urllib.request.urlopen(f"https://huggingface.co/{path}", timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code in (401, 404):
            return None
        raise


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


def build():
    models = []
    for mid, name, publisher, gguf_repo, source, mlx, tools in MODELS:
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
    return {"version": 1, "tiers": TIERS, "models": models}


if __name__ == "__main__":
    out = Path(__file__).resolve().parent.parent / "Sources/AgentGateCore/Resources/catalog.json"
    out.write_text(json.dumps(build(), indent=1) + "\n")
    print(f"wrote {out}", file=sys.stderr)
