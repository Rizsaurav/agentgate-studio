import { randomUUID } from 'node:crypto';
import type Database from 'better-sqlite3';
import { z } from 'zod';

const MAX_NOTE_CHARS = 2000;
const KEEP_NOTES = 200;

export const noteKindSchema = z.enum([
  'question',
  'answer',
  'finding',
  'action',
  'proposal',
]);
export const agentNoteSchema = z.object({
  id: z.string(),
  createdAt: z.string(),
  kind: noteKindSchema,
  findingId: z.string().nullable(),
  text: z.string(),
  status: z.enum(['open', 'approved', 'dismissed']),
});
export type AgentNote = z.infer<typeof agentNoteSchema>;

const day = (now: Date) => now.toISOString().slice(0, 10);

/** What the assistant has said and done, its on/off switch, and the tokens it has spent today. */
export class AgentStore {
  constructor(
    private readonly db: Database.Database,
    private readonly now: () => Date = () => new Date(),
  ) {}

  enabled(): boolean {
    return this.setting('enabled') !== 'off';
  }

  setEnabled(enabled: boolean): void {
    this.saveSetting('enabled', enabled ? 'on' : 'off');
  }

  /** Whether the user has chosen local models. Until then Ollama is not started or watched. */
  usesLocalModels(): boolean {
    return this.setting('local-models') === 'on';
  }

  setUsesLocalModels(): void {
    this.saveSetting('local-models', 'on');
  }

  private setting(key: string): string | undefined {
    const row = this.db
      .prepare('SELECT value FROM agent_settings WHERE key = ?')
      .get(key) as { value: string } | undefined;
    return row?.value;
  }

  private saveSetting(key: string, value: string): void {
    this.db
      .prepare(
        'INSERT INTO agent_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      )
      .run(key, value);
  }

  tokensToday(): number {
    const row = this.db
      .prepare('SELECT tokens FROM agent_usage WHERE day = ?')
      .get(day(this.now())) as { tokens: number } | undefined;
    return row?.tokens ?? 0;
  }

  charge(tokens: number): void {
    if (!Number.isFinite(tokens) || tokens <= 0) return;
    this.db
      .prepare(
        `INSERT INTO agent_usage (day, tokens, calls) VALUES (?, ?, 1)
         ON CONFLICT(day) DO UPDATE SET tokens = tokens + excluded.tokens, calls = calls + 1`,
      )
      .run(day(this.now()), Math.round(tokens));
  }

  addNote(
    kind: AgentNote['kind'],
    text: string,
    findingId: string | null = null,
  ): AgentNote {
    const note = agentNoteSchema.parse({
      id: randomUUID(),
      createdAt: this.now().toISOString(),
      kind,
      findingId,
      text: text.slice(0, MAX_NOTE_CHARS),
      status: 'open',
    });
    this.db
      .prepare(
        'INSERT INTO agent_notes (id, created_at, kind, finding_id, text, status) VALUES (@id, @createdAt, @kind, @findingId, @text, @status)',
      )
      .run(note);
    // Bounded history: the oldest notes are dropped.
    this.db
      .prepare(
        'DELETE FROM agent_notes WHERE id NOT IN (SELECT id FROM agent_notes ORDER BY created_at DESC, rowid DESC LIMIT ?)',
      )
      .run(KEEP_NOTES);
    return note;
  }

  notes(limit: number): AgentNote[] {
    return z.array(agentNoteSchema).parse(
      this.db
        .prepare(
          `SELECT id, created_at AS createdAt, kind, finding_id AS findingId, text, status
             FROM agent_notes ORDER BY created_at DESC, rowid DESC LIMIT ?`,
        )
        .all(limit),
    );
  }

  findNote(id: string): AgentNote | undefined {
    const row = this.db
      .prepare(
        `SELECT id, created_at AS createdAt, kind, finding_id AS findingId, text, status
         FROM agent_notes WHERE id = ?`,
      )
      .get(id);
    return row === undefined ? undefined : agentNoteSchema.parse(row);
  }

  setStatus(id: string, status: AgentNote['status']): void {
    this.db
      .prepare('UPDATE agent_notes SET status = ? WHERE id = ?')
      .run(status, id);
  }

  /** When the assistant last looked into this finding, so it is not investigated again and again. */
  lastInvestigation(findingId: string): Date | null {
    const row = this.db
      .prepare(
        "SELECT created_at AS at FROM agent_notes WHERE kind = 'finding' AND finding_id = ? ORDER BY created_at DESC LIMIT 1",
      )
      .get(findingId) as { at: string } | undefined;
    return row ? new Date(row.at) : null;
  }

  investigationsSince(since: Date): number {
    const row = this.db
      .prepare(
        "SELECT COUNT(*) AS n FROM agent_notes WHERE kind = 'finding' AND created_at >= ?",
      )
      .get(since.toISOString()) as { n: number };
    return row.n;
  }
}
