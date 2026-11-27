import { Agent, type AgentMessage } from '@earendil-works/pi-agent-core';
import type { Passage } from './documents';
import {
  checkGrounding,
  DEFAULT_GROUNDING,
  groundedQuestion,
  type GroundingCheck,
  type GroundingOptions,
  revisionRequest,
  uncoveredQuestion,
  withoutClaims,
} from './grounding';
import type { RetrievalModels } from './retrieval';
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
  retrieve(projectId: string, query: string): Promise<Passage[]>;
  /** Whether the project has reference documents; when it does and nothing matched, the model is told. */
  hasDocuments?(projectId: string): boolean;
}
export type RunOptions = {
  /** Required: no model text is delivered without passing the guard. */
  guard: RunGuard;
  timeoutMs?: number;
  knowledge?: RunKnowledge;
  /** Checks every claim of an answer built on excerpts; unsupported claims are revised once, then removed. */
  grounding?: {
    models: Pick<RetrievalModels, 'entail'>;
    options?: GroundingOptions;
  };
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
  private readonly grounding: RunOptions['grounding'];

  constructor(
    private readonly repository: SessionRepository,
    private readonly models: AgentModels,
    options: RunOptions,
  ) {
    this.guard = options.guard;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_RUN_TIMEOUT_MS;
    this.knowledge = options.knowledge;
    this.grounding = options.grounding;
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
        (await this.knowledge?.retrieve(session.projectId, run.prompt)) ?? [],
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
      const uncovered =
        passages.length === 0 &&
        (this.knowledge?.hasDocuments?.(session.projectId) ?? false);
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
        // Answers from the documents are sampled greedily, so the same question and excerpts give the same
        // answer, and the check that follows judges what the model most expects, not a random draw.
        streamFn:
          passages.length > 0 || uncovered
            ? (model, context, options) =>
                opened.streamFn(model, context, { ...options, temperature: 0 })
            : opened.streamFn,
        getApiKey: opened.getApiKey,
        // Excerpts reach the model for this call only; they are not saved into the history. A project with
        // documents that none answered is told so, rather than left to guess what they might say.
        transformContext: async (messages) =>
          passages.length > 0
            ? withExcerpts(messages, passages)
            : uncovered
              ? withQuestion(messages, uncoveredQuestion)
              : messages,
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
      // A hard stop for the whole run, revision included: even a provider that ignores abort cannot hold the queue.
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
      const ask = async (text: string) => {
        answer = '';
        await Promise.race([agent.prompt(text), stop]);
      };
      const lastAnswer = () => {
        const message = agent.state.messages.at(-1);
        return message?.role === 'assistant' &&
          message.stopReason !== 'error' &&
          message.stopReason !== 'aborted'
          ? message
          : null;
      };
      // An answer built on excerpts is checked claim by claim. Unsupported or contradicted claims get one
      // revision with the exact sentences named; whatever is still unsupported is removed before delivery.
      let grounding: GroundingCheck | null = null;
      let firstTry: { answer: string; check: GroundingCheck } | null = null;
      try {
        await ask(run.prompt);
        if (!stopped && this.grounding && passages.length > 0 && lastAnswer()) {
          const check = (text: string) =>
            checkGrounding(
              text,
              passages,
              this.grounding?.models as Pick<RetrievalModels, 'entail'>,
              this.grounding?.options ?? DEFAULT_GROUNDING,
            );
          grounding = await check(answer);
          const rejected = rejectedClaims(grounding);
          if (rejected.length > 0) {
            firstTry = { answer, check: grounding };
            await ask(revisionRequest(rejected));
            if (!stopped && lastAnswer() && answer.trim()) {
              const second = await check(answer);
              if (rejectedClaims(second).length <= rejected.length)
                grounding = second;
              else answer = firstTry.answer;
            } else if (!stopped) answer = firstTry.answer;
          }
        }
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
      const last = firstTry
        ? turn.findLast((message) => message.role === 'assistant')
        : turn.at(-1);
      if (last?.role !== 'assistant')
        return fail('The model returned no answer.');
      if (!firstTry && last.stopReason === 'aborted') return cancelled();
      if (!firstTry && last.stopReason === 'error')
        return fail(
          opened.describeError(
            last.errorMessage ?? 'The model request failed.',
          ),
        );
      let stored = turn;
      if (grounding) {
        answer = withoutClaims(answer, rejectedClaims(grounding));
        this.repository.appendEvent(
          run.id,
          'grounding',
          JSON.stringify({
            claims: grounding.claims.length,
            supported: grounding.supported,
            unsupported: grounding.unsupported,
            contradicted: grounding.contradicted,
            revised: firstTry !== null,
            removed: rejectedClaims(grounding),
          }),
        );
        // The history keeps the question and the answer as delivered, not the revision exchange.
        const question = turn.find((message) => message.role === 'user');
        if (question)
          stored = [
            question,
            { ...last, content: [{ type: 'text', text: answer }] },
          ];
      }
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
        stored.map((message) => storedMessageSchema.parse(message)),
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

/** Claims the check rejected: unsupported or contradicted. */
function rejectedClaims(check: GroundingCheck): string[] {
  return check.claims
    .filter((claim) => claim.status !== 'supported')
    .map((claim) => claim.sentence);
}

/** The latest user message, rewritten by `wrap`; earlier messages are left as they are. */
function withQuestion(
  messages: AgentMessage[],
  wrap: (question: string) => string,
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
      ? { ...original, content: [{ type: 'text', text: wrap(question) }] }
      : message,
  );
}

function withExcerpts(
  messages: AgentMessage[],
  passages: Passage[],
): AgentMessage[] {
  return withQuestion(messages, (question) =>
    groundedQuestion(question, passages),
  );
}
