import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  answerRank,
  DEFAULT_RETRIEVAL,
  DEFAULT_SCANNER_URL,
  indexCorpus,
  retrievalSetSchema,
  ScannerRetrievalModels,
} from '@agentgate/controller';

// Where retrieval loses an answer: in candidate search (not among the reranker's inputs) or in reranking
// (among them, but not ranked into the top 4). `npx tsx evals/retrieval/recall.ts --set kb [--candidates 30]`.
const here = dirname(fileURLToPath(import.meta.url));
const arg = (name: string) => {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? undefined : process.argv[index + 1];
};
const setName = arg('set');
const set = retrievalSetSchema.parse(
  JSON.parse(
    readFileSync(
      join(here, setName ? `questions-${setName}.json` : 'questions.json'),
      'utf8',
    ),
  ),
);
const pool = Number(arg('candidates') ?? DEFAULT_RETRIEVAL.rerank);
const models = new ScannerRetrievalModels(
  process.env.AGENTGATE_SCANNER_URL ?? DEFAULT_SCANNER_URL,
);
const corpus = await indexCorpus(
  set,
  join(here, '..', '..', 'fixtures'),
  models,
  {
    ...DEFAULT_RETRIEVAL,
    rerank: pool,
    limit: pool,
    minScore: 0,
    keepScore: 0,
  },
);
let inPool = 0;
let top4 = 0;
const answerable = set.questions.filter((q) => q.answers.length > 0);
const lost: string[] = [];
for (const question of answerable) {
  const passages = await corpus.retrieve(question.question);
  const rank = answerRank(question, passages);
  if (rank !== null) inPool += 1;
  else lost.push(`${question.id} ${question.kind ?? ''}`);
  if (rank !== null && rank <= 4) top4 += 1;
}
// How well the best reranker score separates answerable from unanswerable questions: the gate's job.
const best = async (q: string) => (await corpus.retrieve(q))[0]?.score ?? 0;
const yes: number[] = [];
const no: number[] = [];
for (const question of set.questions)
  (question.answers.length ? yes : no).push(await best(question.question));
corpus.close();
let pairs = 0;
let wins = 0;
for (const a of yes)
  for (const b of no) {
    pairs += 1;
    wins += a > b ? 1 : a === b ? 0.5 : 0;
  }
const cuts = [...new Set([...yes, ...no])].sort((a, b) => a - b);
let pick = { cut: 0, kept: 0, refused: 0, score: -1 };
for (const cut of cuts) {
  const kept = yes.filter((s) => s >= cut).length / yes.length;
  const refused = no.filter((s) => s < cut).length / no.length;
  // Refusing an unanswerable question matters as much as answering an answerable one.
  if (kept + refused > pick.score)
    pick = { cut, kept, refused, score: kept + refused };
}
console.log(
  `gate AUC ${(wins / pairs).toFixed(3)}; best cut ${pick.cut.toFixed(4)} keeps ${(pick.kept * 100).toFixed(0)}% of answerable, refuses ${(pick.refused * 100).toFixed(0)}% of unanswerable`,
);
console.log(
  `candidates ${pool}: answer among them ${inPool}/${answerable.length}, reranked into top 4 ${top4}/${answerable.length}`,
);
console.log(`not among the candidates: ${lost.join(', ')}`);
