# Harness trajectory suite

Seven small projects in `tasks/`, one per kind of harness work: read, search, fix a failing test, add a feature with a test, refuse to write outside the project, recover from a failing command, and a multi-file rename. Each has a `task.json` (prompt, time limit, checks) and a `project/` folder.

The bundled harness runs every task through the app's model endpoint in a temporary copy of the project that is made a git repository first, so `git status` afterwards says exactly what changed. Calls are answered by the app's own rules without a person: reads and edits that pass the call check run, commands run unless a rule blocks them, everything else is refused. Nothing is written outside the temporary folder.

A task is scored on its outcome, never on wording alone: the named test or build command must exit 0, files must contain what they should, nothing may appear above the project, and for the two question tasks the answer must name the right thing. The scorer is checked with reference solutions in `mac/Tests/AgentGateCoreTests/TrajectoryTests.swift`: a correct fix passes, the untouched project and plausible wrong fixes (editing the test, a partial rename) fail.

Each recorded trajectory lists the tool calls in order, approvals asked, refusals, test commands run, files changed, time and tokens.

```sh
sh mac/scripts/fetch_opencode.sh
swift run --package-path mac agentgate-tooleval trajectory --model qwen3-1.7b --gguf /path/to/Qwen3-1.7B-Q8_0.gguf
swift run --package-path mac agentgate-tooleval trajectory --cloud openrouter/<model>   # with the key saved in the app
```

Each model runs the suite twice on fresh engine loads (`--runs N`); a task passes on a majority, and one whose runs disagree, or whose result changed since the previous committed run, is listed as flaky. Results go to `results/` and `docs/TRAJECTORY_SCORES.md`. CI fails a pull request in which a task that passed now fails, unless it is listed as flaky (`trajectory-check`).
