'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { cancelRun, saveOutcome, sendPrompt } from '@/app/actions';
import { Button } from './ui/button';
import { Icon } from './icon';

type Turn = { role: 'user' | 'assistant'; text: string };
type Source = { documentId: string; title: string; seq: number };
type StreamEvent = { seq: number; type: string; text: string };
function parseEvent(data: string): StreamEvent | null {
  try {
    const event: unknown = JSON.parse(data);
    if (
      typeof event === 'object' &&
      event !== null &&
      'seq' in event &&
      typeof event.seq === 'number' &&
      Number.isInteger(event.seq) &&
      'type' in event &&
      typeof event.type === 'string' &&
      'text' in event &&
      typeof event.text === 'string'
    )
      return { seq: event.seq, type: event.type, text: event.text };
    return null;
  } catch {
    return null;
  }
}
export function SessionChat({
  projectId,
  sources,
  sessionId,
  turns,
  activeRunId,
  activePrompt,
}: {
  projectId: string;
  sources: Source[][];
  sessionId: string;
  turns: Turn[];
  activeRunId: string | null;
  activePrompt: string | null;
}) {
  const router = useRouter();
  const [runId, setRunId] = useState(activeRunId),
    [prompt, setPrompt] = useState(''),
    [live, setLive] = useState(''),
    [status, setStatus] = useState(''),
    [error, setError] = useState<string | null>(null),
    [pending, setPending] = useState(false),
    [cancelling, setCancelling] = useState(false);
  const pendingPrompt = useRef(activePrompt),
    cursor = useRef(0);
  useEffect(() => {
    if (!runId) return;
    cursor.current = 0;
    setLive('');
    setStatus('Generating and checking the answer…');
    const source = new EventSource(`/api/runs/${runId}/events`);
    source.onopen = () => setStatus('Generating and checking the answer…');
    source.onerror = () => setStatus('Connection interrupted · reconnecting…');
    source.onmessage = (message: MessageEvent<string>) => {
      const event = parseEvent(message.data);
      if (!event) {
        source.close();
        setError(
          'The execution stream could not be read. Reload to restore the saved session.',
        );
        return;
      }
      if (event.seq <= cursor.current) return;
      cursor.current = event.seq;
      if (event.type === 'text_delta') {
        setStatus('Delivering checked answer…');
        setLive((current) => current + event.text);
      }
      if (event.type === 'cancelled') setError('Run cancelled.');
      if (
        ['completed', 'failed', 'cancelled', 'blocked'].includes(event.type)
      ) {
        source.close();
        setRunId(null);
        setStatus('');
        setCancelling(false);
        pendingPrompt.current = null;
        router.refresh();
      }
    };
    return () => source.close();
  }, [runId, router]);
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (pending || runId || !prompt.trim()) return;
    setPending(true);
    setError(null);
    try {
      const result = await sendPrompt(sessionId, prompt);
      if (result.error !== null) {
        setError(result.error);
        return;
      }
      pendingPrompt.current = prompt;
      setPrompt('');
      setRunId(result.runId);
    } catch {
      setError(
        'The task could not be submitted. Check the connection and try again.',
      );
    } finally {
      setPending(false);
    }
  }
  async function cancel() {
    if (!runId) return;
    setCancelling(true);
    try {
      await cancelRun(runId);
      setStatus('Cancellation requested…');
    } catch {
      setError('Cancellation could not be confirmed. Reconnect and try again.');
      setCancelling(false);
    }
  }
  return (
    <div className="conversation-surface">
      <ol className="conversation" aria-label="Conversation">
        {turns.length === 0 && !runId && (
          <li className="empty-state">
            <span className="empty-icon">
              <Icon name="spark" width={26} height={26} />
            </span>
            <h3>What would you like to work on?</h3>
            <p>
              Your project context is included. Retrieved sources appear with
              the answer.
            </p>
          </li>
        )}
        {turns.map((turn, index) => (
          <li key={`${index}-${turn.role}`} className={`turn ${turn.role}`}>
            <span className="turn-avatar">
              <Icon
                name={turn.role === 'user' ? 'message' : 'spark'}
                width={16}
              />
            </span>
            <div className="turn-body">
              <span className="turn-label">
                {turn.role === 'user' ? 'You' : 'Model'}
              </span>
              <div className="turn-text">{turn.text}</div>
              {turn.role === 'assistant' && (
                <AnswerDetails
                  projectId={projectId}
                  text={turn.text}
                  sources={sources[Math.floor(index / 2)] ?? []}
                />
              )}
            </div>
          </li>
        ))}
        {runId && pendingPrompt.current && (
          <li className="turn user">
            <span className="turn-avatar">
              <Icon name="message" width={16} />
            </span>
            <div className="turn-body">
              <span className="turn-label">You</span>
              <div className="turn-text">{pendingPrompt.current}</div>
            </div>
          </li>
        )}
        {runId && (
          <li className="turn assistant">
            <span className="turn-avatar state-pulse">
              <Icon name="spark" width={16} />
            </span>
            <div className="turn-body">
              <span className="turn-label" role="status">
                Model · {status}
              </span>
              <div className="turn-text">{live}</div>
            </div>
          </li>
        )}
      </ol>
      {error && (
        <p role="alert" className="error-message px-6 pb-4">
          {error}
        </p>
      )}
      <form onSubmit={submit} className="composer">
        <label htmlFor="prompt" className="sr-only">
          Task
        </label>
        <textarea
          id="prompt"
          required
          maxLength={8000}
          rows={2}
          value={prompt}
          onChange={(event) => setPrompt(event.target.value)}
          disabled={runId !== null || pending}
          placeholder="Ask anything about your project…"
          onKeyDown={(event) => {
            if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
              event.preventDefault();
              event.currentTarget.form?.requestSubmit();
            }
          }}
        />
        <div className="composer-footer">
          <span className="composer-hint">
            Context shared · Tools disabled
            <span className="hidden sm:inline"> · ⌘ Return</span>
          </span>
          <div className="composer-actions">
            {runId ? (
              <Button
                type="button"
                variant="outline"
                disabled={cancelling}
                onClick={() => void cancel()}
              >
                <Icon name="stop" width={14} className="mr-2" />
                {cancelling ? 'Cancelling…' : 'Cancel'}
              </Button>
            ) : (
              <Button type="submit" disabled={pending || !prompt.trim()}>
                <Icon name="send" width={15} className="mr-2" />
                {pending ? 'Sending…' : 'Run task'}
              </Button>
            )}
          </div>
        </div>
      </form>
    </div>
  );
}
function AnswerDetails({
  projectId,
  text,
  sources,
}: {
  projectId: string;
  text: string;
  sources: Source[];
}) {
  const titles = [...new Set(sources.map((source) => source.title))];
  return (
    <div className="answer-details">
      {titles.length > 0 && (
        <p>
          Retrieved context: <span>{titles.join(', ')}</span>
        </p>
      )}
      <details className="mt-2">
        <summary>Answer details</summary>
        <p className="mt-2">
          Verify the answer before adding it to shared project context.
        </p>
        <form action={saveOutcome}>
          <input type="hidden" name="projectId" value={projectId} />
          <input type="hidden" name="text" value={text.slice(0, 500)} />
          <button type="submit" className="text-button">
            Save as verified outcome
          </button>
        </form>
      </details>
    </div>
  );
}
