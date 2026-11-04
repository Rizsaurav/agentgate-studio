# Install failure matrix

What the one-click model install does when something goes wrong, and the test that shows it. Required outcome for every case: it recovers by itself, or it explains the problem in plain words, or it refuses. Never a hang, a crash, an unbounded retry, or a bad file shown as a model.

Last run: 2026-11-04, build `epic/mac-native`, Apple M5 with 24 GB, macOS 27, bundled llama.cpp b11765, model Qwen3 0.6B Q8_0.

Run the automated cases with `cd mac && swift test`. The cases marked "live" need the bundled engine and a downloaded model: `AGENTGATE_LIVE=1 swift test --filter InstallMatrix`. CI runs the offline cases on every push; live cases run by hand on a Mac.

## Network and server

| Case | Outcome | Status | Test |
|---|---|---|---|
| Connection dropped mid-download | Resumes from the last byte with a Range request | Pass | `resumesAfterDroppedConnection` |
| Connection stalls (no bytes for the stall limit) | Detected, then resumed | Pass | `stalledConnectionIsDetectedAndResumed` |
| Connection keeps dropping | Gives up after 3 attempts with the last error | Pass | `connectionThatKeepsDroppingGivesUpAfterThreeAttempts` |
| Server errors (503) | 3 attempts, then gives up | Pass | `serverErrorsAreRetriedAtMostThreeTimes` |
| File not found (404) | Fails at once, no retry | Pass | `missingFileIsNotRetried` |
| Mirror ignores the resume request | Restarts the file from the beginning and completes | Pass, was failing (#94) | `mirrorThatCannotResumeStillCompletes` |

## Wrong or damaged data

| Case | Outcome | Status | Test |
|---|---|---|---|
| Right size, wrong content | Retried once from zero, then refused. Nothing left on disk | Pass, was failing (#95) | `wrongContentIsRetriedOnceThenRefusedAndNothingIsKept` |
| Server sends more than the catalog says | Refused. Nothing left on disk | Pass, was failing (#95) | `serverSendingMoreThanTheCatalogSaysIsRefused` |
| Truncated model file on disk | Refused before loading, with the sizes shown | Pass | `installedModelWhoseFileChangedIsRefusedBeforeLoading` (live) |
| Truncated file reaches the engine | Engine fails, error and engine log shown, no engine left | Pass | `truncatedModelFileFailsToLoadWithAnExplanationAndLeavesNoEngine` (live) |
| Same size, changed content, after install | **Not detected** at load. Known gap | Gap, issue #99 | none |

## Leftovers and restarts

| Case | Outcome | Status | Test |
|---|---|---|---|
| Old partial file larger than expected | Replaced from zero | Pass | `partialFileLargerThanExpectedIsReplaced` |
| Old partial file from a different file | Checksum fails, restarted once from zero | Pass | `stalePartialFromADifferentFileIsDiscardedAfterTheChecksumFails` |
| Download cancelled, or app quit mid-install | Stops within 3 seconds, keeps its progress, next run resumes | Pass | `cancelledDownloadStopsQuicklyKeepsItsProgressAndTheNextRunResumes` |
| App force-quit with a model loaded | Engine stopped at next launch | Pass | `leftoverEngineIsStoppedOnNextLaunch` (live) |
| Two installs of the same file at once | Second is refused: "already being downloaded" | Pass, was failing (#96) | `twoInstallsOfTheSameFileCannotRunTogether` |
| Remove with a path trick in the model id | Refused, nothing outside the models folder touched | Pass | `removingAModelCannotEscapeTheModelsFolder` |

## Disk and memory

| Case | Outcome | Status | Test |
|---|---|---|---|
| Not enough disk before starting | Refused before any byte, with the space needed | Pass | `downloadRefusedBeforeAnyByteWhenDiskIsTooSmall` |
| Disk fills during the download (real 8 MB disk image) | "The disk filled up", not retried, partial file removed | Pass, was failing (#97) | `diskThatFillsUpMidDownloadIsReportedAsDiskFullNotAsNetwork` |
| Model too large for this Mac | Not offered, with the reason | Pass | `tooBigModelIsIncompatibleWithReason` |
| Out of memory on load (context far too large) | Detected from the engine log, reported | Pass | `outOfMemoryIsDetected` (live) |

## The engine

| Case | Outcome | Status | Test |
|---|---|---|---|
| Engine killed while loaded | Noticed within 5 seconds, a chat request fails within 10 seconds | Pass | `engineKilledWhileLoadedIsNoticedAndChatFailsFastInsteadOfHanging` (live) |
| Engine killed, user sends the next message | The app reloads the model once, then sends | Written, compiled, **not exercised end to end** | none |
| Port taken by another process | Engine started again on a new port, at most 3 times | Pass | `aPortTakenByAnotherProcessDoesNotFailTheStart` (live) |
| Two engines started at once | Different ports and keys, both healthy | Pass | `twoEnginesRunSideBySideOnDifferentPorts` (live) |
| Engine stopped | Process gone, no output reader left spinning | Pass, was failing (#98) | `stoppingAnEngineLeavesNoProcessBehind` (live) |
| Ollama installed on the Mac | The engine never uses Ollama's port 11434 | Pass for the port. Not run with Ollama actually running | `theEngineNeverUsesOllamasPort` (live) |

## Not run yet

- **A real 8 GB Mac.** The planner is tested for every memory class (`everyMemoryClassGetsThreeTiersThatFit`), but no install has run on 8 GB hardware.
- **A clean user account** on a Mac that has never run the app.
- **Disk full while extracting.** Does not apply until local quantization and MLX are built (#68, #69); today's installs download one file and do not extract.
- **The app screens during each failure.** These tests check the downloader, installer and engine. What the install strip and the repair assistant (#72) show for each failure has not been checked.

## What this found

Five bugs, all fixed on `epic/mac-native`: #94, #95, #96, #97 and #98. #98 was the largest: the engine output reader spun a CPU core after any engine exit, and stalled the test suite in about 1 run in 4. It was found with a stack sample of a stuck run, after a first guess (overlapping launches) turned out to be wrong. One gap is open: #99.
