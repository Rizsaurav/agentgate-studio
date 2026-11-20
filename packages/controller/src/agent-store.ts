import { randomUUID } from 'node:crypto';
import type Database from 'better-sqlite3';
import { z } from 'zod';
import { redactSecrets } from './policy';
import { SqliteSettings } from './settings';

const MAX_NOTE_CHARS = 2000;
const KEEP_NOTES = 200;
const KEEP_RUNS = 500;
/** Share of the daily cap at which the panel warns. */
export const SPEND_WARNING = 0.8;

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

export const agentRunSchema = z
  .object({
    createdAt: z.iso.datetime(),
    trigger: z.enum(['question', 'finding']),
    findingId: z.string().nullable(),
    inputTokens: z.number().int().nonnegative(),
    outputTokens: z.number().int().nonnegative(),
    /** Estimated from the provider's published prices; zero when the model lists none. */
    costUsd: z.number().nonnegative(),
    outcome: z.enum(['answered', 'stopped', 'failed']),
  })
  .strict();
export type AgentRun = z.infer<typeof agentRunSchema>;
export type SpendDay = {
  day: string;
  tokens: number;
  costUsd: number;
  calls: number;
};
export type Spending = {
  today: SpendDay;
  /** Oldest first, one entry per day including days with no use, ending today. */
  days: SpendDay[];
  week: { tokens: number; costUsd: number };
  recent: AgentRun[];
};

/** Notes are shown in the panel and sent to the browser, so credential-shaped text never survives. */
const readNote = (row: unknown): AgentNote => {
  const note = agentNoteSchema.parse(row);
  return { ...note, text: redactSecrets(note.text) };
};

const day = (now: Date) => now.toISOString().slice(0, 10);

/** What the assistant has said and done, its on/off switch, and the tokens it has spent today. */
export class AgentStore {
  private readonly settings: SqliteSettings;

  constructor(
    private readonly db: Database.Database,
    private readonly now: () => Date = () => new Date(),
  ) {
    this.settings = new SqliteSettings(db);
  }

  enabled(): boolean {
    return this.settings.get('enabled') !== 'off';
  }

  setEnabled(enabled: boolean): void {
    this.settings.set('enabled', enabled ? 'on' : 'off');
  }

  /** Whether the user has chosen local models. Until then Ollama is not started or watched. */
  usesLocalModels(): boolean {
    return this.settings.get('local-models') === 'on';
  }

  setUsesLocalModels(): void {
    this.settings.set('local-models', 'on');
  }

  tokensToday(): number {
    const row = this.db
      .prepare('SELECT tokens FROM agent_usage WHERE day = ?')
      .get(day(this.now())) as { tokens: number } | undefined;
    return row?.tokens ?? 0;
  }

  /** Adds one model call's tokens and estimated cost to today's total. */
  charge(tokens: number, costUsd = 0): void {
    if (!Number.isFinite(tokens) || tokens <= 0) return;
    const cost = Number.isFinite(costUsd) && costUsd > 0 ? costUsd : 0;
    this.db
      .prepare(
        `INSERT INTO agent_usage (day, tokens, calls, cost_usd) VALUES (?, ?, 1, ?)
         ON CONFLICT(day) DO UPDATE SET tokens = tokens + excluded.tokens, calls = calls + 1,
           cost_usd = cost_usd + excluded.cost_usd`,
      )
      .run(day(this.now()), Math.round(tokens), cost);
  }

  /** One finished assistant run; only numbers and the finding id, never question or answer text. */
  recordRun(input: Omit<AgentRun, 'createdAt'>): void {
    const run = agentRunSchema.parse({
      ...input,
      inputTokens: Math.round(input.inputTokens),
      outputTokens: Math.round(input.outputTokens),
      createdAt: this.now().toISOString(),
    });
    this.db.transaction(() => {
      this.db
        .prepare(
          `INSERT INTO agent_runs (id, created_at, trigger, finding_id, input_tokens, output_tokens, cost_usd, outcome)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          randomUUID(),
          run.createdAt,
          run.trigger,
          run.findingId,
          run.inputTokens,
          run.outputTokens,
          run.costUsd,
          run.outcome,
        );
      this.db
        .prepare(
          'DELETE FROM agent_runs WHERE id NOT IN (SELECT id FROM agent_runs ORDER BY created_at DESC, rowid DESC LIMIT ?)',
        )
        .run(KEEP_RUNS);
    })();
  }

  /** Tokens and estimated cost for today and the last `days` days, and the latest runs. */
  spending(days = 7, recentRuns = 10): Spending {
    const now = this.now();
    const keys = Array.from({ length: days }, (_, index) =>
      day(new Date(now.getTime() - (days - 1 - index) * 86_400_000)),
    );
    const rows = this.db
      .prepare(
        'SELECT day, tokens, cost_usd AS costUsd, calls FROM agent_usage WHERE day >= ?',
      )
      .all(keys[0]) as SpendDay[];
    const byDay = new Map(rows.map((row) => [row.day, row]));
    const series = keys.map(
      (key) => byDay.get(key) ?? { day: key, tokens: 0, costUsd: 0, calls: 0 },
    );
    const recent = this.db
      .prepare(
        `SELECT created_at AS createdAt, trigger, finding_id AS findingId, input_tokens AS inputTokens,
                output_tokens AS outputTokens, cost_usd AS costUsd, outcome
           FROM agent_runs ORDER BY created_at DESC, rowid DESC LIMIT ?`,
      )
      .all(recentRuns);
    return {
      today: series.at(-1)!,
      days: series,
      week: {
        tokens: series.reduce((sum, entry) => sum + entry.tokens, 0),
        costUsd: series.reduce((sum, entry) => sum + entry.costUsd, 0),
      },
      recent: z.array(agentRunSchema).parse(recent),
    };
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
      text: redactSecrets(text).slice(0, MAX_NOTE_CHARS),
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
    // Read through the redaction too, so notes written before it existed are cleaned as well.
    return this.db
      .prepare(
        `SELECT id, created_at AS createdAt, kind, finding_id AS findingId, text, status
           FROM agent_notes ORDER BY created_at DESC, rowid DESC LIMIT ?`,
      )
      .all(limit)
      .map(readNote);
  }

  findNote(id: string): AgentNote | undefined {
    const row = this.db
      .prepare(
        `SELECT id, created_at AS createdAt, kind, finding_id AS findingId, text, status
         FROM agent_notes WHERE id = ?`,
      )
      .get(id);
    return row === undefined ? undefined : readNote(row);
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
