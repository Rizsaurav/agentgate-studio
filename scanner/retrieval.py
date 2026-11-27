"""Local models for retrieval and grounding, beside the injection scanner.

Three small models, each loaded on first use and pinned to an exact revision:

- an embedding model, for semantic search next to keyword search;
- a cross-encoder reranker, which reads a question and a passage together and scores how well the passage
  answers it; its score also decides when nothing in the documents answers the question;
- a natural-language-inference model, which checks whether a passage supports a sentence of the answer.

Everything runs on this machine; texts are never logged. Policy (thresholds, what to show) stays in the
Node controller: these functions return numbers only.
"""

import os
import threading

import torch
from transformers import AutoModel, AutoModelForSequenceClassification, AutoTokenizer

# (model id, pinned revision). Overridable for experiments; the defaults are what the evaluation measured.
EMBED = (
    os.environ.get("AGENTGATE_EMBED_MODEL", "BAAI/bge-small-en-v1.5"),
    os.environ.get("AGENTGATE_EMBED_REVISION", "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"),
)
RERANK = (
    os.environ.get("AGENTGATE_RERANK_MODEL", "mixedbread-ai/mxbai-rerank-base-v1"),
    os.environ.get("AGENTGATE_RERANK_REVISION", "800f24c113213a187e65bde9db00c15a2bb12738"),
)
NLI = (
    os.environ.get("AGENTGATE_NLI_MODEL", "MoritzLaurer/DeBERTa-v3-base-mnli-fever-anli"),
    os.environ.get("AGENTGATE_NLI_REVISION", "6f5cf0a2b59cabb106aca4c287eed12e357e90eb"),
)
# What each embedding model expects: an instruction in front of a search query or a passage, and how its token
# vectors become one vector (first token, or the mean of all tokens).
QUERY_PREFIX = {
    "BAAI/bge-small-en-v1.5": "Represent this sentence for searching relevant passages: ",
    "BAAI/bge-base-en-v1.5": "Represent this sentence for searching relevant passages: ",
    "Snowflake/snowflake-arctic-embed-s": "Represent this sentence for searching relevant passages: ",
    "Snowflake/snowflake-arctic-embed-m-v1.5": "Represent this sentence for searching relevant passages: ",
    "nomic-ai/modernbert-embed-base": "search_query: ",
}
PASSAGE_PREFIX = {"nomic-ai/modernbert-embed-base": "search_document: "}
MEAN_POOLING = {"nomic-ai/modernbert-embed-base"}
DEVICE = os.environ.get("AGENTGATE_RETRIEVAL_DEVICE") or ("mps" if torch.backends.mps.is_available() else "cpu")
BATCH = 32
MAX_TOKENS = 512

_lock = threading.Lock()
_loaded = {}


def _load(kind, spec, model_class):
    with _lock:
        if kind not in _loaded:
            name, revision = spec
            tokenizer = AutoTokenizer.from_pretrained(name, revision=revision)
            model = model_class.from_pretrained(name, revision=revision).to(DEVICE).eval()
            _loaded[kind] = (tokenizer, model)
        return _loaded[kind]


def _batches(items):
    for start in range(0, len(items), BATCH):
        yield items[start : start + BATCH]


@torch.inference_mode()
def embed(texts, query=False):
    """Unit-length vectors, CLS pooled. Queries get the model's search instruction."""
    tokenizer, model = _load("embed", EMBED, AutoModel)
    prefix = QUERY_PREFIX.get(EMBED[0], "") if query else PASSAGE_PREFIX.get(EMBED[0], "")
    vectors = []
    for batch in _batches([prefix + text for text in texts]):
        inputs = tokenizer(batch, padding=True, truncation=True, max_length=MAX_TOKENS, return_tensors="pt").to(DEVICE)
        states = model(**inputs).last_hidden_state
        if EMBED[0] in MEAN_POOLING:
            mask = inputs["attention_mask"].unsqueeze(-1).to(states.dtype)
            hidden = (states * mask).sum(1) / mask.sum(1).clamp(min=1)
        else:
            hidden = states[:, 0]
        vectors += torch.nn.functional.normalize(hidden, dim=-1).float().cpu().tolist()
    return vectors


@torch.inference_mode()
def rerank(query, texts):
    """How well each text answers the query, 0 to 1 (sigmoid of the cross-encoder's logit)."""
    tokenizer, model = _load("rerank", RERANK, AutoModelForSequenceClassification)
    scores = []
    for batch in _batches(texts):
        inputs = tokenizer([query] * len(batch), batch, padding=True, truncation=True, max_length=MAX_TOKENS,
                           return_tensors="pt").to(DEVICE)
        logits = model(**inputs).logits[:, 0]
        scores += torch.sigmoid(logits).float().cpu().tolist()
    return scores


@torch.inference_mode()
def entail(pairs):
    """For each (premise, hypothesis): probabilities that the premise entails or contradicts the hypothesis."""
    tokenizer, model = _load("nli", NLI, AutoModelForSequenceClassification)
    labels = {str(label).lower(): int(index) for index, label in model.config.id2label.items()}
    # Three-way NLI models name "entailment"; binary fact checkers name "supported" or just "1" (MiniCheck).
    supports = next((labels[name] for name in ("entailment", "supported", "1") if name in labels), len(labels) - 1)
    results = []
    for batch in _batches(pairs):
        inputs = tokenizer([p for p, _ in batch], [h for _, h in batch], padding=True, truncation=True,
                           max_length=MAX_TOKENS, return_tensors="pt").to(DEVICE)
        probs = torch.softmax(model(**inputs).logits, dim=-1).float().cpu()
        for row in probs:
            results.append({
                "entailment": float(row[supports]),
                "contradiction": float(row[labels["contradiction"]]) if "contradiction" in labels else 0.0,
            })
    return results


def models():
    return {"embed": EMBED[0], "rerank": RERANK[0], "nli": NLI[0], "device": DEVICE}


def preload():
    """Downloads (once) and loads all three models, so the first question does not wait minutes for them."""
    embed(["warm up"], query=True)
    rerank("warm up", ["warm up"])
    entail([("warm up", "warm up")])
