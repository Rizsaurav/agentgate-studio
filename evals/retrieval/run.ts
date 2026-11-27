import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_RETRIEVAL,
  DEFAULT_SCANNER_URL,
  indexCorpus,
  retrievalSetSchema,
  ScannerRetrievalModels,
  scoreByKind,
  scoreRetrieval,
  type RetrievalMetrics,
} from '@agentgate/controller';

// Retrieval evaluation (#14).
//   npm run eval:retrieval                       keyword search on questions.json (no models needed)
//   npm run eval:retrieval -- --hybrid           the production pipeline: hybrid search, reranker, abstention gate
//   npm run eval:retrieval -- --set kb           another question set (questions-kb.json)
//   npm run eval:retrieval -- --hybrid --sweep   abstention gate thresholds side by side
//   ... -- --update                              write the metrics as the new baseline for this set and mode
// The hybrid mode needs the scanner service (AGENTGATE_SCANNER_URL, default http://127.0.0.1:8765).
const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const arg = (name: string) => {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? undefined : process.argv[index + 1];
};
const hybrid = process.argv.includes('--hybrid');
const setName = arg('set');
const set = retrievalSetSchema.parse(
  JSON.parse(
    readFileSync(
      join(here, setName ? `questions-${setName}.json` : 'questions.json'),
      'utf8',
    ),
  ),
);
const suffix = `${setName ? `-${setName}` : ''}${hybrid ? '-hybrid' : ''}`;
const baselinePath = join(here, `baseline${suffix}.json`);
const keys = ['hitAt1', 'hitAt4', 'mrr', 'abstention'] as const;
// Model scores differ in the last digits between a Mac's GPU and a CI machine's CPU; keyword search does not.
const tolerance = hybrid ? 0.01 : 0;
const models = hybrid
  ? new ScannerRetrievalModels(
      process.env.AGENTGATE_SCANNER_URL ?? DEFAULT_SCANNER_URL,
    )
  : undefined;

if (process.argv.includes('--sweep')) {
  if (!models) throw new Error('--sweep needs --hybrid.');
  // Every question is reranked once with no gate; each threshold is then applied to the same scores.
  const corpus = await indexCorpus(set, join(repo, 'fixtures'), models, {
    ...DEFAULT_RETRIEVAL,
    minScore: 0,
    keepScore: 0,
    limit: DEFAULT_RETRIEVAL.rerank,
  });
  const ranked = new Map<string, Awaited<ReturnType<typeof corpus.retrieve>>>();
  for (const question of set.questions)
    ranked.set(question.question, await corpus.retrieve(question.question));
  corpus.close();
  const lines = [
    '| minScore | keepScore | hit@1 | hit@4 | MRR | abstention |',
    '| --- | --- | --- | --- | --- | --- |',
  ];
  for (const keepScore of [0.01, 0.05])
    for (const minScore of [
      0, 0.02, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6,
    ]) {
      const { metrics } = await scoreRetrieval(set, async (question) => {
        const all = ranked.get(question) ?? [];
        if ((all[0]?.score ?? 0) < minScore) return [];
        return all
          .filter((p, i) => i === 0 || (p.score ?? 0) >= keepScore)
          .slice(0, DEFAULT_RETRIEVAL.limit);
      });
      lines.push(
        `| ${minScore} | ${keepScore} | ${metrics.hitAt1.toFixed(3)} | ${metrics.hitAt4.toFixed(3)} | ${metrics.mrr.toFixed(3)} | ${metrics.abstention.toFixed(3)} |`,
      );
    }
  console.log(lines.join('\n'));
  process.exit(0);
}

const corpus = await indexCorpus(set, join(repo, 'fixtures'), models);
// Each question is retrieved once; the overall and per-kind scores read the same results.
const results = new Map<string, ReturnType<typeof corpus.retrieve>>();
const retrieve = (question: string) => {
  const cached = results.get(question) ?? corpus.retrieve(question);
  results.set(question, cached);
  return cached;
};
const started = performance.now();
const { metrics, misses } = await scoreRetrieval(set, retrieve);
const perQuestionMs = (performance.now() - started) / set.questions.length;
const kinds = await scoreByKind(set, retrieve);
corpus.close();

// Only a missing file means "no baseline yet"; a baseline that cannot be read is an error.
const baseline: RetrievalMetrics | null = existsSync(baselinePath)
  ? (JSON.parse(readFileSync(baselinePath, 'utf8')) as RetrievalMetrics)
  : null;
if (!baseline) console.log('No baseline yet.');
const lines = [
  `Retrieval (${hybrid ? 'hybrid, reranked, gated' : 'keyword'}) on ${metrics.answerable} answerable and ${metrics.unanswerable} unanswerable questions, ${perQuestionMs.toFixed(0)} ms per question`,
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
  '| Kind | Questions | Answer in top 4 | No passages |',
  '| --- | --- | --- | --- |',
  ...Object.entries(kinds).map(
    ([kind, k]) => `| ${kind} | ${k.count} | ${k.found} | ${k.abstained} |`,
  ),
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
} else if (
  baseline &&
  keys.some((key) => metrics[key] < baseline[key] - tolerance)
) {
  console.error('A retrieval metric is below the baseline.');
  process.exitCode = 1;
}
