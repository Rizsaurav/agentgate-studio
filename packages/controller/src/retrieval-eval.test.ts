import { readFileSync } from 'node:fs';
import { dirname, extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { normalizeText, type Passage } from './documents';
import {
  answerRank,
  indexCorpus,
  plain,
  retrievalSetSchema,
  scoreRetrieval,
  type RetrievalMetrics,
} from './retrieval-eval';

const repo = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const evalDir = join(repo, 'evals', 'retrieval');
const set = retrievalSetSchema.parse(
  JSON.parse(readFileSync(join(evalDir, 'questions.json'), 'utf8')),
);

const passage = (path: string, text: string): Passage => ({
  documentId: '00000000-0000-4000-8000-000000000000',
  title: path,
  path,
  seq: 0,
  text,
  released: false,
});

describe('retrieval evaluation (#14)', () => {
  it('has 100 questions, some unanswerable, and every label exists in its document', () => {
    expect(set.questions).toHaveLength(100);
    expect(
      set.questions.filter((q) => q.answers.length === 0).length,
    ).toBeGreaterThanOrEqual(10);
    for (const question of set.questions)
      for (const answer of question.answers) {
        const path = join(repo, 'fixtures', answer.document);
        const text = plain(
          normalizeText(readFileSync(path, 'utf8'), extname(path)),
        );
        expect(
          text,
          `${question.id}: "${answer.contains}" is not in ${answer.document}`,
        ).toContain(plain(answer.contains));
      }
  });

  it('ranks answers by the first passage that contains the phrase from the right document', async () => {
    const question = {
      id: 'q001',
      question: 'x',
      answers: [{ document: 'a.md', contains: 'thirty days' }],
    };
    expect(
      answerRank(question, [
        passage('b.md', 'thirty days'),
        passage('a.md', 'Within  Thirty\ndays.'),
      ]),
    ).toBe(2);
    expect(answerRank(question, [passage('a.md', 'nothing here')])).toBeNull();
    const { metrics } = await scoreRetrieval(
      {
        corpus: ['x'],
        questions: [question, { id: 'q002', question: 'none', answers: [] }],
      },
      async (q) =>
        q === 'none'
          ? []
          : [passage('b.md', ''), passage('a.md', 'thirty days')],
    );
    expect(metrics).toEqual({
      answerable: 1,
      unanswerable: 1,
      hitAt1: 0,
      hitAt4: 1,
      mrr: 0.5,
      abstention: 1,
    });
  });

  it('keyword retrieval stays at or above the committed baseline', async () => {
    const corpus = await indexCorpus(set, join(repo, 'fixtures'));
    try {
      const { metrics } = await scoreRetrieval(set, corpus.retrieve);
      const baseline = JSON.parse(
        readFileSync(join(evalDir, 'baseline.json'), 'utf8'),
      ) as RetrievalMetrics;
      for (const key of ['hitAt1', 'hitAt4', 'mrr', 'abstention'] as const)
        expect(
          metrics[key],
          `${key} fell below the baseline; run npm run eval:retrieval`,
        ).toBeGreaterThanOrEqual(baseline[key]);
    } finally {
      corpus.close();
    }
  });
});
