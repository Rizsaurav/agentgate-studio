# Retrieval baseline

`questions.json` holds 100 questions about the demo corpus (`fixtures/rag`, `fixtures/demo/policies`, `fixtures/benign`): 82 with the document and a phrase the answering passage must contain, and 18 that nothing in the corpus answers. A test checks that every phrase really is in its document.

`npm run eval:retrieval` indexes the corpus with the real ingestion and SQLite FTS5 search, asks every question, and prints:

- **hit@1** and **hit@4**: share of answerable questions with an answering passage first, or in the first four (the number the app sends to the model);
- **MRR**: mean reciprocal rank of the first answering passage;
- **abstention**: share of unanswerable questions for which retrieval returned nothing.

`--set kb` uses `questions-kb.json` instead: 152 questions about 30 documents of a fictional company (`fixtures/kb`, about 13,600 words), each tagged with a kind (lexical, paraphrase, distractor, unanswerable-near, unanswerable-far, false-premise) so the results break down by what makes a question hard. `--hybrid` adds semantic search and the reranker from the scanner service (`AGENTGATE_SCANNER_URL`), as the app runs it; `--sweep` scores every gate cutoff from one run; `recall.ts` reports whether the answer is among the candidates at all and how well the gate's score separates answerable from unanswerable questions.

The change from the baseline (`baseline{-kb}{-hybrid}.json`) is printed too, and in CI it goes to the run summary, so a pull request that touches retrieval shows its effect. A metric below the baseline fails the unit tests. When a change improves the numbers, `npm run eval:retrieval -- --update` raises the baseline, so thresholds only move up.

## Experiments

Record each one here the same way: what changed, the four numbers, and whether it was kept.

| Date       | Change                                                   | hit@1 | hit@4 | MRR   | abstention | Kept     |
| ---------- | -------------------------------------------------------- | ----- | ----- | ----- | ---------- | -------- |
| 2026-11-17 | Baseline: FTS5, bm25, 800-character chunks, top 4        | 0.915 | 1.000 | 0.951 | 0.111      | yes      |
| 2026-11-27 | Section-aware chunks with title and heading in the index | 0.915 | 0.976 | 0.936 | 0.111      | yes      |
| 2026-11-27 | kb set, keyword only                                     | 0.598 | 0.680 | 0.634 | 0.000      | baseline |
| 2026-11-27 | kb set, hybrid: fusion, mxbai reranker, gate 0.02        | 0.856 | 0.907 | 0.878 | 0.182      | yes      |
| 2026-11-27 | small set, hybrid                                        | 0.976 | 0.988 | 0.979 | 0.444      | yes      |

Section chunks cost the small set one hit@4 question but measured better on the kb set with the reranker (answer in top 4: 87 vs 85 of 97; gate AUC 0.700 vs 0.664). Model comparisons and what the answering model does with the passages are in [../grounding/README.md](../grounding/README.md).

## Limits

- The small set saturates: it shows regressions, not improvements. Use the kb set for experiments.
- Abstention here is at the retrieval level. Whether the model then declines, and whether its answers are supported by the passages, is measured live in [../grounding](../grounding/README.md).
- Hybrid numbers come from the local models; CI runs them on CPU, so the hybrid baselines allow a 0.01 tolerance.
