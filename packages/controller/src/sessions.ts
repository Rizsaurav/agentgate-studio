import { z } from 'zod';
import { projectIdSchema, type ProjectRepository } from './projects';
import { securityEventSchema } from './security';
import {
  buildTraceStages,
  runTraceStageSchema,
  screenedDocumentIds,
  securityEventSummarySchema,
  sourcesFromEvents,
  toSecurityEventSummaries,
  traceSourceSchema,
} from './trace';

/** Providers a user can connect with an API key. Each one is a built-in provider of the Pi SDK. */
export const CLOUD_PROVIDERS = [
  'openrouter',
  'anthropic',
  'openai',
  'google',
  'groq',
  'deepseek',
  'mistral',
  'xai',
] as const;
export const cloudProviderSchema = z.enum(CLOUD_PROVIDERS);
export type CloudProvider = z.infer<typeof cloudProviderSchema>;
export const modelRefSchema = z
  .object({
    provider: z.enum(['ollama', 'custom', ...CLOUD_PROVIDERS]),
    modelId: z.string().trim().min(1).max(200),
  })
  .strict();
export type ModelRef = z.infer<typeof modelRefSchema>;

export const sessionIdSchema = z.uuid();
export const runIdSchema = z.uuid();
export const promptSchema = z
  .string()
  .trim()
  .min(1, 'Enter a task for the agent.')
  .max(8000, 'Use at most 8000 characters.');
export const createSessionSchema = z
  .object({ projectId: projectIdSchema, model: modelRefSchema })
  .strict();
export const sendPromptSchema = z
  .object({ sessionId: sessionIdSchema, prompt: promptSchema })
  .strict();

export const sessionSchema = z
  .object({
    id: sessionIdSchema,
    projectId: projectIdSchema,
    model: modelRefSchema,
    createdAt: z.iso.datetime(),
  })
  .strict();
export type Session = z.infer<typeof sessionSchema>;

export const runStatusSchema = z.enum([
  'queued',
  'running',
  'completed',
  'failed',
  'cancelled',
  'blocked',
]);
export type RunStatus = z.infer<typeof runStatusSchema>;
export const runSchema = z
  .object({
    id: runIdSchema,
    sessionId: sessionIdSchema,
    prompt: promptSchema,
    status: runStatusSchema,
    error: z.string().nullable(),
    createdAt: z.iso.datetime(),
    finishedAt: z.iso.datetime().nullable(),
  })
  .strict();
export type Run = z.infer<typeof runSchema>;

export const runEventSchema = z
  .object({
    seq: z.number().int().positive(),
    type: z.enum([
      'started',
      'screened',
      'sources',
      'text_delta',
      'completed',
      'failed',
      'cancelled',
      'blocked',
    ]),
    text: z.string(),
  })
  .strict();
export type RunEvent = z.infer<typeof runEventSchema>;

export const runTraceSchema = z
  .object({
    run: runSchema,
    started: z.boolean(),
    sources: z.array(traceSourceSchema),
    securityEvents: z.array(securityEventSummarySchema),
    stages: z.array(runTraceStageSchema),
  })
  .strict();
export type RunTrace = z.infer<typeof runTraceSchema>;

export const TERMINAL_STATUSES: readonly RunStatus[] = [
  'completed',
  'failed',
  'cancelled',
  'blocked',
];

/**
 * Pi owns the full message shape; the application only checks the role it
 * relies on when it replays stored history into an agent.
 */
export const storedMessageSchema = z
  .object({ role: z.enum(['user', 'assistant', 'toolResult']) })
  .loose();
export type StoredMessage = z.infer<typeof storedMessageSchema>;

export type TurnView = { role: 'user' | 'assistant'; text: string };

function messageText(message: StoredMessage): string {
  const content: unknown = message.content;
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .map((block: unknown) =>
      typeof block === 'object' &&
      block !== null &&
      'type' in block &&
      block.type === 'text' &&
      'text' in block &&
      typeof block.text === 'string'
        ? block.text
        : '',
    )
    .join('');
}

export interface SessionRepository {
  createSession(projectId: string, model: ModelRef): Session;
  findSession(id: string): Session | null;
  listSessions(projectId: string): Session[];
  messages(sessionId: string): StoredMessage[];
  /** Fails if the session already has a queued or running run. */
  createRun(sessionId: string, prompt: string): Run;
  findRun(id: string): Run | null;
  listRuns(sessionId: string): Run[];
  claimNextQueued(): Run | null;
  appendEvent(runId: string, type: RunEvent['type'], text: string): void;
  eventsAfter(runId: string, seq: number): RunEvent[];
  /** Only 'started', 'screened', 'sources', and 'completed' events, for traces and source lists. */
  traceEvents(runId: string): RunEvent[];
  /** Atomically appends the turn's messages and marks the run completed. */
  completeRun(run: Run, messages: StoredMessage[]): void;
  finishRun(
    runId: string,
    status: 'failed' | 'cancelled' | 'blocked',
    error: string | null,
  ): void;
  /** Marks runs left running by a previous process as failed. */
  failInterrupted(): number;
}

export class SessionService {
  constructor(
    private readonly repository: SessionRepository,
    private readonly projects: ProjectRepository,
  ) {}

  createSession(input: unknown): Session {
    const { projectId, model } = createSessionSchema.parse(input);
    if (!this.projects.find(projectId)) throw new Error('Unknown project.');
    return sessionSchema.parse(this.repository.createSession(projectId, model));
  }

  findSession(id: unknown): Session | null {
    return sessionSchema
      .nullable()
      .parse(this.repository.findSession(sessionIdSchema.parse(id)));
  }

  listSessions(projectId: unknown): Session[] {
    return z
      .array(sessionSchema)
      .parse(this.repository.listSessions(projectIdSchema.parse(projectId)));
  }

  transcript(sessionId: unknown): StoredMessage[] {
    return z
      .array(storedMessageSchema)
      .parse(this.repository.messages(sessionIdSchema.parse(sessionId)));
  }

  /** The user-visible conversation: text of user and assistant messages only. */
  view(sessionId: unknown): TurnView[] {
    return this.transcript(sessionId).flatMap((message) =>
      message.role === 'user' || message.role === 'assistant'
        ? [{ role: message.role, text: messageText(message) }]
        : [],
    );
  }

  /** Documents retrieved for a run, recorded as the run executed. */
  sources(
    runId: unknown,
  ): { documentId: string; title: string; seq: number }[] {
    return sourcesFromEvents(this.traceEvents(runId));
  }

  /** Only 'started', 'screened', 'sources', and 'completed' events, without streamed text deltas. */
  traceEvents(runId: unknown): RunEvent[] {
    return z
      .array(runEventSchema)
      .parse(this.repository.traceEvents(runIdSchema.parse(runId)));
  }

  /**
   * A per-run trace built only from already-stored data: run events,
   * retrieved sources, and security events. It never invents a stage that
   * did not happen, it never includes model text or retrieved excerpts,
   * and its security events carry no stored evidence.
   *
   * Malformed stored events (a Zod parse error or a JSON syntax error)
   * make this run's trace unavailable (null); the page renders a
   * placeholder for it. Any other error is a bug or a database failure:
   * it is logged server-side with only the error name and the run id,
   * no stored values, and then rethrown, never swallowed.
   */
  trace(runId: unknown, securityEvents: unknown): RunTrace | null {
    const run = this.findRun(runId);
    if (!run) return null;
    return this.traceForRun(run, securityEvents);
  }

  /**
   * Same as trace(), but for a run the caller already fetched (the
   * session page's listRuns snapshot). Skipping a second findRun keeps
   * the run badge and the stages on the same run snapshot.
   */
  traceForRun(runInput: unknown, securityEvents: unknown): RunTrace | null {
    try {
      const run = runSchema.parse(runInput);
      const events = z.array(securityEventSchema).parse(securityEvents);
      const storedEvents = this.traceEvents(run.id);
      const started = storedEvents.some((event) => event.type === 'started');
      const screened = storedEvents.some((event) => event.type === 'screened');
      const hasCompleted = storedEvents.some(
        (event) => event.type === 'completed',
      );
      const sources = sourcesFromEvents(storedEvents);
      const stages = buildTraceStages({
        run,
        started,
        screened,
        screenedDocumentIds: screenedDocumentIds(storedEvents),
        hasCompleted,
        sources,
        securityEvents: events,
      });
      return runTraceSchema.parse({
        run,
        started,
        sources,
        securityEvents: toSecurityEventSummaries(events),
        stages,
      });
    } catch (error) {
      if (error instanceof z.ZodError || error instanceof SyntaxError) {
        return null;
      }
      // Log only the error class and the run id: stored values may
      // contain private content.
      const runIdForLog =
        typeof runInput === 'object' &&
        runInput !== null &&
        'id' in runInput &&
        typeof (runInput as { id: unknown }).id === 'string'
          ? (runInput as { id: string }).id
          : 'unknown';
      console.error(
        `Trace for run ${runIdForLog} failed:`,
        error instanceof Error ? error.name : 'unknown',
      );
      throw error;
    }
  }

  listRuns(sessionId: unknown): Run[] {
    return z
      .array(runSchema)
      .parse(this.repository.listRuns(sessionIdSchema.parse(sessionId)));
  }

  findRun(id: unknown): Run | null {
    return runSchema
      .nullable()
      .parse(this.repository.findRun(runIdSchema.parse(id)));
  }

  eventsAfter(runId: unknown, seq: number): RunEvent[] {
    return z
      .array(runEventSchema)
      .parse(this.repository.eventsAfter(runIdSchema.parse(runId), seq));
  }
}
