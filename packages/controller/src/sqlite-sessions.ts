import { randomUUID } from 'node:crypto';
import type Database from 'better-sqlite3';
import { z } from 'zod';
import {
  modelRefSchema,
  runEventSchema,
  runSchema,
  sessionSchema,
  storedMessageSchema,
  type ModelRef,
  type Run,
  type RunEvent,
  type Session,
  type SessionRepository,
  type StoredMessage,
} from './sessions';

const SESSION_COLUMNS =
  'id, project_id AS projectId, provider, model_id AS modelId, created_at AS createdAt';
const RUN_COLUMNS =
  'id, session_id AS sessionId, prompt, status, error, created_at AS createdAt, finished_at AS finishedAt';

type SessionRow = {
  id: string;
  projectId: string;
  provider: string;
  modelId: string;
  createdAt: string;
};
function toSession(row: SessionRow): Session {
  return sessionSchema.parse({
    id: row.id,
    projectId: row.projectId,
    model: modelRefSchema.parse({
      provider: row.provider,
      modelId: row.modelId,
    }),
    createdAt: row.createdAt,
  });
}

export class SqliteSessions implements SessionRepository {
  constructor(private readonly db: Database.Database) {}

  createSession(projectId: string, model: ModelRef): Session {
    const session = sessionSchema.parse({
      id: randomUUID(),
      projectId,
      model,
      createdAt: new Date().toISOString(),
    });
    this.db
      .prepare(
        'INSERT INTO sessions (id, project_id, provider, model_id, created_at) VALUES (?, ?, ?, ?, ?)',
      )
      .run(
        session.id,
        projectId,
        model.provider,
        model.modelId,
        session.createdAt,
      );
    return session;
  }

  findSession(id: string): Session | null {
    const row = this.db
      .prepare(`SELECT ${SESSION_COLUMNS} FROM sessions WHERE id = ?`)
      .get(id) as SessionRow | undefined;
    return row === undefined ? null : toSession(row);
  }

  listSessions(projectId: string): Session[] {
    const rows = this.db
      .prepare(
        `SELECT ${SESSION_COLUMNS} FROM sessions WHERE project_id = ? ORDER BY created_at DESC, id ASC`,
      )
      .all(projectId) as SessionRow[];
    return rows.map(toSession);
  }

  messages(sessionId: string): StoredMessage[] {
    const rows = this.db
      .prepare('SELECT payload FROM messages WHERE session_id = ? ORDER BY seq')
      .all(sessionId) as { payload: string }[];
    return rows.map((row) =>
      storedMessageSchema.parse(JSON.parse(row.payload)),
    );
  }

  createRun(sessionId: string, prompt: string): Run {
    return this.db.transaction(() => {
      const active = this.db
        .prepare(
          "SELECT 1 FROM runs WHERE session_id = ? AND status IN ('queued','running')",
        )
        .get(sessionId);
      if (active) throw new Error('This session already has an active run.');
      const run = runSchema.parse({
        id: randomUUID(),
        sessionId,
        prompt,
        status: 'queued',
        error: null,
        createdAt: new Date().toISOString(),
        finishedAt: null,
      });
      this.db
        .prepare(
          'INSERT INTO runs (id, session_id, prompt, status, error, created_at, finished_at) VALUES (?, ?, ?, ?, NULL, ?, NULL)',
        )
        .run(run.id, sessionId, prompt, run.status, run.createdAt);
      return run;
    })();
  }

  findRun(id: string): Run | null {
    const row = this.db
      .prepare(`SELECT ${RUN_COLUMNS} FROM runs WHERE id = ?`)
      .get(id);
    return row === undefined ? null : runSchema.parse(row);
  }

  listRuns(sessionId: string): Run[] {
    return z
      .array(runSchema)
      .parse(
        this.db
          .prepare(
            `SELECT ${RUN_COLUMNS} FROM runs WHERE session_id = ? ORDER BY created_at, id`,
          )
          .all(sessionId),
      );
  }

  claimNextQueued(): Run | null {
    return this.db.transaction(() => {
      const row = this.db
        .prepare(
          `SELECT ${RUN_COLUMNS} FROM runs WHERE status = 'queued' ORDER BY created_at, id LIMIT 1`,
        )
        .get();
      if (row === undefined) return null;
      const run = runSchema.parse(row);
      this.db
        .prepare("UPDATE runs SET status = 'running' WHERE id = ?")
        .run(run.id);
      return { ...run, status: 'running' as const };
    })();
  }

  appendEvent(runId: string, type: RunEvent['type'], text: string): void {
    runEventSchema.parse({ seq: 1, type, text });
    this.db
      .prepare(
        'INSERT INTO run_events (run_id, seq, type, text) SELECT @runId, COALESCE(MAX(seq), 0) + 1, @type, @text FROM run_events WHERE run_id = @runId',
      )
      .run({ runId, type, text });
  }

  eventsAfter(runId: string, seq: number): RunEvent[] {
    return z
      .array(runEventSchema)
      .parse(
        this.db
          .prepare(
            'SELECT seq, type, text FROM run_events WHERE run_id = ? AND seq > ? ORDER BY seq',
          )
          .all(runId, seq),
      );
  }

  traceEvents(runId: string): RunEvent[] {
    return z
      .array(runEventSchema)
      .parse(
        this.db
          .prepare(
            "SELECT seq, type, text FROM run_events WHERE run_id = ? AND type IN ('started', 'screened', 'sources', 'completed') ORDER BY seq",
          )
          .all(runId),
      );
  }

  completeRun(run: Run, messages: StoredMessage[]): void {
    this.db.transaction(() => {
      const next = this.db
        .prepare(
          'SELECT COALESCE(MAX(seq), 0) + 1 AS next FROM messages WHERE session_id = ?',
        )
        .get(run.sessionId) as { next: number };
      const insert = this.db.prepare(
        'INSERT INTO messages (session_id, seq, payload) VALUES (?, ?, ?)',
      );
      messages.forEach((message, index) => {
        insert.run(
          run.sessionId,
          next.next + index,
          JSON.stringify(storedMessageSchema.parse(message)),
        );
      });
      this.finish(run.id, 'completed', null);
    })();
  }

  finishRun(
    runId: string,
    status: 'failed' | 'cancelled' | 'blocked',
    error: string | null,
  ): void {
    this.finish(runId, status, error);
  }

  private finish(
    runId: string,
    status: 'completed' | 'failed' | 'cancelled' | 'blocked',
    error: string | null,
  ): void {
    this.db
      .prepare(
        "UPDATE runs SET status = ?, error = ?, finished_at = ? WHERE id = ? AND status IN ('queued','running')",
      )
      .run(status, error, new Date().toISOString(), runId);
  }

  failInterrupted(): number {
    const rows = this.db
      .prepare("SELECT id FROM runs WHERE status = 'running'")
      .all() as { id: string }[];
    for (const { id } of rows) {
      this.appendEvent(id, 'failed', 'Interrupted by an application restart.');
      this.finish(id, 'failed', 'Interrupted by an application restart.');
    }
    return rows.length;
  }
}
