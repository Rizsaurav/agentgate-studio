import { z } from 'zod';
import { DEFAULT_OLLAMA_URL } from './ollama';

export const PULL_TIMEOUT_MS = 60 * 60_000;

/**
 * Ollama model references: a library name such as qwen2.5:3b, or a Hugging Face repository
 * as hf.co/owner/repo:quantization. No whitespace or path tricks.
 */
const LIBRARY_MODEL =
  /^([a-z0-9][a-z0-9_-]*\/)?[a-z0-9][a-z0-9._-]*(:[a-zA-Z0-9._-]+)?$/;
const HUGGING_FACE_MODEL =
  /^hf\.co\/[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*(:[A-Za-z0-9._-]+)?$/;
export const modelNameSchema = z
  .string()
  .trim()
  .min(1, 'Enter a model name.')
  .refine(
    (name) =>
      (name.length <= 100 && LIBRARY_MODEL.test(name)) ||
      (name.length <= 150 && HUGGING_FACE_MODEL.test(name)),
    'Use an Ollama model name such as qwen2.5:3b.',
  );

const pullLineSchema = z
  .object({
    status: z.string().optional(),
    digest: z.string().optional(),
    total: z.number().optional(),
    completed: z.number().optional(),
    error: z.string().optional(),
  })
  .loose();

/** The install steps in order: get Ollama running, download, check the model answers, then ready. */
export const PULL_STEPS = ['runtime', 'download', 'verify', 'ready'] as const;
export type PullStep = (typeof PULL_STEPS)[number];

export type PullState = {
  model: string;
  status: 'downloading' | 'done' | 'failed' | 'cancelled';
  /** The step in progress, or the one that ended the install. */
  step: PullStep;
  message: string;
  completedBytes: number;
  totalBytes: number;
};

export type PullOptions = {
  /** A download with no new data for this long is restarted; Ollama continues where it stopped. */
  stallMs?: number;
  /** Time a freshly installed model gets to load and answer its first prompt. */
  verifyMs?: number;
  /** Makes Ollama available (installing and starting it if needed) before the download. */
  prepare?: (
    report: (message: string) => void,
    signal: AbortSignal,
  ) => Promise<void>;
};

const STALL_MS = 2 * 60_000;
const VERIFY_MS = 5 * 60_000;
const MAX_ATTEMPTS = 3;
/** Downloads waiting behind the current one. */
export const MAX_QUEUED = 10;

class Stalled extends Error {}
/** Ollama answered, but the model cannot run here (for example an unsupported architecture). */
class DoesNotRun extends Error {}

/**
 * Downloads one model at a time through Ollama, with a time limit and cancel; more wait in a queue.
 * A stalled download is resumed, and a model counts as installed only once it answers a prompt;
 * one that does not run is removed and the next candidate is tried.
 * Progress is held in memory; Ollama itself resumes a partial download.
 */
export class ModelPuller {
  private current: PullState | null = null;
  private readonly waiting: string[][] = [];
  private abort: AbortController | null = null;
  private readonly baseUrl: string;
  private readonly stallMs: number;
  private readonly verifyMs: number;
  private readonly prepare: PullOptions['prepare'];

  constructor(baseUrl: string = DEFAULT_OLLAMA_URL, options: PullOptions = {}) {
    this.baseUrl = new URL(baseUrl).origin;
    this.stallMs = options.stallMs ?? STALL_MS;
    this.verifyMs = options.verifyMs ?? VERIFY_MS;
    this.prepare = options.prepare;
  }

  state(): PullState | null {
    return this.current;
  }

  /** Models waiting to download, in order. */
  queued(): string[] {
    return this.waiting.map((models) => models[0] as string);
  }

  /**
   * Starts the download, or queues it behind the current one; progress is read with state().
   * `fallbacks` are tried in order if a model downloads but does not run on this computer.
   */
  start(modelInput: unknown, fallbacks: unknown[] = []): 'started' | 'queued' {
    const models = [modelInput, ...fallbacks].map((model) =>
      modelNameSchema.parse(model),
    );
    const model = models[0] as string;
    if (this.current?.status === 'downloading') {
      if (this.current.model === model || this.queued().includes(model))
        throw new Error(`${model} is already being installed.`);
      if (this.waiting.length >= MAX_QUEUED)
        throw new Error(
          `At most ${MAX_QUEUED} models can wait to install. Try again once some finish.`,
        );
      this.waiting.push(models);
      return 'queued';
    }
    this.begin(models);
    return 'started';
  }

  /** Takes a model off the queue before its download starts. */
  unqueue(modelInput: unknown): void {
    const model = modelNameSchema.parse(modelInput);
    const index = this.queued().indexOf(model);
    if (index >= 0) this.waiting.splice(index, 1);
  }

  /** Deletes an installed model from Ollama. */
  async uninstall(modelInput: unknown): Promise<void> {
    const model = modelNameSchema.parse(modelInput);
    if (this.current?.status === 'downloading' && this.current.model === model)
      throw new Error(`${model} is installing; cancel it first.`);
    this.unqueue(model);
    if (!(await this.remove(model)))
      throw new Error(`${model} could not be removed.`);
  }

  private begin(models: string[]): void {
    const state: PullState = {
      model: models[0] as string,
      status: 'downloading',
      step: 'runtime',
      message: 'Checking Ollama…',
      completedBytes: 0,
      totalBytes: 0,
    };
    this.current = state;
    this.abort = new AbortController();
    void this.run(state, models, this.abort).finally(() => {
      const next = this.waiting.shift();
      if (next) this.begin(next);
    });
  }

  /** Stops the current download; queued ones continue after it. */
  cancel(): void {
    this.abort?.abort(new Error('cancelled'));
  }

  /** Resolves when the active download and the queue end. Used by tests. */
  async idle(): Promise<void> {
    while (this.current?.status === 'downloading' || this.waiting.length)
      await new Promise((resolve) => setTimeout(resolve, 20));
  }

  private async run(
    state: PullState,
    models: string[],
    controller: AbortController,
  ): Promise<void> {
    const timer = setTimeout(
      () => controller.abort(new Error('timeout')),
      PULL_TIMEOUT_MS,
    );
    try {
      await this.prepare?.((message) => {
        state.message = message;
      }, controller.signal);
      for (const [index, model] of models.entries()) {
        state.step = 'download';
        state.model = model;
        state.completedBytes = 0;
        state.totalBytes = 0;
        await this.download(state, controller.signal);
        state.step = 'verify';
        state.message = 'Asking it for a short reply…';
        try {
          await this.verify(model, controller.signal);
        } catch (error) {
          if (!(error instanceof DoesNotRun)) throw error;
          if (!(await this.remove(model)))
            throw new Error(
              `${model} does not run here and could not be removed.`,
            );
          const next = models[index + 1];
          if (!next)
            throw new Error(
              `${model} downloaded but does not run on this computer, so it was removed.`,
            );
          state.message = `${model} does not run on this computer; trying ${next}…`;
          continue;
        }
        state.step = 'ready';
        state.status = 'done';
        state.message = 'Installed and ready to chat.';
        state.completedBytes = state.totalBytes;
        return;
      }
    } catch (error) {
      const reason = controller.signal.aborted
        ? String(controller.signal.reason?.message)
        : '';
      if (reason === 'cancelled') {
        state.status = 'cancelled';
        state.message = 'Cancelled.';
      } else {
        state.status = 'failed';
        state.message =
          reason === 'timeout'
            ? 'The download took too long and was stopped.'
            : describePullError(error);
      }
    } finally {
      clearTimeout(timer);
    }
  }

  /** Pulls with a bounded number of resumes after a stall or a dropped connection. */
  private async download(state: PullState, signal: AbortSignal): Promise<void> {
    for (let attempt = 1; ; attempt += 1) {
      try {
        return await this.pullOnce(state, signal);
      } catch (error) {
        if (!(error instanceof Stalled) || signal.aborted) throw error;
        if (attempt === MAX_ATTEMPTS)
          throw new Error(
            `The download stopped ${MAX_ATTEMPTS} times. Check the internet connection and install again; it continues where it stopped.`,
          );
        state.message = `The download stalled; resuming (attempt ${attempt + 1} of ${MAX_ATTEMPTS})…`;
      }
    }
  }

  private async pullOnce(state: PullState, signal: AbortSignal): Promise<void> {
    const stall = new AbortController();
    let watchdog = setTimeout(() => stall.abort(), this.stallMs);
    const layers = new Map<string, { total: number; completed: number }>();
    let succeeded = false;
    try {
      const response = await fetch(`${this.baseUrl}/api/pull`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ model: state.model, stream: true }),
        signal: AbortSignal.any([signal, stall.signal]),
      });
      if (!response.ok || !response.body)
        throw new Error(`Ollama returned HTTP ${response.status}.`);
      const decoder = new TextDecoder();
      let buffer = '';
      for await (const chunk of response.body) {
        clearTimeout(watchdog);
        watchdog = setTimeout(() => stall.abort(), this.stallMs);
        buffer += decoder.decode(chunk as Uint8Array, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          if (!line.trim()) continue;
          const parsed = pullLineSchema.parse(JSON.parse(line));
          if (parsed.error) throw new Error(parsed.error);
          if (parsed.status === 'success') succeeded = true;
          if (parsed.digest && parsed.total)
            layers.set(parsed.digest, {
              total: parsed.total,
              completed:
                parsed.completed ?? layers.get(parsed.digest)?.completed ?? 0,
            });
          state.totalBytes = sum(layers, 'total');
          state.completedBytes = sum(layers, 'completed');
          state.message =
            describeProgress(parsed.status, state) ?? state.message;
        }
      }
    } catch (error) {
      if (stall.signal.aborted && !signal.aborted) throw new Stalled();
      throw error;
    } finally {
      clearTimeout(watchdog);
    }
    // A stream that ends without Ollama's success line was cut off, not finished.
    if (!succeeded) throw new Stalled();
  }

  /** Asks the model for a few tokens; an error from Ollama means it cannot run here. */
  private async verify(model: string, signal: AbortSignal): Promise<void> {
    const response = await fetch(`${this.baseUrl}/api/generate`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        model,
        prompt: 'Reply with OK.',
        stream: false,
        options: { num_predict: 4 },
      }),
      signal: AbortSignal.any([signal, AbortSignal.timeout(this.verifyMs)]),
    });
    if (!response.ok) throw new DoesNotRun();
  }

  /** True when the model is gone afterwards (including when it was never there). */
  private async remove(model: string): Promise<boolean> {
    const response = await fetch(`${this.baseUrl}/api/delete`, {
      method: 'DELETE',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model }),
    });
    return response.ok || response.status === 404;
  }
}

const MB = 1024 ** 2;

/** Ollama's progress lines in plain words; layer digests mean nothing to a person. */
function describeProgress(
  status: string | undefined,
  state: PullState,
): string | undefined {
  if (!status) return undefined;
  if (status.startsWith('pulling manifest')) return 'Finding the model…';
  if (status.startsWith('pulling'))
    return state.totalBytes
      ? `Downloading ${Math.round(state.completedBytes / MB)} of ${Math.round(state.totalBytes / MB)} MB`
      : 'Downloading…';
  if (status.startsWith('verifying')) return 'Verifying the download…';
  if (status === 'success') return 'Downloaded.';
  return 'Finishing the install…';
}

function sum(
  layers: Map<string, { total: number; completed: number }>,
  key: 'total' | 'completed',
): number {
  let value = 0;
  for (const layer of layers.values()) value += layer[key];
  return value;
}

/** Ollama's own messages are short and safe to show; transport errors get plain wording. */
function describePullError(error: unknown): string {
  if (error instanceof z.ZodError || error instanceof SyntaxError)
    return 'Ollama sent an unexpected response.';
  const message = error instanceof Error ? error.message : '';
  if (/fetch failed|ECONN|ENOTFOUND/i.test(message))
    return 'Ollama is not reachable. Start it with the app launcher or `ollama serve`.';
  return message.slice(0, 200) || 'The download failed.';
}
