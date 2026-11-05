'use client';
import { useRef, useState } from 'react';
import { Button } from '@/components/ui/button';
import type { ProjectImportProgress } from '@agentgate/controller';

function isProgress(
  value: unknown,
): value is { type: 'progress' } & ProjectImportProgress {
  return (
    typeof value === 'object' &&
    value !== null &&
    'type' in value &&
    value.type === 'progress' &&
    'phase' in value &&
    typeof value.phase === 'string' &&
    'percent' in value &&
    (value.percent === null || typeof value.percent === 'number')
  );
}

export function FetchProjectHistory({ projectId }: { projectId: string }) {
  const abort = useRef<AbortController | null>(null);
  const [pending, setPending] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function fetchHistory() {
    setPending(true);
    setStatus('Fetching full repository history…');
    setError(null);
    const controller = new AbortController();
    abort.current = controller;
    try {
      const response = await fetch(
        `/api/projects/${projectId}/source/history`,
        { method: 'POST', signal: controller.signal },
      );
      if (!response.ok)
        throw new Error('The full repository history could not be fetched.');
      if (!response.body)
        throw new Error('The progress stream is unavailable.');
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      let completed = false;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          if (!line) continue;
          const event: unknown = JSON.parse(line);
          if (isProgress(event))
            setStatus(
              `Fetching full history${
                event.percent === null ? '…' : ` · ${event.percent}%`
              }`,
            );
          else if (
            typeof event === 'object' &&
            event !== null &&
            'type' in event &&
            event.type === 'complete'
          ) {
            completed = true;
            setStatus('Full history fetched.');
          } else if (
            typeof event === 'object' &&
            event !== null &&
            'type' in event &&
            event.type === 'error' &&
            'message' in event &&
            typeof event.message === 'string'
          )
            throw new Error(event.message);
          else throw new Error('The progress response was invalid.');
        }
      }
      if (!completed) throw new Error('The history fetch ended unexpectedly.');
    } catch (failure) {
      if (failure instanceof DOMException && failure.name === 'AbortError')
        setStatus('Fetch canceled.');
      else {
        setStatus(null);
        setError(
          failure instanceof Error
            ? failure.message
            : 'The repository history could not be fetched.',
        );
      }
    } finally {
      abort.current = null;
      setPending(false);
    }
  }

  return (
    <div className="mt-4">
      {pending ? (
        <Button
          type="button"
          variant="outline"
          onClick={() => abort.current?.abort()}
        >
          Cancel fetch
        </Button>
      ) : (
        <Button
          type="button"
          variant="outline"
          onClick={() => void fetchHistory()}
        >
          Fetch full history
        </Button>
      )}
      {status && (
        <p role="status" className="muted mt-2">
          {status}
        </p>
      )}
      {error && (
        <p role="alert" className="error-message mt-2">
          {error}
        </p>
      )}
    </div>
  );
}
