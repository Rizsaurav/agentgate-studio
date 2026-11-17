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
  "messages": [{ "role": "user", "content": "What is the weather in Paris right now?" }],
  "expect": { "calls": [{ "name": "get_weather", "arguments": { "city": { "contains": "paris" } } }] }
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
