import type { ProjectImportProgress } from '@agentgate/controller';
import { ProjectSourceError } from '@agentgate/controller';

type ProgressEvent = { type: 'progress' } & ProjectImportProgress;
type StreamEvent<T> =
  | ProgressEvent
  | { type: 'complete'; value: T }
  | { type: 'error'; message: string };

function messageOf(error: unknown): string {
  if (error instanceof ProjectSourceError) return error.message;
  if (error instanceof Error && error.name === 'ZodError') {
    const issues = (error as Error & { issues?: { message?: unknown }[] })
      .issues;
    const message = issues?.[0]?.message;
    if (typeof message === 'string') return message;
  }
  return 'The project could not be imported. Check the folder and available disk space.';
}

/** Streams bounded progress and aborts unfinished work when the client disconnects. */
export function projectProgressStream<T>(
  request: Request,
  run: (
    signal: AbortSignal,
    onProgress: (progress: ProjectImportProgress) => void,
  ) => Promise<T>,
): Response {
  const encoder = new TextEncoder();
  const abort = new AbortController();
  const queue: Uint8Array[] = [];
  let wake: (() => void) | null = null;
  let finished = false;
  let cancelled = false;
  const push = (event: StreamEvent<T>) => {
    if (cancelled) return;
    queue.push(encoder.encode(`${JSON.stringify(event)}\n`));
    wake?.();
    wake = null;
  };
  const onRequestAbort = () => abort.abort();
  request.signal.addEventListener('abort', onRequestAbort, { once: true });

  void run(abort.signal, (progress) => push({ type: 'progress', ...progress }))
    .then((value) => push({ type: 'complete', value }))
    .catch((error: unknown) =>
      push({ type: 'error', message: messageOf(error) }),
    )
    .finally(() => {
      finished = true;
      request.signal.removeEventListener('abort', onRequestAbort);
      wake?.();
      wake = null;
    });

  return new Response(
    new ReadableStream<Uint8Array>({
      async pull(controller) {
        while (queue.length === 0 && !finished)
          await new Promise<void>((resolve) => {
            wake = resolve;
          });
        const next = queue.shift();
        if (next) controller.enqueue(next);
        else controller.close();
      },
      cancel() {
        cancelled = true;
        abort.abort();
        request.signal.removeEventListener('abort', onRequestAbort);
      },
    }),
    {
      headers: {
        'cache-control': 'no-store, no-transform',
        'content-type': 'application/x-ndjson; charset=utf-8',
        'x-content-type-options': 'nosniff',
      },
    },
  );
}
