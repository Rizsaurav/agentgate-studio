import { cpSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { z } from 'zod';
import { openDatabase } from './database';
import { DocumentService, SqliteDocuments, type Passage } from './documents';
import {
  DEFAULT_RETRIEVAL,
  HybridRetriever,
  type RetrievalModels,
  type RetrievalOptions,
} from './retrieval';
import { ProjectService } from './projects';
import { SqliteProjects } from './sqlite-projects';

/**
 * Retrieval quality on a labelled question set (#14). A question is answered by a passage from one
 * of its documents that contains its phrase. Labelling by phrase, not by chunk number, keeps the
 * labels valid when chunking changes, which is one of the experiments this measures.
 */
export const retrievalSetSchema = z
  .object({
    /** Folders, relative to the corpus root, referenced into one project. */
    corpus: z.array(z.string().min(1)).min(1),
    questions: z
      .array(
        z
          .object({
            id: z.string().regex(/^q\d{3}$/),
            /** What the question tests: lexical, paraphrase, distractor, unanswerable-near, ... */
            kind: z.string().min(1).optional(),
            question: z.string().min(1),
            /** Empty for a question nothing in the corpus answers. */
            answers: z.array(
              z
                .object({
                  document: z.string().min(1),
                  contains: z.string().min(3),
                })
                .strict(),
            ),
          })
          .strict(),
      )
      .min(1),
  })
  .strict();
export type RetrievalSet = z.infer<typeof retrievalSetSchema>;
type Question = RetrievalSet['questions'][number];

export type RetrievalMetrics = {
  answerable: number;
  unanswerable: number;
  /** Share of answerable questions whose first passage answers them. */
  hitAt1: number;
  /** Share of answerable questions with an answering passage among the first four. */
  hitAt4: number;
  /** Mean reciprocal rank of the first answering passage (0 when none). */
  mrr: number;
  /** Share of unanswerable questions for which retrieval returned nothing. */
  abstention: number;
};

/** Normalised so a phrase matches across line breaks and spacing. */
export function plain(text: string): string {
  return text.toLowerCase().replace(/\s+/g, ' ');
}

/**
 * Whether a passage holds a labelled phrase. A phrase quoting a table row ("Express | EUR 14.95") matches when
 * every cell is on one line of the passage, so labels stay valid when tables are rewritten as sentences.
 */
export function holds(passageText: string, phrase: string): boolean {
  if (!phrase.includes('|')) return plain(passageText).includes(plain(phrase));
  const cells = phrase
    .split('|')
    .map((cell) => plain(cell).trim())
    .filter(Boolean);
  return passageText
    .split('\n')
    .some((line) => cells.every((cell) => plain(line).includes(cell)));
}

/** 1-based rank of the first passage that answers `question`, or null. */
export function answerRank(
  question: Question,
  passages: Passage[],
): number | null {
  const index = passages.findIndex((passage) =>
    question.answers.some(
      (answer) =>
        passage.path === answer.document &&
        holds(passage.text, answer.contains),
    ),
  );
  return index === -1 ? null : index + 1;
}

export async function scoreRetrieval(
  set: RetrievalSet,
  retrieve: (question: string) => Promise<Passage[]>,
): Promise<{
  metrics: RetrievalMetrics;
  misses: { id: string; question: string }[];
}> {
  const answerable = set.questions.filter((q) => q.answers.length > 0);
  const unanswerable = set.questions.filter((q) => q.answers.length === 0);
  let hit1 = 0;
  let hit4 = 0;
  let reciprocal = 0;
  const misses: { id: string; question: string }[] = [];
  for (const question of answerable) {
    const rank = answerRank(
      question,
      (await retrieve(question.question)).slice(0, 4),
    );
    if (rank === 1) hit1 += 1;
    if (rank !== null) {
      hit4 += 1;
      reciprocal += 1 / rank;
    } else {
      misses.push({ id: question.id, question: question.question });
    }
  }
  let abstained = 0;
  for (const q of unanswerable)
    if ((await retrieve(q.question)).length === 0) abstained += 1;
  const share = (n: number, of: number) =>
    of === 0 ? 0 : Math.round((n / of) * 1000) / 1000;
  return {
    metrics: {
      answerable: answerable.length,
      unanswerable: unanswerable.length,
      hitAt1: share(hit1, answerable.length),
      hitAt4: share(hit4, answerable.length),
      mrr: share(reciprocal, answerable.length),
      abstention: share(abstained, unanswerable.length),
    },
    misses,
  };
}

/**
 * Indexes the corpus into a throwaway project with the real ingestion and FTS5 search, and returns
 * its retrieval. Ingestion screening is not under test here, so every passage is allowed.
 */
export async function indexCorpus(
  set: RetrievalSet,
  corpusRoot: string,
  /** With models, the production pipeline: hybrid search, reranking and the abstention gate. */
  models?: RetrievalModels,
  options: RetrievalOptions = DEFAULT_RETRIEVAL,
): Promise<{
  retrieve: (question: string) => Promise<Passage[]>;
  close: () => void;
}> {
  const work = mkdtempSync(join(tmpdir(), 'agentgate-retrieval-'));
  const docs = join(work, 'documents');
  cpSync(corpusRoot, docs, { recursive: true });
  const db = openDatabase(join(work, 'agentgate.sqlite'));
  const projectRepository = new SqliteProjects(db);
  const repository = new SqliteDocuments(db);
  const documents = new DocumentService(
    repository,
    projectRepository,
    docs,
    async () => ({ withheld: [] }),
    models ? new HybridRetriever(repository, models, options) : undefined,
  );
  const project = new ProjectService(projectRepository).create({
    name: 'Retrieval evaluation',
  });
  for (const folder of set.corpus) {
    const result = await documents.reference({
      projectId: project.id,
      path: folder,
    });
    if (result.skipped.length || result.quarantined.length)
      throw new Error(
        `The corpus folder ${folder} was not fully ingested: ${JSON.stringify(result)}`,
      );
  }
  return {
    retrieve: (question) => documents.retrieve(project.id, question),
    close: () => {
      db.close();
      rmSync(work, { recursive: true, force: true });
    },
  };
}

/** Metrics for each kind of question, for the questions that carry one. */
export async function scoreByKind(
  set: RetrievalSet,
  retrieve: (question: string) => Promise<Passage[]>,
): Promise<
  Record<string, { count: number; found: number; abstained: number }>
> {
  const kinds: Record<
    string,
    { count: number; found: number; abstained: number }
  > = {};
  for (const question of set.questions) {
    const kind =
      question.kind ??
      (question.answers.length ? 'answerable' : 'unanswerable');
    const passages = await retrieve(question.question);
    const entry = (kinds[kind] ??= { count: 0, found: 0, abstained: 0 });
    entry.count += 1;
    if (passages.length === 0) entry.abstained += 1;
    if (
      question.answers.length &&
      answerRank(question, passages.slice(0, 4)) !== null
    )
      entry.found += 1;
  }
  return kinds;
}
