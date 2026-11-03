# Architecture

```mermaid
flowchart LR
  UI[Next.js UI] --> Controller[Local Node controller]
  Controller --> SQLite[(SQLite)]
  Controller --> Runner[Bounded run queue]
  Runner --> Pi[Pi agent runtime]
  Pi --> Models[Ollama / cloud provider planned]
  Runner --> Security[Protection pipeline]
  Security --> Scanner[LLM Guard scanner service]
  Controller --> EvalWorker[Bounded eval worker]
  EvalWorker --> Eval[Promptfoo suite]
  Eval --> Security
```

Implemented in A1: `apps/web` owns UI and server-action transport; `packages/controller/src/projects.ts` owns project rules and typed contracts; `sqlite-projects.ts` owns persistence and schema migration. The controller validates request and repository outputs. SQLite is the canonical owner of project metadata. The Node server uses one controller instance per process, retained through development reloads.

Planned Phase 1 flow: Web UI → Local Controller → Pi Agent Runtime → Selected Model. Context management stores goals, approved decisions, and references to verified results. A bounded local worker will run model tasks and evaluations independently of HTTP requests. Security checks inputs, retrieved documents, outputs, and approved tool operations. Promptfoo uses the same application protection path in the dashboard and CI.

The user's explicit LLM Guard selection supersedes Prompt Guard 2 from the original specification. A small Python adapter may host LLM Guard. The Node controller retains orchestration and state ownership. Scanner failures must fail closed. Treat documents as data; never execute their instructions. Do not duplicate histories or policies across services.

Provider, scanner, and evaluation contracts will be added with their first real integrations, not as speculative interfaces. Credential storage must use a protected local mechanism, preferably the OS store, and never return saved keys to the browser.

Implemented in A2: `RunService` drains a durable SQLite queue one run at a time, with a hard deadline, cancellation, and recovery of runs interrupted by a restart. It drives a Pi `Agent` with no tools against a model from `OllamaCatalog`, which verifies the model is actually installed. Run events are rows in SQLite; the UI reads them over a resumable SSE route, so a dropped browser connection never affects the run. SQLite owns the conversation history.

Implemented in B: one structured context record per project (goals, approved decisions, verified outcomes) is rendered into every run's system prompt, so switching models keeps it. `DocumentService` ingests `.md`/`.txt` files confined to one reference folder into SQLite FTS5; retrieval is project-scoped and bm25-ranked, and withheld passages are excluded. Text is normalised before chunking (invisible characters removed, layout whitespace collapsed), so the scanner and the model read the same text. Retrieved excerpts are labelled untrusted and added to the model call only, never stored in history. Deterministic secret rules keep credentials out of context and documents.

Implemented in C: `ProtectionPipeline` combines application-owned deterministic rules with the LLM Guard prompt-injection scanner, which runs as a separate loopback Python service (`scanner/`) returning scores only. The run loop calls it at input, on retrieved passages, and on the complete answer before any text is emitted; every passage is scanned at ingestion, and only flagged passages are withheld (a document is quarantined only when all of its passages are). The user can review a withheld passage on the project page and release it; the release is recorded as a security event and that passage is not scanned again. Scanner failures are mapped to a blocked outcome. Decisions are persisted as security events.

Implemented in D: `EvalService` runs the repository's Promptfoo suite as a bounded child process and persists configuration identity and per-case results. The suite's provider drives the same `RunService`, `DocumentService`, and `ProtectionPipeline` the app uses, with a scripted model fixture. GitHub Actions runs the identical `npm run eval`.
