import { Agent, type AgentMessage } from '@earendil-works/pi-agent-core';
import type { Passage } from './documents';
import { groundedQuestion } from './grounding';
import type { AgentModels } from './ollama';
import type { Blocked, RunGuard } from './security';
import {
  sendPromptSchema,
  storedMessageSchema,
  type Run,
  type SessionRepository,
} from './sessions';

export const DEFAULT_RUN_TIMEOUT_MS = 120_000;
const SYSTEM_PROMPT =
  'You are a helpful assistant inside AGENTGATE Studio. Answer concisely.';
const MAX_ERROR_LENGTH = 300;

/** Project knowledge supplied to every run; the same for whichever model runs. */
export interface RunKnowledge {
  context(projectId: string): string;
  retrieve(projectId: string, query: string): Passage[];
}
export type RunOptions = {
  /** Required: no model text is delivered without passing the guard. */
  guard: RunGuard;
  timeoutMs?: number;
  knowledge?: RunKnowledge;
};
const DELIVERY_CHUNK_CHARS = 40;

type StopReason = 'cancelled' | 'timeout';
type Active = { runId: string; stop: (reason: StopReason) => void };

/**
 * Executes queued runs one at a time, independent of any HTTP request.
 * Pi agents run without tools: no filesystem or shell capability is granted.
 */
export class RunService {
  private active: Active | null = null;
  private draining: Promise<void> | null = null;
  private readonly timeoutMs: number;
  private readonly knowledge: RunKnowledge | undefined;
  private readonly guard: RunGuard;

  constructor(
    private readonly repository: SessionRepository,
    private readonly models: AgentModels,
    options: RunOptions,
  ) {
    this.guard = options.guard;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_RUN_TIMEOUT_MS;
    this.knowledge = options.knowledge;
  }

  /** Recover from a previous process, then continue any queued work. */
  start(): void {
    this.repository.failInterrupted();
    this.kick();
  }

  enqueue(input: unknown): Run {
    const { sessionId, prompt } = sendPromptSchema.parse(input);
    if (!this.repository.findSession(sessionId))
      throw new Error('Unknown session.');
    const run = this.repository.createRun(sessionId, prompt);
    this.kick();
    return run;
  }

  cancel(runId: string): void {
    if (this.active?.runId === runId) {
      this.active.stop('cancelled');
      return;
    }
    const run = this.repository.findRun(runId);
    if (run?.status === 'queued') {
      this.repository.appendEvent(
        runId,
        'cancelled',
        'Cancelled before it started.',
      );
      this.repository.finishRun(runId, 'cancelled', null);
    }
  }

  /** Resolves when the queue is empty. Used by tests and graceful shutdown. */
  async idle(): Promise<void> {
    while (this.draining) await this.draining;
  }

  private kick(): void {
    if (this.draining) return;
    this.draining = this.drain().finally(() => {
      this.draining = null;
    });
  }

  private async drain(): Promise<void> {
    for (let run = this.repository.claimNextQueued(); run;) {
      await this.execute(run);
      run = this.repository.claimNextQueued();
    }
  }

  private async execute(run: Run): Promise<void> {
    const fail = (message: string) => {
      this.repository.appendEvent(run.id, 'failed', message);
      this.repository.finishRun(run.id, 'failed', message);
    };
    const blocked = (decision: Blocked) => {
      const message = `Blocked by security rule ${decision.rule}: ${decision.reason}`;
      this.repository.appendEvent(run.id, 'blocked', message);
      this.repository.finishRun(run.id, 'blocked', message);
    };
    const cancelled = () => {
      this.repository.appendEvent(run.id, 'cancelled', 'Cancelled.');
      this.repository.finishRun(run.id, 'cancelled', null);
    };
    try {
      const session = this.repository.findSession(run.sessionId);
      if (!session) return fail('The session no longer exists.');
      const history = this.repository.messages(session.id);
      const guardContext = { projectId: session.projectId, runId: run.id };
      // Input check → retrieval → scan retrieved content → generate → inspect output → deliver or block.
      const input = await this.guard.checkInput(guardContext, run.prompt);
      if (!input.allowed) return blocked(input);
      const screened = await this.guard.screenPassages(
        guardContext,
        this.knowledge?.retrieve(session.projectId, run.prompt) ?? [],
      );
      if (screened.blocked) return blocked(screened.blocked);
      const passages = screened.passages;
      // Proof that the input check and retrieval finished, recorded
      // before model opening: if opening then fails, the trace can
      // still show task and retrieval as done, instead of not-run.
      // Document ids only, no titles or passage text.
      this.repository.appendEvent(
        run.id,
        'screened',
        JSON.stringify([...new Set(passages.map((p) => p.documentId))]),
      );
      const context = this.knowledge?.context(session.projectId) ?? '';
      const opened = await this.models.open(session.model);
      const agent = new Agent({
        initialState: {
          model: opened.model,
          systemPrompt: context
            ? `${SYSTEM_PROMPT}\n\n${context}`
            : SYSTEM_PROMPT,
          tools: [],
          messages: history as AgentMessage[],
        },
        streamFn: opened.streamFn,
        getApiKey: opened.getApiKey,
        // Excerpts reach the model for this call only; they are not saved into the history.
        transformContext: async (messages) =>
          passages.length === 0 ? messages : withExcerpts(messages, passages),
      });
      this.repository.appendEvent(run.id, 'started', session.model.modelId);
      if (passages.length > 0)
        this.repository.appendEvent(
          run.id,
          'sources',
          JSON.stringify(
            passages.map(({ documentId, title, seq }) => ({
              documentId,
              title,
              seq,
            })),
          ),
        );
      // Model text is held back until the output has been inspected.
      let answer = '';
      const unsubscribe = agent.subscribe((event) => {
        if (
          event.type === 'message_update' &&
          event.assistantMessageEvent.type === 'text_delta'
        ) {
          answer += event.assistantMessageEvent.delta;
        }
      });
      // A hard stop: even a provider that ignores abort cannot hold the queue.
      let stopped: StopReason | null = null;
      let timer: NodeJS.Timeout | undefined;
      const stop = new Promise<void>((resolve) => {
        const request = (reason: StopReason) => {
          stopped ??= reason;
          agent.abort();
          resolve();
        };
        this.active = { runId: run.id, stop: request };
        timer = setTimeout(() => request('timeout'), this.timeoutMs);
      });
      try {
        await Promise.race([agent.prompt(run.prompt), stop]);
      } finally {
        clearTimeout(timer);
        unsubscribe();
        this.active = null;
      }
      if (stopped === 'timeout') return fail('The run timed out.');
      if (stopped === 'cancelled') return cancelled();
      const turn = agent.state.messages
        .filter((message) => message.role !== 'system')
        .slice(history.length);
      const last = turn.at(-1);
      if (last?.role !== 'assistant')
        return fail('The model returned no answer.');
      if (last.stopReason === 'aborted') return cancelled();
      if (last.stopReason === 'error')
        return fail(
          opened.describeError(
            last.errorMessage ?? 'The model request failed.',
          ),
        );
      const output = this.guard.inspectOutput(guardContext, answer);
      if (!output.allowed) return blocked(output);
      for (let i = 0; i < answer.length; i += DELIVERY_CHUNK_CHARS)
        this.repository.appendEvent(
          run.id,
          'text_delta',
          answer.slice(i, i + DELIVERY_CHUNK_CHARS),
        );
      this.repository.appendEvent(run.id, 'completed', '');
      this.repository.completeRun(
        run,
        turn.map((message) => storedMessageSchema.parse(message)),
      );
    } catch (error) {
      // Log only the error class: messages may contain private prompt content.
      console.error(
        `Run ${run.id} failed:`,
        error instanceof Error ? error.name : 'unknown',
      );
      fail(
        error instanceof Error
          ? error.message.slice(0, MAX_ERROR_LENGTH)
          : 'The run failed.',
      );
    }
  }
}

function withExcerpts(
  messages: AgentMessage[],
  passages: Passage[],
): AgentMessage[] {
  const index = messages.findLastIndex((message) => message.role === 'user');
  const original = messages[index];
  if (original?.role !== 'user') return messages;
  const question =
    typeof original.content === 'string'
      ? original.content
      : original.content
          .map((block) => (block.type === 'text' ? block.text : ''))
          .join('');
  return messages.map((message, i) =>
    i === index
      ? {
          ...original,
          content: [
            { type: 'text', text: groundedQuestion(question, passages) },
          ],
        }
      : message,
  );
}
