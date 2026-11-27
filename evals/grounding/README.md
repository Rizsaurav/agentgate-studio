# Grounding evaluation

Retrieval numbers say whether the right passage was found. These evaluations say what a real model then does with it: answer from it, decline, or make something up.

## The pipeline being measured

1. **Hybrid retrieval** (`packages/controller/src/retrieval.ts`): keyword search (SQLite FTS5, bm25) and semantic search (embeddings) each return 40 candidates; reciprocal rank fusion merges them; a cross-encoder reranks the top 30.
2. **Gate**: if the best passage's reranker score is below `minScore` (0.02), nothing is retrieved and the model is told the documents do not answer the question, with one fixed reply allowed. Further passages need `keepScore` (0.01) to go along.
3. **Grounded prompt** (`groundedQuestion`): numbered excerpts with their section, the question before and after them, a find-then-answer instruction, a citation per fact, and the fixed reply `The references don't cover this.`
4. **Answer check** (`checkGrounding`): every sentence of the answer is checked by an entailment model against each excerpt sentence, each pair of neighbouring sentences, and the whole excerpt. A sentence needs 0.9 support.
5. **One revision, then removal**: unsupported sentences are named back to the model once; whatever is still unsupported is removed. If nothing is left, the reply is the fixed one. A `grounding` event in the run trace records what happened.

The three local models run in the scanner service (`scanner/retrieval.py`), pinned to exact revisions:

| Role         | Model                                        | Download |
| ------------ | -------------------------------------------- | -------- |
| Embeddings   | BAAI/bge-small-en-v1.5                       | 133 MB   |
| Reranker     | mixedbread-ai/mxbai-rerank-base-v1           | 369 MB   |
| Answer check | MoritzLaurer/DeBERTa-v3-base-mnli-fever-anli | 369 MB   |

## Running it

Needs the scanner (`scanner/server.py`) and an OpenAI-compatible model server (llama-server, Ollama, LM Studio).

```sh
AGENTGATE_SCANNER_URL=http://127.0.0.1:8766 AGENTGATE_EVAL_MODEL=qwen3-1.7b \
  npx tsx evals/grounding/run.ts --set kb --mode full --out run.json
npx tsx evals/grounding/claims.ts --set kb run.json      # how well the check separates good and bad answers
npx tsx evals/retrieval/recall.ts --set kb               # candidate recall and how well the gate separates
```

`--mode keyword` uses keyword search only, `gated` adds hybrid retrieval and the gate, and `full` adds the answer check. The question set is `evals/retrieval/questions-kb.json`: 152 questions about 30 documents of a fictional company (`fixtures/kb`). 97 are answerable (lexical, paraphrase, distractor); 55 are not (near misses, unrelated, false premises).

## Results

Qwen3 1.7B (Q8_0) on llama-server, the smallest model the app offers. "Answered anyway" is the share of unanswerable questions that got an answer instead of the fixed reply.

| Setup                                                 | Answerable correct | Wrongly declined | Answered anyway |
| ----------------------------------------------------- | ------------------ | ---------------- | --------------- |
| Keyword search, strict prompt                         | 56.7%              | 37.1%            | 3.6%            |
| Hybrid, gate 0.1, check                               | 61.9%              | 28.9%            | 3.6%            |
| Hybrid, gate 0.02, check                              | 66.0%              | 27.8%            | 16.4%           |
| **Hybrid, gate 0.02, check, find-then-answer prompt** | **75.3%**          | **20.6%**        | **12.7%**       |

The answers counted as "answered anyway" in the last row: two correct a false premise from the documents (the return window is 14 days, not 30; Care Fleet cannot be paused), three state a true fact about a neighbouring thing (another bike's light, the battery capacity instead of its weight, the recovery objective instead of the replication lag), and one turns a per-minute limit into a daily quota. Every sentence in them is supported by an excerpt; what they miss is that the excerpt is about something else. That is the open problem, below.

## Experiments

| Change                                                                                    | Measured                                                                                                                                                                                      | Kept                                                                                    |
| ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Hybrid retrieval with reranker, over keyword search                                       | answer in top 4: 68.0% to 92.8% (ungated)                                                                                                                                                     | yes                                                                                     |
| Rerankers compared (gate AUC; answer in top 4 of 97)                                      | MiniLM-L6 0.712, 86; **mxbai-rerank-base 0.781, 91**; gte-modernbert 0.757, 92; granite-r2 0.683, 88; bge-base 0.693, 84; mxbai-xsmall 0.698, 87                                              | mxbai-base                                                                              |
| Embedding models compared (answer among 40 candidates)                                    | bge-small 96/97, granite-small-r2 95, gte-modernbert 96, granite-r2 96, bge-base 96, modernbert-embed 96: fusion with keyword search saturates recall                                         | bge-small, the smallest                                                                 |
| Answer checkers compared (AUC on 132 correct and 36 hallucinated real answers)            | DeBERTa-v3-xsmall 0.846; ModernBERT zero-shot 0.852; tasksource small 0.830; **DeBERTa-v3-base mnli-fever-anli 0.910**; MiniCheck RoBERTa-L 0.844; MiniCheck DeBERTa-L 0.934 at 2.4x the size | DeBERTa-v3-base: at 0.9 it keeps 123/132 correct answers and catches 29/36 hallucinated |
| Check against sentences, neighbour pairs and the whole excerpt, instead of whole excerpts | correct table answers no longer removed                                                                                                                                                       | yes                                                                                     |
| Tables written as "Header: cell" sentences at ingestion                                   | table answers checkable                                                                                                                                                                       | yes                                                                                     |
| Strict prompt when the gate finds nothing (no general-knowledge answers)                  | answered anyway: a third of unanswerable to 3.6%                                                                                                                                              | yes                                                                                     |
| Gate 0.1 vs 0.02                                                                          | 0.1 drops reworded questions with the answer at rank 1; with the stricter prompt 0.02 answers more                                                                                            | 0.02                                                                                    |
| Prompt layouts, same excerpts (correct on 31 reworded questions)                          | rules then excerpts 9; question before and after 11; **find the sentence, then answer 16**; same plus "must be the exact thing asked" 14                                                      | find-then-answer                                                                        |
| Temperature 0 for answers from documents                                                  | no measurable change on this set; kept for reproducible answers                                                                                                                               | yes                                                                                     |
| Reply when the question names something no excerpt mentions                               | caught none of the 7 and would block 3 correct answers                                                                                                                                        | no                                                                                      |

## Open problems

- **Off-target but true answers.** The answer check asks whether the excerpt supports the sentence, not whether the sentence answers the question. A sentence like "The integrated front light produces 70 lux" is supported by the Halcy 52 manual even when the question asked about the Halcy 40. Checking the claim with the question's subject filled in needs a rewrite of each claim, which costs a model call per answer.
- **Reworded questions the model still declines.** 18 of 35 paraphrase questions; for most of them the answering passage is in the excerpts. Larger models decline less.
- These are measurements on one corpus and one small model. They show the pipeline reduces made-up answers; they are not a guarantee that none get through.
