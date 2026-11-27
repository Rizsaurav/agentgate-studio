import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  checkGrounding,
  DEFAULT_RETRIEVAL,
  DEFAULT_SCANNER_URL,
  indexCorpus,
  retrievalSetSchema,
  ScannerRetrievalModels,
} from '@agentgate/controller';

// How well the answer check tells a correct answer from a hallucinated one, on real answers a small model gave
// in live runs (`evals/grounding/run.ts --out`). An answer passes when every claim in it is supported; its score
// is its weakest claim's support. Correct answers to answerable questions should pass; answers given anyway
// to unanswerable questions should not.
//   npx tsx evals/grounding/claims.ts --set kb run1.json run2.json ...
const here = dirname(fileURLToPath(import.meta.url));
const setIndex = process.argv.indexOf('--set');
const setName = setIndex === -1 ? 'kb' : process.argv[setIndex + 1];
const files = process.argv
  .slice(2)
  .filter((a, i, all) => a !== '--set' && all[i - 1] !== '--set');
const set = retrievalSetSchema.parse(
  JSON.parse(
    readFileSync(
      join(here, '..', 'retrieval', `questions-${setName}.json`),
      'utf8',
    ),
  ),
);
const questions = new Map(set.questions.map((q) => [q.id, q]));
const declined =
  /references don.t cover|references do not cover|not (specified|mentioned|stated|provided|covered|included|listed|given)|(do|does) not (say|state|mention|specify|cover|provide|include)|don.t (say|state|mention|specify)|no (information|mention|details?)/i;

type Row = {
  id: string;
  answer: string;
  answerable: boolean;
  correct: boolean;
};
const examples = new Map<
  string,
  { id: string; answer: string; good: boolean }
>();
for (const file of files)
  for (const row of (JSON.parse(readFileSync(file, 'utf8')) as { rows: Row[] })
    .rows) {
    if (declined.test(row.answer) || row.answer.startsWith('[')) continue;
    if (row.answerable && !row.correct) continue;
    examples.set(`${row.id}\n${row.answer}`, {
      id: row.id,
      answer: row.answer,
      good: row.answerable,
    });
  }

const models = new ScannerRetrievalModels(
  process.env.AGENTGATE_SCANNER_URL ?? DEFAULT_SCANNER_URL,
);
const corpus = await indexCorpus(
  set,
  join(here, '..', '..', 'fixtures'),
  models,
  { ...DEFAULT_RETRIEVAL, minScore: 0 },
);
const scored: { good: boolean; score: number; id: string; answer: string }[] =
  [];
for (const example of examples.values()) {
  const question = questions.get(example.id);
  if (!question) continue;
  const passages = await corpus.retrieve(question.question);
  const check = await checkGrounding(example.answer, passages, models);
  const weakest = check.claims.length
    ? Math.min(...check.claims.map((c) => c.support))
    : 1;
  scored.push({
    good: example.good,
    score: weakest,
    id: example.id,
    answer: example.answer,
  });
}
corpus.close();

const good = scored.filter((s) => s.good).map((s) => s.score);
const bad = scored.filter((s) => !s.good).map((s) => s.score);
let wins = 0;
for (const g of good)
  for (const b of bad) wins += g > b ? 1 : g === b ? 0.5 : 0;
const at = (threshold: number) =>
  `kept ${good.filter((s) => s >= threshold).length}/${good.length} correct, caught ${bad.filter((s) => s < threshold).length}/${bad.length} hallucinated`;
console.log(
  `answer check AUC ${(wins / (good.length * bad.length)).toFixed(3)} on ${good.length} correct and ${bad.length} hallucinated answers`,
);
for (const t of [0.3, 0.5, 0.7, 0.9]) console.log(`  threshold ${t}: ${at(t)}`);
for (const miss of scored.filter((s) => !s.good && s.score >= 0.9))
  console.log(
    `  missed ${miss.id} (${miss.score.toFixed(2)}): ${miss.answer.slice(0, 140).replace(/\n/g, ' ')}`,
  );
