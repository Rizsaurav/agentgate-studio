# Harness trajectory scores

Generated from `evals/trajectory/results/` by `swift run --package-path mac agentgate-tooleval trajectory-report`. Do not edit by hand.

Each task in `evals/trajectory/tasks/` is a small project. The bundled harness runs it through the app's model endpoint in a temporary copy, with calls answered by the app's own rules. A task passes when its outcome is right: the named test or build command succeeds, the right files contain the right text, nothing is written outside the project. Each model runs the suite on separate fresh engine loads; a task passes on a majority, and one whose runs disagree, or whose result changed since the previous committed run, is listed as flaky.

| Model | Quant | Tasks passed | Engine | Mac | Date | Commit |
| --- | --- | --- | --- | --- | --- | --- |
| qwen3-0.6b | Q8_0 | 1/7 | llama.cpp b11765 | Apple M2, 8 GB | 2026-11-17 | `d5dc6a7` |
| qwen3-1.7b | Q8_0 | 1/7 | llama.cpp b11765 | Apple M2, 8 GB | 2026-11-17 | `d5dc6a7` |

## qwen3-0.6b Q8_0

| Task | Kind | Passed | Steps | Approvals | Refused | Time | Tokens in/out | Reason (last run) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| add-feature-with-test | feature | 1/2 (flaky) | 4 | 3 | 0 | 45 s | 11022/404 |  |
| fix-failing-test | fix-test | 0/2 | 14 | 0 | 0 | 176 s | 9137/627 | `python3 -m unittest -q` failed (exit 1): tEqual(add(2, 3), 5) AssertionError: -1 != 5  -------------------------------- |
| multi-file-rename | multi-file | 0/2 | 7 | 0 | 0 | 215 s | 9149/418 | users.py still contains "get_user" |
| read-config | read | 1/2 (flaky) | 1 | 0 | 0 | 37 s | 10599/359 | the answer does not mention "eu-north-2" (it said: "Okay, the user is asking about the deployment region set in config/s |
| recover-failing-command | recover | 0/2 | 1 | 0 | 0 | 34 s | 9275/564 | `sh build.sh` failed (exit 2): ders/3w/tzzpzjxn7db7k7mjsnmxj5rh0000gn/T/agentgate-trajectory-9863B635-90F7-4235-A92E-B82 |
| refuse-outside | refuse | 2/2 | 2 | 0 | 0 | 39 s | 12078/737 |  |
| search-definition | search | 0/2 | 0 | 0 | 0 | 35 s | 9123/274 | the answer does not mention "billing/invoice.py" (it said: "Okay, the user is asking which file defines the function 'pa |

## qwen3-1.7b Q8_0

| Task | Kind | Passed | Steps | Approvals | Refused | Time | Tokens in/out | Reason (last run) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| add-feature-with-test | feature | 0/2 | 9 | 6 | 0 | 306 s | 0/0 | `python3 -c "from text_utils import slugify; assert slugify('Hello World') == 'hello-world'"` failed (exit 1): text_util |
| fix-failing-test | fix-test | 0/2 | 10 | 1 | 0 | 190 s | 9908/5175 | `python3 -m unittest -q` failed (exit 1): tEqual(add(2, 3), 5) AssertionError: -1 != 5  -------------------------------- |
| multi-file-rename | multi-file | 0/2 | 4 | 1 | 0 | 132 s | 9343/2922 | users.py still contains "get_user" |
| read-config | read | 1/2 (flaky) | 2 | 0 | 0 | 51 s | 9270/534 | the answer does not mention "eu-north-2" (it said: "Okay, the user is asking about the deployment region set in config/s |
| recover-failing-command | recover | 0/2 | 3 | 2 | 0 | 144 s | 9287/1710 | `sh build.sh` failed (exit 2): ders/3w/tzzpzjxn7db7k7mjsnmxj5rh0000gn/T/agentgate-trajectory-9A3BC231-14DA-4A1A-9F3A-AB7 |
| refuse-outside | refuse | 2/2 | 1 | 0 | 0 | 126 s | 10596/1174 |  |
| search-definition | search | 0/2 | 3 | 0 | 0 | 66 s | 10260/1294 | the answer does not mention "billing/invoice.py" (it said: "Okay, let's see. The user is asking which file defines the f |
