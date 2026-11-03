'use client';
import Link from 'next/link';
import { Button } from '@/components/ui/button';
import { useModelPull } from './use-model-pull';

export function QuickInstall({
  best,
  fallbacks,
  ollamaInstalled,
  summary,
  error: loadError,
}: {
  best: { id: string; label: string; downloadGb: number } | null;
  fallbacks: string[];
  ollamaInstalled: boolean;
  summary: string;
  error: string | null;
}) {
  const { pull, error, downloading, percent, install, cancel } = useModelPull();
  if (loadError)
    return (
      <p role="alert" className="error-message">
        {loadError}
      </p>
    );
  if (!best)
    return (
      <p role="alert" className="muted">
        This computer ({summary}) is short on memory or disk space for local
        models.{' '}
        <Link href="/models" className="text-teal-800">
          Connect a cloud provider instead
        </Link>
        .
      </p>
    );
  return (
    <div className="space-y-3">
      <p className="muted">
        Your computer: {summary}. The best local model for it is{' '}
        <strong>{best.label}</strong> (about {best.downloadGb} GB). It runs
        entirely on this computer and is set up for you
        {ollamaInstalled
          ? '.'
          : ', including Ollama, the program that runs it (about 230 MB, from ollama.com).'}{' '}
        Once installed it is ready in the chat.
      </p>
      {downloading && pull ? (
        <div role="status">
          <progress
            value={percent}
            max={100}
            aria-label={`Installing ${best.label}`}
            className="w-full"
          />
          <p className="metadata mt-1">
            {percent}% · {pull.message}
          </p>
          <Button
            type="button"
            variant="outline"
            className="mt-2"
            onClick={() => void cancel()}
          >
            Cancel
          </Button>
        </div>
      ) : (
        <Button type="button" onClick={() => void install(best.id, fallbacks)}>
          Install {best.label} for me
        </Button>
      )}
      {pull?.status === 'failed' && (
        <p role="alert" className="error-message">
          {pull.message}
        </p>
      )}
      {error && (
        <p role="alert" className="error-message">
          {error}
        </p>
      )}
    </div>
  );
}
