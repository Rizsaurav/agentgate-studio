import { z } from 'zod';
import { projectIdSchema, type ProjectRepository } from './projects';

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
    provider: z.enum(['ollama', ...CLOUD_PROVIDERS]),
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
    return this.eventsAfter(runId, 0)
      .filter((event) => event.type === 'sources')
      .flatMap((event) =>
        z
          .array(
            z
              .object({
                documentId: z.uuid(),
                title: z.string(),
                seq: z.number().int(),
              })
              .strict(),
          )
          .parse(JSON.parse(event.text)),
      );
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
