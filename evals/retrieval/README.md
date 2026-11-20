# Retrieval baseline

`questions.json` holds 100 questions about the demo corpus (`fixtures/rag`, `fixtures/demo/policies`, `fixtures/benign`): 82 with the document and a phrase the answering passage must contain, and 18 that nothing in the corpus answers. A test checks that every phrase really is in its document.

`npm run eval:retrieval` indexes the corpus with the real ingestion and SQLite FTS5 search, asks every question, and prints:

- **hit@1** and **hit@4**: share of answerable questions with an answering passage first, or in the first four (the number the app sends to the model);
- **MRR**: mean reciprocal rank of the first answering passage;
- **abstention**: share of unanswerable questions for which retrieval returned nothing.

The change from `baseline.json` is printed too, and in CI it goes to the run summary, so a pull request that touches retrieval shows its effect. A metric below the baseline fails the unit tests. When a change improves the numbers, `npm run eval:retrieval -- --update` raises the baseline, so thresholds only move up.

## Experiments

Record each one here the same way: what changed, the four numbers, and whether it was kept.

| Date       | Change                                            | hit@1 | hit@4 | MRR   | abstention | Kept |
| ---------- | ------------------------------------------------- | ----- | ----- | ----- | ---------- | ---- |
| 2026-11-17 | Baseline: FTS5, bm25, 800-character chunks, top 4 | 0.915 | 1.000 | 0.951 | 0.111      | yes  |

## Limits

- The corpus is about 550 words, a dozen chunks, so hit@4 saturates. It shows regressions but cannot show whether hybrid search or reranking helps. A larger corpus (#21) is needed before those experiments.
- Abstention here is at the retrieval level: keyword search returns something for most questions it cannot answer. Whether the model then declines, and whether its answers cite a retrieved passage (groundedness), needs a live model and belongs with the nightly live suite (#17).
