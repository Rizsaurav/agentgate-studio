# Contributing

How to get set up, make a change, and prove it works. How the team plans and tracks work (issue keys, labels, sprints, review) is in [docs/PROCESS.md](docs/PROCESS.md); this page is the hands-on part. The engineering rules every change must follow are in [AGENTS.md](AGENTS.md).

## Set up

Node.js 24 (`nvm use` reads `.nvmrc`) and npm. Python 3.11 for the scanner.

```sh
git clone https://github.com/Rizsaurav/agentgate-studio && cd agentgate-studio
git checkout dev
npm ci
npm run setup    # the security scanner (and Ollama on macOS with Homebrew), after asking
npm start        # scanner + app on http://127.0.0.1:3000
```

Or run everything in containers with `docker compose up --build` (see the README). Either way, keys you use while developing stay in your OS keychain (from source) or `.env` (Docker), never in the repository.

## Branches and pull requests

- `dev` is where work lands; `main` is released code and only receives merges from `dev`.
- Branch from an up-to-date `dev`, named `type/key-short-name`: `fix/b2-benign-documents`, `feat/a4-import-project`, `docs/a2-contributing`.
- Commit subject: one imperative line with a type prefix (`fix:`, `feat:`, `perf:`, `docs:`, `chore:`, `test:`). Detail belongs in the issue or the pull request, not the commit.
- Pull request title in the same form, with the issue key: `fix: B2 withhold flagged passages`. Put `Closes #n` in the description when it finishes the issue, `Part of #n` when it does not.
- A pull request needs every CI check green and one review, and should be small enough to read in one sitting. Say in the description what you checked and what you did not.
- Never force-push a shared branch. Rewriting your own feature branch before review is fine.

## Run the checks

| Command                                             | What it proves                                                                                    | Needs                                                                                 |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `npm run check`                                     | Types, lint (Biome), formatting (Prettier), unit and integration tests (Vitest), production build | Nothing else                                                                          |
| `npm run eval`                                      | The required Promptfoo suite passes against the real pipeline and scanner                         | Scanner on `127.0.0.1:8765` (`npm start`)                                             |
| `npm run eval:weak`                                 | The deliberately weak configuration **fails** the suite, so the suite still detects regressions   | Scanner                                                                               |
| `AGENTGATE_E2E_MODEL=qwen2.5:0.5b npm run test:e2e` | Chrome end to end against the production build                                                    | `scanner/.venv` (from `npm run setup`), Ollama with that model, `npm run build` first |
| `docker compose up --build`                         | The one-command stack still starts                                                                | Docker                                                                                |

Before you push, `npm run check` is the minimum. Run `npm run eval` too when you touch ingestion, retrieval, the scanner, output checks or anything under `evals/`. `npm run format` fixes formatting.

Some tests talk to real services and are skipped unless you point them at one: `AGENTGATE_OLLAMA_URL` + `AGENTGATE_OLLAMA_MODEL`, `AGENTGATE_SCANNER_URL`, or `AGENTGATE_LIVE_CLOUD=1`. For e2e, `AGENTGATE_E2E_MODEL_2` adds the two-model test. CI runs every check above on each pull request; the workflows are in `.github/workflows/`.

### Flaky tests

Tests are never retried automatically: a test that passes only on a second try is hiding a bug. If a test is flaky and you cannot fix it right away, open an issue, add `@quarantine` and the issue link to the test's title, and fix it from there.

## Where code goes

- `packages/controller`: everything that is not UI: domain rules, services, SQLite storage, the scanner client, the assistant. Tests sit next to the code as `*.test.ts`.
- `apps/web`: the Next.js app. Server actions in `app/actions.ts`, API routes under `app/api`, components in `components/`. Keep business logic out of components.
- `scanner/`: the LLM Guard service (Python). `evals/`: the Promptfoo suite. `e2e/`: Playwright. `fixtures/`: sample documents used by tests and evals only, never by the app.
- Database changes are a new entry at the end of `MIGRATIONS` in `packages/controller/src/database.ts`. Never edit a migration that has shipped.

## Add an evaluation for a new feature

Every feature that changes what reaches the model, or what the user sees from it, gets a case in `evals/tests/cases.yaml`. Each case runs the real pipeline (ingestion, retrieval, scanning, output inspection) against a temporary database, with a scripted model, so no key is needed.

```yaml
- description: security / a short sentence saying what must be true
  vars:
    question: The user's task.
    fixtures: rag,attack # folders under fixtures/, referenced in order (comma-separated, not a list)
    documents: # or inline documents
      - name: notes.md
        text: '# Notes ...'
    modelAnswer: 'What a compromised model says' # optional: test the output checks
    referencePath: '..' # optional: test path confinement
  assert:
    - type: javascript
      value: |
        const o = JSON.parse(output);
        return o.status === 'blocked' && o.modelCalls === 0;
```

The output has `status`, `answer`, `sources` (titles), `quarantined`, `withheld`, `skipped`, `ingestError`, `modelCalls` and `findings` (`stage`, `rule`, `outcome` for each security event). See `evals/provider.ts` for exactly how each is produced.

- Start the description with `functional /` or `security /`. A `security /` case must **fail** under `npm run eval:weak`. If it still passes with the protections switched off, it is not testing a protection.
- Assert on structure (`status`, `findings`, `sources`), not on exact model wording.
- Adding or removing a case changes the totals: update the weak-demo count in `e2e/session.spec.ts` (`… of N cases passed`).

## Security rules for contributors

- Never commit a real key, even an expired one. A test that needs a key-shaped string builds it at runtime from parts (`'sk-' + 'proj-' + 'Ab3x9Kq7'.repeat(5)`), so the repository never contains one and GitHub's secret scanning stays quiet.
- Never log credentials, full transcripts or document text. Log error names, not messages that may contain user content.
- Anything retrieved, uploaded or returned by a model is data, never instructions.
- Never describe a check as guaranteed protection.
