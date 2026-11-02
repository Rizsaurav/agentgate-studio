# AGENTGATE Studio

A local web app for running Pi agent sessions on Ollama or cloud models, with shared project context, reference RAG, and enforced security checks. Phase 1 is in progress; see the [implementation plan](docs/IMPLEMENTATION_PLAN.md) for status and limits, the [architecture](docs/ARCHITECTURE.md), and the [Phase 1 specification](docs/phase1.md).

## Run it

Pick one. All three end at the same app on `http://localhost:3000` (Docker: the same, unless `PORT` is set).

### 1. Docker (the same for every teammate)

Needs Docker Desktop (or Docker Engine with Compose). On macOS install [Ollama](https://ollama.com/download) on your computer too, so models use your GPU; the container talks to it.

```sh
cp .env.example .env          # optional: add OPENROUTER_API_KEY to turn on the assistant
docker compose up --build     # first run downloads the scanner model (about 700 MB)
```

Open http://localhost:3000, go to Models, and install the model it recommends. Stop with `docker compose down` (your data stays in a volume; `down -v` deletes it). To run Ollama in a container as well (CPU only on macOS and Windows): set `AGENTGATE_OLLAMA_URL=http://ollama:11434` in `.env` and use `docker compose --profile ollama up --build`. Only port 3000 is published, on `127.0.0.1`.

### 2. From source

Requirements: Node.js 24 (`nvm use`) and npm. The setup script installs the rest after asking.

```sh
npm ci
npm run setup    # installs Ollama (Homebrew on macOS) and the security scanner if missing
npm start        # starts the scanner and the app (and Ollama if you already have local models), then opens the Models page
```

### 3. Mac app

`cd desktop && npm ci && npm run build` creates `desktop/release/AGENTGATE Studio-*/AGENTGATE Studio.app`. It starts only the web app, so Ollama and the scanner must already be running (see [issue tracker](../../issues) for the planned first-run setup).

### First five minutes

1. **Models**: press Install on the model marked Best fit for this computer.
2. **Projects**: create one, then open References and add a `.md` or `.txt` file.
3. **Start a session**, pick the model, and ask a question about your document.
4. **Security & Verification**: see what was blocked, and run the evaluation suite.
5. **Assistant** (title bar): add an OpenRouter key to get explanations and automatic fixes.

### Troubleshooting

| Symptom                                     | Fix                                                                                                            |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Tasks say "Blocked ... scanner-unavailable" | The scanner is not running. `npm start` or `docker compose up` starts it; the first start downloads its model. |
| No models in the picker                     | Add an API key on Models, or install a local model there (that starts Ollama).                                 |
| Port 3000 is in use                         | `PORT=3100 npm start`, or `PORT=3100 docker compose up`.                                                       |
| Docker: models never appear                 | Ollama must run on your computer (`ollama serve`) or use the `ollama` profile above.                           |
| Keys                                        | From source: stored in your OS keychain. Docker: set them in `.env` (a container has no keychain).             |

## Settings

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

The **Assistant** button in the title bar shows live status and opens a panel. A watchdog checks the scanner, downloads, the latest evaluation and (once you use local models) Ollama every 30 seconds and restarts Ollama or the scanner for you (at most 3 tries per 10 minutes) without using any model. With an OpenRouter key (entered in the panel and stored in the operating system credential store) an AI assistant can also explain a failed evaluation or download and answer questions. It sees only system state: service status, evaluation case names and counts of blocked items, never documents, conversations or other keys. It can start services and run the evaluation suite; installing a model always waits for your approval. Token guardrails: a daily cap, at most 6 tool calls and 700 output tokens per run, a 60-second limit, each problem investigated at most once per 30 minutes and 6 times per hour, and no model call at all when the assistant is off, has no key, or is out of budget.

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
- Models: any of OpenRouter, Anthropic, OpenAI, Google Gemini, Groq, DeepSeek, Mistral or xAI with an API key, and Ollama for local models. You need only one. A full chat through OpenRouter was verified; the other providers use the same Pi SDK path but were not run with real keys.
- Agents have no tools: no filesystem or shell access is granted.
- Reference documents: `.md`/`.txt` files up to 200 KB from one folder (`AGENTGATE_DOCS_ROOT`), non-recursive.
- Answers appear after generation finishes, because model text is held until it has been inspected.
- Prompt-injection detection is LLM Guard's classifier (threshold 0.9). It can miss attacks and flag benign text, for example it flags credential-seeking questions such as "What is the admin key?". Deterministic rules cover only well-known credential formats, a few destructive operations, and data-carrying links.
- The tiny local models used in verification (0.4–0.5B parameters) often answer poorly even with correct context; automated tests assert retrieval, context, and enforcement, not answer quality.
- The required evaluation suite uses a scripted model fixture. It proves the application stops unsafe content whatever a model says, not that any real model behaves safely. No live-model evaluation suite exists.
- Browser E2E needs Ollama and the scanner, so it is run locally, not in CI.
- `npm run setup` installs Ollama automatically only on macOS with Homebrew; on other systems it links to the download. Model downloads are tracked in memory (Ollama resumes a partial download after a restart). Local model sizes and memory needs on the Models page are approximate.
- Ollama and the scanner are separate local processes. Ollama starts only when you install or use a local model; `npm start` starts the scanner, and the app reports when either is unreachable.
