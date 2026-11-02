import { z } from 'zod';
import { DEFAULT_OLLAMA_URL } from './ollama';

export const PULL_TIMEOUT_MS = 60 * 60_000;
const START_TIMEOUT_MS = 10_000;

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

export type PullState = {
  model: string;
  status: 'downloading' | 'done' | 'failed' | 'cancelled';
  message: string;
  completedBytes: number;
  totalBytes: number;
};

/**
 * Downloads one model at a time through Ollama, with a time limit and cancel.
 * Progress is held in memory; Ollama itself resumes a partial download.
 */
export class ModelPuller {
  private current: PullState | null = null;
  private abort: AbortController | null = null;
  private readonly baseUrl: string;

  constructor(baseUrl: string = DEFAULT_OLLAMA_URL) {
    this.baseUrl = new URL(baseUrl).origin;
  }

  state(): PullState | null {
    return this.current;
  }

  /** Starts the download and returns once it is running; progress is read with state(). */
  start(modelInput: unknown): PullState {
    const model = modelNameSchema.parse(modelInput);
    if (this.current?.status === 'downloading')
      throw new Error(`${this.current.model} is already downloading.`);
    const state: PullState = {
      model,
      status: 'downloading',
      message: 'Starting…',
      completedBytes: 0,
      totalBytes: 0,
    };
    this.current = state;
    this.abort = new AbortController();
    void this.run(state, this.abort);
    return state;
  }

  cancel(): void {
    this.abort?.abort(new Error('cancelled'));
  }

  /** Resolves when the active download ends. Used by tests. */
  async idle(): Promise<void> {
    while (this.current?.status === 'downloading')
      await new Promise((resolve) => setTimeout(resolve, 20));
  }

  private async run(
    state: PullState,
    controller: AbortController,
  ): Promise<void> {
    const timer = setTimeout(
      () => controller.abort(new Error('timeout')),
      PULL_TIMEOUT_MS,
    );
    const layers = new Map<string, { total: number; completed: number }>();
    try {
      const response = await fetch(`${this.baseUrl}/api/pull`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ model: state.model, stream: true }),
        signal: AbortSignal.any([
          controller.signal,
          AbortSignal.timeout(START_TIMEOUT_MS + PULL_TIMEOUT_MS),
        ]),
      });
      if (!response.ok || !response.body)
        throw new Error(`Ollama returned HTTP ${response.status}.`);
      const decoder = new TextDecoder();
      let buffer = '';
      for await (const chunk of response.body) {
        buffer += decoder.decode(chunk as Uint8Array, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          if (!line.trim()) continue;
          const parsed = pullLineSchema.parse(JSON.parse(line));
          if (parsed.error) throw new Error(parsed.error);
          if (parsed.digest && parsed.total)
            layers.set(parsed.digest, {
              total: parsed.total,
              completed:
                parsed.completed ?? layers.get(parsed.digest)?.completed ?? 0,
            });
          state.totalBytes = sum(layers, 'total');
          state.completedBytes = sum(layers, 'completed');
          state.message = parsed.status ?? state.message;
        }
      }
      state.status = 'done';
      state.message = 'Installed.';
      state.completedBytes = state.totalBytes;
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
