import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { cancelPull, pullModel, unqueueModel } from '@/app/actions';

export type Pull = {
  model: string;
  status: 'downloading' | 'done' | 'failed' | 'cancelled';
  message: string;
  completedBytes: number;
  totalBytes: number;
} | null;

/** Starts model downloads and follows the current one and the queue, refreshing the page as each ends. */
export function useModelPull() {
  const router = useRouter();
  const [pull, setPull] = useState<Pull>(null);
  const [queued, setQueued] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const finished = useRef<string | null>(null);
  const downloading = pull?.status === 'downloading';
  const busy = downloading || queued.length > 0;

  const poll = useCallback(async () => {
    const response = await fetch('/api/models/pull', { cache: 'no-store' });
    if (!response.ok) return;
    const state = (await response.json()) as {
      current: Pull;
      queued: string[];
    };
    setPull(state.current);
    setQueued(state.queued);
    // Each model that ends refreshes the page once, so the chat picker and lists pick it up.
    const ended = state.current && state.current.status !== 'downloading';
    const key = ended
      ? `${state.current?.model}:${state.current?.status}`
      : null;
    if (key && finished.current !== key) {
      if (finished.current !== null) router.refresh();
      finished.current = key;
    }
  }, [router]);

  useEffect(() => {
    void poll();
    if (!busy) return;
    const timer = setInterval(() => void poll(), 1000);
    return () => clearInterval(timer);
  }, [poll, busy]);

  async function install(model: string, fallbacks: string[] = []) {
    setError(null);
    const result = await pullModel(model, fallbacks);
    if (result.error) return setError(result.error);
    finished.current ??= '';
    await poll();
  }
  async function unqueue(model: string) {
    await unqueueModel(model);
    await poll();
  }
  const percent =
    pull && pull.totalBytes > 0
      ? Math.min(100, Math.round((pull.completedBytes / pull.totalBytes) * 100))
      : 0;
  return {
    pull,
    queued,
    error,
    downloading,
    percent,
    install,
    unqueue,
    cancel: cancelPull,
  };
}
