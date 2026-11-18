import { Agent, type AgentMessage } from '@earendil-works/pi-agent-core';
import type { Passage } from './documents';
import { groundedQuestion } from './grounding';
import type { AgentModels } from './ollama';
import { DEFAULT_SYSTEM_PROMPT, type ActivePrompt } from './prompts';
import type { Blocked, RunGuard } from './security';
import {
  type RunTelemetry,
  type SpanAttributes,
  TraceRecorder,
} from './telemetry';
import {
  sendPromptSchema,
  storedMessageSchema,
  type Run,
  type SessionRepository,
} from './sessions';

export const DEFAULT_RUN_TIMEOUT_MS = 120_000;
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
  /** Where run traces go (#10). Optional: without it nothing is recorded. */
  telemetry?: RunTelemetry;
  /** The project's active system prompt (#27). Without it runs use the built-in version 0. */
  prompts?: { active(projectId: string): ActivePrompt };
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
  private readonly telemetry: RunTelemetry | undefined;
  private readonly prompts: RunOptions['prompts'];

  constructor(
    private readonly repository: SessionRepository,
    private readonly models: AgentModels,
    options: RunOptions,
  ) {
    this.guard = options.guard;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_RUN_TIMEOUT_MS;
    this.knowledge = options.knowledge;
    this.telemetry = options.telemetry;
    this.prompts = options.prompts;
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
    // Set once the session is known; every way out of the run finishes it exactly once.
    let trace: TraceRecorder | undefined;
    const fail = (message: string) => {
      this.repository.appendEvent(run.id, 'failed', message);
      this.repository.finishRun(run.id, 'failed', message);
      trace?.finish('failed');
    };
    const blocked = (decision: Blocked) => {
      const message = `Blocked by security rule ${decision.rule}: ${decision.reason}`;
      this.repository.appendEvent(run.id, 'blocked', message);
      this.repository.finishRun(run.id, 'blocked', message);
      trace?.finish('blocked', decision.rule);
    };
    const cancelled = () => {
      this.repository.appendEvent(run.id, 'cancelled', 'Cancelled.');
      this.repository.finishRun(run.id, 'cancelled', null);
      trace?.finish('cancelled');
    };
    try {
      const session = this.repository.findSession(run.sessionId);
      if (!session) return fail('The session no longer exists.');
      trace = new TraceRecorder(
        this.telemetry,
        run.id,
        session.projectId,
        `${session.model.provider}/${session.model.modelId}`,
      );
      const history = this.repository.messages(session.id);
      const guardContext = { projectId: session.projectId, runId: run.id };
      // Input check → retrieval → scan retrieved content → generate → inspect output → deliver or block.
      const endInput = trace.span('agentgate.input_check');
      const input = await this.guard.checkInput(guardContext, run.prompt);
      if (!input.allowed) {
        endInput('blocked', { 'agentgate.rule': input.rule });
        return blocked(input);
      }
      endInput('ok', scored({}, input));
      const endRetrieval = trace.span('agentgate.retrieval');
      const retrieved =
        this.knowledge?.retrieve(session.projectId, run.prompt) ?? [];
      endRetrieval('ok', counts(retrieved));
      const endScreening = trace.span('agentgate.passage_screening');
      const screened = await this.guard.screenPassages(guardContext, retrieved);
      if (screened.blocked) {
        endScreening('blocked', { 'agentgate.rule': screened.blocked.rule });
        return blocked(screened.blocked);
      }
      const passages = screened.passages;
      endScreening('ok', counts(passages));
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
      const endChat = trace.span('gen_ai.chat');
      const prompt = this.prompts?.active(session.projectId) ?? {
        version: 0,
        text: DEFAULT_SYSTEM_PROMPT,
      };
      const chat = {
        'gen_ai.operation.name': 'chat',
        'gen_ai.provider.name': session.model.provider,
        'gen_ai.request.model': session.model.modelId,
        'agentgate.prompt_version': prompt.version,
      } as const;
      let opened: Awaited<ReturnType<AgentModels['open']>>;
      try {
        opened = await this.models.open(session.model);
      } catch (error) {
        endChat('error', chat);
        throw error;
      }
      const agent = new Agent({
        initialState: {
          model: opened.model,
          systemPrompt: context ? `${prompt.text}\n\n${context}` : prompt.text,
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
      // The version number only, so every answer can show which prompt produced it.
      this.repository.appendEvent(run.id, 'prompt', String(prompt.version));
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
      const turn = agent.state.messages
        .filter((message) => message.role !== 'system')
        .slice(history.length);
      const last = turn.at(-1);
      const usage = last?.role === 'assistant' ? last.usage : undefined;
      const chatResult = {
        ...chat,
        ...(usage && {
          'gen_ai.usage.input_tokens': usage.input,
          'gen_ai.usage.output_tokens': usage.output,
          ...(usage.cost.total > 0 && {
            'agentgate.cost_usd': usage.cost.total,
          }),
        }),
      };
      if (stopped === 'timeout') {
        endChat('error', chatResult);
        return fail('The run timed out.');
      }
      if (stopped === 'cancelled') {
        endChat('cancelled', chatResult);
        return cancelled();
      }
      if (last?.role !== 'assistant') {
        endChat('error', chatResult);
        return fail('The model returned no answer.');
      }
      if (last.stopReason === 'aborted') {
        endChat('cancelled', chatResult);
        return cancelled();
      }
      if (last.stopReason === 'error') {
        endChat('error', chatResult);
        return fail(
          opened.describeError(
            last.errorMessage ?? 'The model request failed.',
          ),
        );
      }
      endChat('ok', chatResult);
      const endOutput = trace.span('agentgate.output_check');
      const output = this.guard.inspectOutput(guardContext, answer);
      if (!output.allowed) {
        endOutput('blocked', { 'agentgate.rule': output.rule });
        return blocked(output);
      }
      endOutput('ok');
      const endDelivery = trace.span('agentgate.delivery');
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
      endDelivery('ok');
      trace.finish('completed');
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

/** Passage and document counts for a span; never the passages themselves. */
function counts(passages: Passage[]): SpanAttributes {
  return {
    'agentgate.passages': passages.length,
    'agentgate.documents': new Set(passages.map((p) => p.documentId)).size,
  };
}

/** Adds the scanner's score when the decision carries one. */
function scored(
  attributes: SpanAttributes,
  decision: { score?: number },
): SpanAttributes {
  return decision.score === undefined
    ? attributes
    : { ...attributes, 'agentgate.scanner.score': decision.score };
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
