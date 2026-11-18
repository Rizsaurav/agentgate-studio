import { createHash } from 'node:crypto';
import type Database from 'better-sqlite3';
import { z } from 'zod';
import type { Passage } from './documents';
import { type StoredMessage, storedMessageSchema } from './sessions';

/**
 * C3 (#31): an exact-match answer cache. An answer is reused only when everything that produced it
 * is identical: the project, the model, the system prompt version and text, the project context,
 * the retrieved passages (document, position and text), the conversation so far and the question.
 *
 * The project is the permission boundary in this single-user app: no key spans two projects, and a
 * project's entries are deleted by database triggers whenever its documents, passages, context or
 * active prompt change (see ANSWER_CACHE in database.ts), so a removed or withheld document cannot
 * live on in a saved answer. Only answers that passed the output check are saved, and a reused
 * answer still goes through the input check, retrieval, passage screening and the output check.
 *
 * Exact match only: a semantic (similar-question) cache is not built, because a near match can
 * return an answer to a different question; see docs/ARCHITECTURE.md.
 */

/** Entries older than this are not reused, so an answer is never more than a day old. */
export const ANSWER_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
/** Per project; the oldest entries are dropped past this. */
export const ANSWER_CACHE_MAX_ENTRIES = 200;

export type AnswerKeyInput = {
  projectId: string;
  model: { provider: string; modelId: string };
  prompt: { version: number; text: string };
  context: string;
  passages: Passage[];
  history: StoredMessage[];
  question: string;
};

const sha256 = (text: string) =>
  createHash('sha256').update(text).digest('hex');

/** A SHA-256 of every input, in a fixed order; no part of the question or answer is readable. */
export function answerKey(input: AnswerKeyInput): string {
  return sha256(
    JSON.stringify([
      'answer-cache/1',
      input.projectId,
      input.model.provider,
      input.model.modelId,
      input.prompt.version,
      sha256(input.prompt.text),
      sha256(input.context),
      input.passages.map((p) => [p.documentId, p.seq, sha256(p.text)]),
      sha256(JSON.stringify(input.history)),
      input.question,
    ]),
  );
}

const savedSchema = z
  .object({
    answer: z.string().min(1),
    messages: z.array(storedMessageSchema).min(1),
    createdAt: z.iso.datetime(),
  })
  .strict();
export type SavedAnswer = z.infer<typeof savedSchema>;

export class AnswerCache {
  constructor(
    private readonly db: Database.Database,
    private readonly now: () => number = Date.now,
  ) {}

  find(projectId: string, key: string): SavedAnswer | null {
    const row = this.db
      .prepare(
        'SELECT answer, messages, created_at AS createdAt FROM answer_cache WHERE key = ? AND project_id = ?',
      )
      .get(key, projectId) as
      { answer: string; messages: string; createdAt: string } | undefined;
    if (!row) return null;
    if (this.now() - Date.parse(row.createdAt) >= ANSWER_CACHE_TTL_MS) {
      this.db.prepare('DELETE FROM answer_cache WHERE key = ?').run(key);
      return null;
    }
    this.db
      .prepare('UPDATE answer_cache SET hits = hits + 1 WHERE key = ?')
      .run(key);
    return savedSchema.parse({
      answer: row.answer,
      messages: JSON.parse(row.messages),
      createdAt: row.createdAt,
    });
  }

  /** Saves the model's part of a turn (everything after the user's message). */
  save(
    projectId: string,
    key: string,
    answer: string,
    messages: StoredMessage[],
  ): void {
    const value = savedSchema.parse({
      answer,
      messages,
      createdAt: new Date(this.now()).toISOString(),
    });
    this.db.transaction(() => {
      this.db
        .prepare(
          `INSERT INTO answer_cache (key, project_id, answer, messages, created_at)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(key) DO UPDATE SET answer = excluded.answer,
             messages = excluded.messages, created_at = excluded.created_at, hits = 0`,
        )
        .run(
          key,
          projectId,
          value.answer,
          JSON.stringify(value.messages),
          value.createdAt,
        );
      this.db
        .prepare(
          `DELETE FROM answer_cache WHERE project_id = ? AND key NOT IN (
             SELECT key FROM answer_cache WHERE project_id = ?
             ORDER BY created_at DESC LIMIT ?)`,
        )
        .run(projectId, projectId, ANSWER_CACHE_MAX_ENTRIES);
    })();
  }

  /** Entries per project, for tests and the purge checks. */
  count(projectId: string): number {
    return (
      this.db
        .prepare('SELECT COUNT(*) AS n FROM answer_cache WHERE project_id = ?')
        .get(projectId) as { n: number }
    ).n;
  }
}
