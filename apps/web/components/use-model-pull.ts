import { useCallback, useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { cancelPull, pullModel, unqueueModel } from '@/app/actions';

export type Pull = {
  model: string;
  status: 'downloading' | 'done' | 'failed' | 'cancelled';
  step: 'runtime' | 'download' | 'verify' | 'ready';
  message: string;
  completedBytes: number;
  totalBytes: number;
} | null;

const IDLE_POLL_MS = 3000;
/** Fired when this page starts an install, so every view of the install updates at once. */
export const INSTALL_STARTED = 'agentgate:install-started';

/**
 * Starts model downloads and follows the current one and the queue, refreshing the page as each ends.
 * `watch` keeps checking while idle, so an install started anywhere in the app is noticed.
 */
export function useModelPull({ watch = false }: { watch?: boolean } = {}) {
  const router = useRouter();
  const [pull, setPull] = useState<Pull>(null);
  const [queued, setQueued] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
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
    setLoaded(true);
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
    const onStart = () => void poll();
    window.addEventListener(INSTALL_STARTED, onStart);
    return () => window.removeEventListener(INSTALL_STARTED, onStart);
  }, [poll]);

  useEffect(() => {
    void poll();
    if (!busy && !watch) return;
    const timer = setInterval(() => void poll(), busy ? 1000 : IDLE_POLL_MS);
    return () => clearInterval(timer);
  }, [poll, busy, watch]);

  async function install(model: string, fallbacks: string[] = []) {
    setError(null);
    const result = await pullModel(model, fallbacks);
    if (result.error) return setError(result.error);
    finished.current ??= '';
    window.dispatchEvent(new Event(INSTALL_STARTED));
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
    loaded,
    queued,
    error,
    downloading,
    percent,
    install,
    unqueue,
    cancel: cancelPull,
  };
}
