# AGENTGATE Studio

A local web app for running Pi agent sessions on Ollama or cloud models, with shared project context, reference RAG, and enforced security checks. Phase 1 is in progress; see the [implementation plan](docs/IMPLEMENTATION_PLAN.md) for status and limits, the [architecture](docs/ARCHITECTURE.md), and the [Phase 1 specification](docs/phase1.md).

## Setup

Requirements: Node.js 24 (`nvm use`) and npm. The setup script installs the rest after asking.

```sh
npm ci
npm run setup    # installs Ollama (Homebrew on macOS) and the security scanner if missing
npm start        # starts Ollama, the scanner, and the app, then opens the Models page
```

On the Models page, press **Install** on the model marked "Best fit" for your computer's memory. You can then start a project and a session. `npm start` builds the app on first run; use `npm start -- --rebuild` after pulling changes.

| Variable                       | Purpose                                                                                                                                                        |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AGENTGATE_DATA_DIR`           | SQLite location (default `~/.agentgate`)                                                                                                                       |
| `AGENTGATE_DOCS_ROOT`          | Only folder reference documents may be read from (default `documents/` inside the data folder; files you add in the app are saved to its `uploads/` subfolder) |
| `AGENTGATE_OLLAMA_URL`         | Ollama endpoint (default `http://127.0.0.1:11434`)                                                                                                             |
| `AGENTGATE_SCANNER_URL`        | Scanner endpoint (default `http://127.0.0.1:8765`)                                                                                                             |
| `AGENTGATE_REPO_ROOT`          | Repository folder containing `evals/` (default `../..` of the web app)                                                                                         |
| `AGENTGATE_AGENT_MODEL`        | OpenRouter model for the assistant (default `deepseek/deepseek-v4.1-flash`)                                                                                    |
| `AGENTGATE_AGENT_DAILY_TOKENS` | Most tokens the assistant may spend per day (default 150000)                                                                                                   |
| `PORT`                         | App port for `npm start` (default 3000)                                                                                                                        |

Cloud keys (Anthropic, OpenAI) are entered on the Models page, tested with one small request, and stored in the operating system's credential store, never in SQLite or on disk. Try the sample documents by referencing `rag`, and the controlled malicious document by referencing `attack`. The Models page also shows a system check that says what is not running and how to fix it.

## Assistant

The **Assistant** button in the title bar shows live status and opens a panel. A watchdog checks Ollama, the scanner, downloads and the latest evaluation every 30 seconds and restarts Ollama or the scanner for you (at most 3 tries per 10 minutes) without using any model. With an OpenRouter key (entered in the panel and stored in the operating system credential store) an AI assistant can also explain a failed evaluation or download and answer questions. It sees only system state: service status, evaluation case names and counts of blocked items, never documents, conversations or other keys. It can start services and run the evaluation suite; installing a model always waits for your approval. Token guardrails: a daily cap, at most 6 tool calls and 700 output tokens per run, a 60-second limit, each problem investigated at most once per 30 minutes and 6 times per hour, and no model call at all when the assistant is off, has no key, or is out of budget.

## Security notes

Single-user and loopback-only: do not expose it on a public interface. Mutations require a matching loopback Origin and Host. Agents have no tools. If the scanner is unreachable, document ingestion and every run fail closed and the reason is shown. Checks reduce risk but do not guarantee protection from all attacks. SQLite is not encrypted, so keep secrets out of project names, context, and documents (known credential formats are rejected).

## Verify

```sh
npm run check        # typecheck, lint, format, unit/integration tests, production build
npm run test:e2e     # Chrome end-to-end; see docs/IMPLEMENTATION_PLAN.md for the live-service variables
```

`npm run eval` runs the Promptfoo suite (needs the scanner); `npm run eval:weak` runs the deliberately weak demonstration, which must fail. Both are also on the Evaluations page.

Live-service tests are skipped unless `AGENTGATE_OLLAMA_URL` + `AGENTGATE_OLLAMA_MODEL`, `AGENTGATE_SCANNER_URL`, or `AGENTGATE_LIVE_CLOUD=1` are set.

## Known limitations

- Single user, loopback only, no authentication. SQLite is not encrypted.
- Local models: Ollama only. Cloud: Anthropic and OpenAI through Pi. A successful cloud connection and cloud run were not exercised (no paid key was available); invalid-key rejection was verified live.
- Agents have no tools: no filesystem or shell access is granted.
- Reference documents: `.md`/`.txt` files up to 200 KB from one folder (`AGENTGATE_DOCS_ROOT`), non-recursive.
- Answers appear after generation finishes, because model text is held until it has been inspected.
- Prompt-injection detection is LLM Guard's classifier (threshold 0.9). It can miss attacks and flag benign text, for example it flags credential-seeking questions such as "What is the admin key?". Deterministic rules cover only well-known credential formats, a few destructive operations, and data-carrying links.
- The tiny local models used in verification (0.4–0.5B parameters) often answer poorly even with correct context; automated tests assert retrieval, context, and enforcement, not answer quality.
- The required evaluation suite uses a scripted model fixture. It proves the application stops unsafe content whatever a model says, not that any real model behaves safely. No live-model evaluation suite exists.
- Browser E2E needs Ollama and the scanner, so it is run locally, not in CI.
- `npm run setup` installs Ollama automatically only on macOS with Homebrew; on other systems it links to the download. Model downloads are tracked in memory (Ollama resumes a partial download after a restart). Local model sizes and memory needs on the Models page are approximate.
- Ollama and the scanner are separate local processes. `npm start` runs them, and the app reports when they are unreachable.
