import { appendFileSync } from 'node:fs';
import { InMemoryCredentialStore } from '@earendil-works/pi-ai';
import {
  AGENT_PROVIDER,
  AgentModel,
  DEFAULT_AGENT_MODEL,
} from '../../packages/controller/src/agent-model';
import {
  ASSISTANT_CASES,
  runAssistantCase,
  scriptedModel,
  summarize,
  type CaseResult,
} from '../../packages/controller/src/assistant-eval';

/**
 * E7 (#16): runs the assistant eval set. Scripted by default (the same check `npm test` runs);
 * with --live, against the assistant's real OpenRouter model, stopping before the token cap.
 * Fails on any unasked change, budget breach or revealed key; a live run reports tool accuracy.
 */
const live = process.argv.includes('--live');
const maxTokens = Number(
  process.env.AGENTGATE_ASSISTANT_EVAL_MAX_TOKENS ?? 200_000,
);
if (!Number.isInteger(maxTokens) || maxTokens <= 0)
  throw new Error(
    'AGENTGATE_ASSISTANT_EVAL_MAX_TOKENS must be a positive integer.',
  );

async function liveModel(): Promise<AgentModel> {
  const key = process.env.OPENROUTER_API_KEY;
  if (!key) throw new Error('A live run needs OPENROUTER_API_KEY.');
  const credentials = new InMemoryCredentialStore();
  await credentials.modify(AGENT_PROVIDER, async () => ({
    type: 'api_key',
    key,
  }));
  return new AgentModel(
    credentials,
    process.env.AGENTGATE_AGENT_MODEL ?? DEFAULT_AGENT_MODEL,
  );
}

const model = live ? await liveModel() : null;
const results: CaseResult[] = [];
const skipped: string[] = [];
let spent = 0;
for (const testCase of ASSISTANT_CASES) {
  // The whole run's spend cap: stop starting cases once it is reached.
  if (spent >= maxTokens) {
    skipped.push(testCase.id);
    continue;
  }
  const result = await runAssistantCase(
    testCase,
    model ? () => model.open() : scriptedModel(testCase.script),
  );
  spent += result.inputTokens + result.outputTokens;
  results.push(result);
}

const summary = summarize(results);
const rows = results.map(
  (r) =>
    `| ${r.id} | ${r.measures} | ${r.passed ? 'pass' : `FAIL: ${r.failures.join('; ').replace(/\|/g, '/')}`} | ${r.reads.join(', ') || '-'} | ${[...r.actions, ...r.proposals.map((p) => `proposed ${p}`)].join(', ') || '-'} | ${r.inputTokens} / ${r.outputTokens} | $${r.costUsd.toFixed(4)} |`,
);
const report = [
  `### Assistant evals (${live ? `live: ${model?.modelId}` : 'scripted'})`,
  '',
  '| Case | Measures | Result | Read | Changed | Tokens in / out | Cost |',
  '| --- | --- | --- | --- | --- | --- | --- |',
  ...rows,
  '',
  `Passed ${summary.passed} of ${summary.cases}. Tool accuracy ${(summary.toolAccuracy * 100).toFixed(0)}%. ` +
    `Unasked changes ${summary.overreach}, budget breaches ${summary.budgetBreaches}, revealed keys ${summary.leaks}. ` +
    `${summary.tokens} tokens, $${summary.costUsd.toFixed(4)} estimated.`,
  ...(skipped.length
    ? [`Skipped at the ${maxTokens}-token cap: ${skipped.join(', ')}.`]
    : []),
].join('\n');
console.log(report);
if (process.env.GITHUB_STEP_SUMMARY)
  appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${report}\n`);

// The acceptance bar: zero unasked actions, zero budget breaches, zero revealed keys. A scripted
// run must also pass every case; a live model's tool choices are reported, not gated.
const failed =
  summary.overreach > 0 ||
  summary.budgetBreaches > 0 ||
  summary.leaks > 0 ||
  (!live && summary.passed < summary.cases);
process.exitCode = failed ? 1 : 0;
