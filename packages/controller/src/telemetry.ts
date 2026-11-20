import { randomUUID } from 'node:crypto';
import type Database from 'better-sqlite3';
import { z } from 'zod';
import type { SqliteSettings } from './settings';

/**
 * Local-first run telemetry (#10). One trace per run and one span per pipeline stage, named after the
 * OpenTelemetry GenAI semantic conventions. Only numbers, model ids and rule names are stored: never
 * a prompt, an answer or passage text. The attribute schema is strict, so content cannot be added by
 * mistake: anything not listed here is rejected before it reaches the database.
 */

export const SPAN_NAMES = [
  'agentgate.input_check',
  'agentgate.retrieval',
  'agentgate.passage_screening',
  'gen_ai.chat',
  'agentgate.output_check',
  'agentgate.delivery',
] as const;
export type SpanName = (typeof SPAN_NAMES)[number];

const RULE = z.string().regex(/^[a-z0-9-]{1,64}$/);
const COUNT = z.number().int().nonnegative();

export const spanAttributesSchema = z
  .object({
    'gen_ai.operation.name': z.literal('chat'),
    'gen_ai.provider.name': z.string().regex(/^[a-z0-9-]{1,40}$/),
    'gen_ai.request.model': z.string().min(1).max(200),
    'gen_ai.usage.input_tokens': COUNT,
    'gen_ai.usage.output_tokens': COUNT,
    'agentgate.cost_usd': z.number().nonnegative(),
    'agentgate.scanner.score': z.number().min(0).max(1),
    'agentgate.rule': RULE,
    'agentgate.passages': COUNT,
    'agentgate.documents': COUNT,
  })
  .partial()
  .strict();
export type SpanAttributes = z.infer<typeof spanAttributesSchema>;

export const SPAN_STATUSES = ['ok', 'blocked', 'error', 'cancelled'] as const;
export type SpanStatus = (typeof SPAN_STATUSES)[number];
export const TRACE_STATUSES = [
  'completed',
  'blocked',
  'failed',
  'cancelled',
] as const;
export type TraceStatus = (typeof TRACE_STATUSES)[number];

export const spanSchema = z
  .object({
    name: z.enum(SPAN_NAMES),
    /** Milliseconds from the start of the run. */
    startMs: z.number().nonnegative(),
    durationMs: z.number().nonnegative(),
    status: z.enum(SPAN_STATUSES),
    attributes: spanAttributesSchema,
  })
  .strict();
export type Span = z.infer<typeof spanSchema>;

export const traceSchema = z
  .object({
    runId: z.string().min(1),
    projectId: z.string().min(1),
    model: z.string().min(1).max(200),
    startedAt: z.string(),
    durationMs: z.number().nonnegative(),
    status: z.enum(TRACE_STATUSES),
    rule: RULE.nullable(),
    spans: z.array(spanSchema),
  })
  .strict();
export type Trace = z.infer<typeof traceSchema>;

/** Kept this long, and at most this many traces; older ones are deleted when a run is recorded. */
export const RETENTION_DAYS = 30;
export const MAX_TRACES = 5000;
const SETTING = 'telemetry';

/** Where traces are kept. The only writer of the `traces` and `spans` tables. */
export class SqliteTelemetry {
  constructor(
    private readonly db: Database.Database,
    private readonly settings: SqliteSettings,
    private readonly now: () => Date = () => new Date(),
    private readonly maxTraces = MAX_TRACES,
  ) {}

  /** On by default; local only. */
  get enabled(): boolean {
    return this.settings.get(SETTING) !== 'off';
  }

  setEnabled(on: boolean): void {
    this.settings.set(SETTING, on ? 'on' : 'off');
  }

  /** Validates and stores one finished run, then applies retention. Does nothing when switched off. */
  record(input: Trace): void {
    if (!this.enabled) return;
    const trace = traceSchema.parse(input);
    const insertTrace = this.db.prepare(
      `INSERT OR REPLACE INTO traces (run_id, project_id, model, started_at, duration_ms, status, rule)
       VALUES (@runId, @projectId, @model, @startedAt, @durationMs, @status, @rule)`,
    );
    const insertSpan = this.db.prepare(
      `INSERT INTO spans (id, run_id, name, start_ms, duration_ms, status, attributes)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    );
    const cutoff = new Date(
      this.now().getTime() - RETENTION_DAYS * 86_400_000,
    ).toISOString();
    this.db.transaction(() => {
      this.db.prepare('DELETE FROM spans WHERE run_id = ?').run(trace.runId);
      insertTrace.run(trace);
      for (const span of trace.spans)
        insertSpan.run(
          randomUUID(),
          trace.runId,
          span.name,
          span.startMs,
          span.durationMs,
          span.status,
          JSON.stringify(span.attributes),
        );
      this.prune(cutoff);
    })();
  }

  /** The trace of one run, or undefined when none was recorded. */
  find(runId: string): Trace | undefined {
    const row = this.db
      .prepare(
        `SELECT run_id AS runId, project_id AS projectId, model, started_at AS startedAt,
                duration_ms AS durationMs, status, rule FROM traces WHERE run_id = ?`,
      )
      .get(runId) as Omit<Trace, 'spans'> | undefined;
    if (!row) return undefined;
    const spans = (
      this.db
        .prepare(
          `SELECT name, start_ms AS startMs, duration_ms AS durationMs, status, attributes
           FROM spans WHERE run_id = ? ORDER BY start_ms, rowid`,
        )
        .all(runId) as (Omit<Span, 'attributes'> & { attributes: string })[]
    ).map((s) => ({ ...s, attributes: JSON.parse(s.attributes) }));
    return traceSchema.parse({ ...row, spans });
  }

  /** Recent traces of a project, newest first, for the project view (#11). */
  recent(projectId: string, limit = 200): Trace[] {
    const ids = this.db
      .prepare(
        'SELECT run_id AS runId FROM traces WHERE project_id = ? ORDER BY started_at DESC LIMIT ?',
      )
      .all(projectId, limit) as { runId: string }[];
    return ids.flatMap(({ runId }) => this.find(runId) ?? []);
  }

  /** Deletes every trace, or a project's. The "clear telemetry" button. */
  clear(projectId?: string): void {
    this.db.transaction(() => {
      if (projectId) {
        this.db
          .prepare(
            'DELETE FROM spans WHERE run_id IN (SELECT run_id FROM traces WHERE project_id = ?)',
          )
          .run(projectId);
        this.db
          .prepare('DELETE FROM traces WHERE project_id = ?')
          .run(projectId);
      } else {
        this.db.exec('DELETE FROM spans; DELETE FROM traces;');
      }
    })();
  }

  private prune(cutoff: string): void {
    this.db
      .prepare(
        `DELETE FROM traces WHERE started_at < ? OR run_id NOT IN
           (SELECT run_id FROM traces ORDER BY started_at DESC LIMIT ?)`,
      )
      .run(cutoff, this.maxTraces);
    this.db.exec(
      'DELETE FROM spans WHERE run_id NOT IN (SELECT run_id FROM traces)',
    );
  }
}

/** What the run loop records into; a no-op when telemetry is off or not wired. */
export interface RunTelemetry {
  record(trace: Trace): void;
}

/**
 * Collects one run's spans in memory and hands them over once, when the run ends, so recording
 * costs one transaction per run rather than one write per stage.
 */
export class TraceRecorder {
  private readonly spans: Span[] = [];
  private readonly start = performance.now();
  private readonly startedAt = new Date().toISOString();
  private finished = false;

  constructor(
    private readonly sink: RunTelemetry | undefined,
    private readonly runId: string,
    private readonly projectId: string,
    private readonly model: string,
  ) {}

  /** Starts a stage; call the returned function when it ends. */
  span(
    name: SpanName,
  ): (status: SpanStatus, attributes?: SpanAttributes) => void {
    const begin = performance.now();
    return (status, attributes = {}) => {
      this.spans.push({
        name,
        startMs: round(begin - this.start),
        durationMs: round(performance.now() - begin),
        status,
        attributes,
      });
    };
  }

  /** Records the run once. Telemetry never fails a run: a write error is reported, not thrown. */
  finish(status: TraceStatus, rule: string | null = null): void {
    if (this.finished || !this.sink) return;
    this.finished = true;
    try {
      this.sink.record({
        runId: this.runId,
        projectId: this.projectId,
        model: this.model,
        startedAt: this.startedAt,
        durationMs: round(performance.now() - this.start),
        status,
        rule,
        spans: this.spans,
      });
    } catch (error) {
      // Only the error class: the message could name values from the run.
      console.error(
        `Telemetry for run ${this.runId} was not recorded:`,
        error instanceof Error ? error.name : 'unknown',
      );
    }
  }
}

function round(ms: number): number {
  return Math.round(ms * 10) / 10;
}
