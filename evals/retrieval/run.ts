import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  indexCorpus,
  retrievalSetSchema,
  scoreRetrieval,
  type RetrievalMetrics,
} from '@agentgate/controller';

// Retrieval baseline (#14): `npm run eval:retrieval` prints the metrics and their change from the
// committed baseline; `-- --update` writes them as the new baseline once a change improves them.
const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const set = retrievalSetSchema.parse(
  JSON.parse(readFileSync(join(here, 'questions.json'), 'utf8')),
);
const baselinePath = join(here, 'baseline.json');
const keys = ['hitAt1', 'hitAt4', 'mrr', 'abstention'] as const;

const corpus = await indexCorpus(set, join(repo, 'fixtures'));
const { metrics, misses } = scoreRetrieval(set, corpus.retrieve);
corpus.close();

// Only a missing file means "no baseline yet"; a baseline that cannot be read is an error.
const baseline: RetrievalMetrics | null = existsSync(baselinePath)
  ? (JSON.parse(readFileSync(baselinePath, 'utf8')) as RetrievalMetrics)
  : null;
if (!baseline) console.log('No baseline yet.');
const lines = [
  `Retrieval on ${metrics.answerable} answerable and ${metrics.unanswerable} unanswerable questions`,
  '',
  '| Metric | Baseline | Now | Change |',
  '| --- | --- | --- | --- |',
  ...keys.map((key) => {
    const before = baseline?.[key];
    const delta =
      before === undefined
        ? ''
        : (metrics[key] - before >= 0 ? '+' : '') +
          (metrics[key] - before).toFixed(3);
    return `| ${key} | ${before?.toFixed(3) ?? '–'} | ${metrics[key].toFixed(3)} | ${delta} |`;
  }),
  '',
  misses.length
    ? `Not found in the top 4: ${misses.map((m) => `${m.id} "${m.question}"`).join('; ')}`
    : 'Every answerable question was found in the top 4.',
];
console.log(lines.join('\n'));
if (process.env.GITHUB_STEP_SUMMARY)
  writeFileSync(process.env.GITHUB_STEP_SUMMARY, `${lines.join('\n')}\n`, {
    flag: 'a',
  });

if (process.argv.includes('--update')) {
  writeFileSync(baselinePath, `${JSON.stringify(metrics, null, 2)}\n`);
  console.log(`Baseline written to ${baselinePath}.`);
} else if (baseline && keys.some((key) => metrics[key] < baseline[key])) {
  console.error('A retrieval metric is below the baseline.');
  process.exitCode = 1;
}
