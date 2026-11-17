# Tool-calling reliability suite

Measures how reliably each catalog model calls tools through the bundled engine (llama.cpp's OpenAI-compatible server). The result decides **Ready** versus **Chat only** in the model picker. The published table is [docs/MODEL_SCORES.md](../../docs/MODEL_SCORES.md).

## Layout

- `tools.json`: the tool definitions (OpenAI function format) the cases may offer.
- `cases/<category>.json`: the cases, one file per category: `single`, `selection` (wrong tools offered), `multiple`, `missing-argument`, `nested`, `parallel`, `recovery` (a tool error the model must recover from), `long-output`, `refusal` (a tool the model must not call, including an instruction injected into a tool result).
- `results/<model>-<quant>.json`: one file per measured model, committed.

A case lists the tools offered, the chat messages to send, and what a correct reply is:

```json
{
  "id": "single-weather",
  "category": "single",
  "description": "One tool, one obvious argument.",
  "tools": ["get_weather"],
  "messages": [
    { "role": "user", "content": "What is the weather in Paris right now?" }
  ],
  "expect": {
    "calls": [
      {
        "name": "get_weather",
        "arguments": { "city": { "contains": "paris" } }
      }
    ]
  }
}
```

`expect` is either `calls` (exactly these calls; any order unless `"ordered": true`) or `"noCall": true` (optionally with `answerContains`). An argument match sets one of `equals`, `contains` (text, ignoring case), `object` (nested matches) or `present`. Scoring checks the structure of the reply, never the wording of prose. A malformed suite is rejected as a whole.

The cases are JSON rather than Promptfoo YAML because the runner is part of the Swift app: it starts models with the same `LlamaRuntime` the app uses, and Foundation has no YAML parser.

## Running

From the repository root, with the engine fetched (`sh mac/scripts/fetch_runtime.sh`):

```sh
swift run --package-path mac agentgate-tooleval run --model qwen3-1.7b --gguf /path/to/Qwen3-1.7B-Q8_0.gguf   # one model
swift run --package-path mac agentgate-tooleval run --all        # every model installed in the app
python3 mac/scripts/build_catalog.py --scores                     # copy the scores into the catalog
```

`run` regenerates `docs/MODEL_SCORES.md`. No network and no cloud key are needed once the model file is on disk.

Each model runs at temperature 0 with seed 42, on 3 fresh loads of the engine; a case passes on a majority. llama.cpp on Metal is repeatable within one load but not exactly across loads, so a case whose runs disagree, or whose result differs from the previous committed run, is listed as flaky in the results and the table.

## Thresholds and CI

- Ready needs a pass rate of at least `ToolSuite.readyPassRate` (75%). A measured model below it is installed as Chat only even if the one-call install check passed. Unmeasured models keep the install check's result.
- CI fails a pull request that lowers a committed model's pass rate by more than `ToolSuite.regressionMargin` (5 points) or deletes its results, compared with the target branch (`agentgate-tooleval check`).
- Unit tests fail when the results were measured on a different set of cases, when `docs/MODEL_SCORES.md` is stale, or when the catalog's scores differ from the results.

## Nightly catalog refresh

`.github/workflows/catalog-refresh.yml` runs every night (and on demand from the Actions tab):

1. Rebuilds `catalog.json` from Hugging Face with `mac/scripts/build_catalog.py` (each request is retried at most three times; the job stops after 120 minutes).
2. Compares it with the committed catalog with `mac/scripts/catalog_diff.py`. A changed checksum for a file already in the catalog **fails the job** and nothing is proposed, because the upstream file may have been replaced. New, changed and removed models, licence changes, and gated or removed repositories are listed in the report.
3. Scores each new or changed tool-calling model with this suite, using the best file under 3 GB, on the runner's CPU (`agentgate-tooleval run --cpu --loads 1`), at most two models per run. Larger or further models are listed for a run on a Mac. On CPU a 0.6B model takes about half an hour; long-output cases can take minutes per request, so CPU mode allows 15 minutes per request. A run where any request fails writes no results rather than counting it as a wrong answer.
4. Opens a pull request with the catalog diff, the results and the report. It never merges. A change that is already proposed (same catalog) is not proposed again.

Scheduled workflows run only from the default branch, so the nightly run starts once this workflow reaches `main`. Pull requests opened with the workflow token do not start CI; close and reopen the pull request to run the checks.
