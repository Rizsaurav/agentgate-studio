# Performance budgets

What "fast" means for AGENTGATE Studio, how it was measured, and what is still open (#6). Budgets are for a local production build (`npm run build && npm start`) on a normal laptop; model time is never counted, because it depends on the model.

## Budgets

| What                                          | Budget                                                                        |
| --------------------------------------------- | ----------------------------------------------------------------------------- |
| Server first byte, every page                 | p95 under 150 ms                                                              |
| Client navigation between pages               | under 100 ms                                                                  |
| Run start to first token, excluding the model | under 300 ms                                                                  |
| Scanner check of a typical passage            | under 250 ms                                                                  |
| Any page                                      | never waits on a network call or a child process before showing local content |

## Measured

**Pages** (2026-11-04, Linux x64, production build, empty database, no Ollama, Hugging Face unreachable), first byte over three requests:

| Page             | First byte | Notes                                                                          |
| ---------------- | ---------- | ------------------------------------------------------------------------------ |
| `/`              | 21–25 ms   |                                                                                |
| `/models`        | 53–56 ms   | Renders the providers panel twice (in the page and in the title bar)           |
| `/security`      | 20–39 ms   |                                                                                |
| Evaluations      | 26–37 ms   | First visit finished after 0.94 s: the GitHub part streams in after first byte |
| `/api/assistant` | 4–59 ms    | First call starts the watchdog                                                 |

All within budget on this machine. It cannot show the suspected costs: no keychain, no Ollama, no NVIDIA driver, and no route to Hugging Face. Measure on a Mac before closing #6.

**Database lookups** with a realistic history (20 projects, 1,000 sessions, 20,000 runs, 60,000 security events, 60,000 passages), mean of 200 calls:

| Lookup                   | Before   | After    | Runs on                          |
| ------------------------ | -------- | -------- | -------------------------------- |
| Security events of a run | 3.185 ms | 0.008 ms | Every session page view          |
| Passages of a document   | 1.703 ms | 0.018 ms | Reviewing and releasing passages |
| Runs of a session        | 0.662 ms | 0.015 ms | Every session page view          |
| Next queued run          | 0.661 ms | 0.002 ms | Every worker poll                |
| Sessions of a project    | 0.058 ms | 0.031 ms | Every project page view          |

Before, each of these scanned the whole table, so it grew with every run ever made. The indexes are migration `LOOKUP_INDEXES` in `packages/controller/src/database.ts`; `performance.test.ts` fails if any of these lookups stops using its index.

**Hardware probe:** `nvidia-smi` is started at most once every 10 minutes instead of on every page view (it can take up to its 3-second timeout). Memory and free disk are still read each time.

## How to measure

```sh
npm run build && AGENTGATE_DATA_DIR=$(mktemp -d) PORT=3460 npm run start:web
for p in / /models /security "/security?view=evaluations"; do
  curl -s -o /dev/null -w "$p first byte %{time_starttransfer}s, done %{time_total}s\n" "http://127.0.0.1:3460$p"
done
```

For a query, run `EXPLAIN QUERY PLAN <sql>` in `sqlite3 ~/.agentgate/agentgate.sqlite`. `SCAN <table>` without `USING INDEX`, or `USE TEMP B-TREE FOR ORDER BY`, means it reads the whole table.

## Still open in #6

- **Render the providers panel only when it is opened.** The root layout renders it on every page, which reads the keychain for each provider, lists Ollama models and asks Hugging Face for the model list (cached for an hour). Waiting for #55, which reworks the same components.
- **`Server-Timing`** headers and a timing log for each pipeline stage.
- **Paginate** the Security findings and the assistant activity feed (both are bounded today: 100 events and 30 notes).
- **Bundle size** per route, with a limit.
