# How we work

This mirrors how product teams run a sprint. Use it as written; change it by pull request.

## Work items

| Term                         | Meaning                                                                                                | Where it lives                                                   |
| ---------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------- |
| **Vision**                   | Why the product exists and where it goes.                                                              | Issue #34                                                        |
| **Epic**                     | A large outcome that takes several issues and more than one sprint. One epic per product area, A to F. | An issue titled `[EPIC X] name` with a checklist of its children |
| **Issue** (story, task, bug) | One piece of work a single person can finish in a few days.                                            | An issue titled `[A1] ...`                                       |
| **Sprint**                   | A fixed period with a goal.                                                                            | A milestone: Sprint 1, 2, 3                                      |

An issue key is the epic letter plus a number (`B2`). Put it in the issue title, the branch name and the pull request title so work can be traced end to end.

| Epic | Area                    |
| ---- | ----------------------- |
| A    | Onboarding and desktop  |
| B    | Security and guardrails |
| C    | RAG and pipeline        |
| D    | Assistant               |
| E    | Evals and telemetry     |
| F    | CI/CD and release       |

## Labels (kept small on purpose)

Every issue has exactly one of each:

- **Type:** `type: feature`, `type: bug`, `type: chore`, `type: docs`, `type: test`
- **Area:** `area: onboarding`, `area: security`, `area: rag`, `area: assistant`, `area: evals`, `area: cicd` (matches the epic)
- **Priority:** `P0` blocker, `P1` this sprint, `P2` next sprint, `P3` later

Optional: `blocked`, `good first issue`, `help wanted`. The sprint is the milestone, never a label.

## Issue template

Context, current state (with measurements), tasks as a checklist, acceptance criteria, and how it is measured. An issue is ready when someone else could start it without asking questions. It is done when its acceptance criteria are met, its evaluation is in place, and the change is merged to `dev`.

## Branches and releases

- `main` is the shared branch. Pull requests may target `main` directly.
- `dev` is an optional staging branch for larger changes that need testing together first.
- Work branches come from `main` (or `dev`), named `type/key-short-name`, for example `fix/b2-benign-documents`.
- No direct pushes to `main`. Never force-push a shared branch.

## Commits and pull requests

- One short subject line in the imperative with a type prefix: `fix:`, `feat:`, `perf:`, `docs:`, `chore:`, `test:`.
- Pull request title follows the same form. Link the issue with `Closes #n`.
- A pull request needs green CI and one review from a teammate, and is small enough to read in one sitting.
- Do not request a Copilot review. It uses the requester's own Copilot quota and fails when that quota runs out. Turn off automatic Copilot reviews in your GitHub settings (Settings, Copilot, Features: "Automatic Copilot code review").
- Keep detail in the issue, not in the commit message.

## Sprint rhythm

Plan the sprint by moving issues into its milestone and assigning owners, work in small pull requests, and close the sprint by reviewing what shipped against the milestone. Anything unfinished moves to the next sprint with its priority reconsidered.
