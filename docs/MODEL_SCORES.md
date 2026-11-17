# Tool-calling scores

Generated from `evals/tools/results/` by `swift run --package-path mac agentgate-tooleval report`. Do not edit by hand.

Each model is run on the bundled engine against the 45-case suite in `evals/tools/cases/`, at temperature 0 with a fixed seed. A case passes when the calls the model makes (names and arguments) or its refusal to call match what the case expects; prose is never graded. A model needs 75% to be offered as **Ready** for agent sessions; below that it is **Chat only**.
Each case runs 3 times and passes on a majority. The engine is not bit-for-bit repeatable even at temperature 0, so a case whose runs disagree is listed as flaky below.


| Model | Quant | Pass rate | Readiness | single | selection | multiple | missing-argument | nested | parallel | recovery | long-output | refusal | Engine | Mac | Date | Commit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| qwen3-0.6b | Q8_0 | 71% | Chat only | 5/6 | 4/5 | 3/5 | 4/5 | 5/5 | 5/5 | 1/5 | 1/4 | 4/5 | llama.cpp b11765 | Apple M2, 8 GB | 2026-11-17 | `fb9080c` |
| qwen3-1.7b | Q8_0 | 76% | Ready | 6/6 | 4/5 | 5/5 | 5/5 | 4/5 | 5/5 | 0/5 | 2/4 | 3/5 | llama.cpp b11765 | Apple M2, 8 GB | 2026-11-17 | `fb9080c` |

## Flaky cases

- qwen3-0.6b-Q8_0: `long-users-then-lookup`, `missing-recipient`, `multiple-search-and-tests`
- qwen3-1.7b-Q8_0: `nested-event-attendees`, `recovery-currency-code`
