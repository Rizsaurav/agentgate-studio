import { cpSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { z } from 'zod';
import { openDatabase } from './database';
import { DocumentService, SqliteDocuments, type Passage } from './documents';
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

/** 1-based rank of the first passage that answers `question`, or null. */
export function answerRank(
  question: Question,
  passages: Passage[],
): number | null {
  const index = passages.findIndex((passage) =>
    question.answers.some(
      (answer) =>
        passage.path === answer.document &&
        plain(passage.text).includes(plain(answer.contains)),
    ),
  );
  return index === -1 ? null : index + 1;
}

export function scoreRetrieval(
  set: RetrievalSet,
  retrieve: (question: string) => Passage[],
): { metrics: RetrievalMetrics; misses: { id: string; question: string }[] } {
  const answerable = set.questions.filter((q) => q.answers.length > 0);
  const unanswerable = set.questions.filter((q) => q.answers.length === 0);
  let hit1 = 0;
  let hit4 = 0;
  let reciprocal = 0;
  const misses: { id: string; question: string }[] = [];
  for (const question of answerable) {
    const rank = answerRank(question, retrieve(question.question).slice(0, 4));
    if (rank === 1) hit1 += 1;
    if (rank !== null) {
      hit4 += 1;
      reciprocal += 1 / rank;
    } else {
      misses.push({ id: question.id, question: question.question });
    }
  }
  const abstained = unanswerable.filter(
    (q) => retrieve(q.question).length === 0,
  ).length;
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
): Promise<{ retrieve: (question: string) => Passage[]; close: () => void }> {
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
