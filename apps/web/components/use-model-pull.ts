import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { cancelPull, pullModel } from '@/app/actions';

export type Pull = {
  model: string;
  status: 'downloading' | 'done' | 'failed' | 'cancelled';
  message: string;
  completedBytes: number;
  totalBytes: number;
} | null;

/** Starts a model download and follows its progress until it ends, then refreshes the page. */
export function useModelPull() {
  const router = useRouter();
  const [pull, setPull] = useState<Pull>(null);
  const [error, setError] = useState<string | null>(null);
  const downloading = pull?.status === 'downloading';

  useEffect(() => {
    let finished = false;
    async function poll() {
      const response = await fetch('/api/models/pull', { cache: 'no-store' });
      if (!response.ok) return;
      const state = (await response.json()) as Pull;
      setPull(state);
      if (state && state.status !== 'downloading' && !finished) {
        finished = true;
        router.refresh();
      }
    }
    void poll();
    const timer = setInterval(() => {
      if (!finished) void poll();
    }, 1000);
    return () => clearInterval(timer);
  }, [router, downloading]);

  async function install(model: string, fallbacks: string[] = []) {
    setError(null);
    const result = await pullModel(model, fallbacks);
    if (result.error) return setError(result.error);
    setPull({
      model,
      status: 'downloading',
      message: 'Starting…',
      completedBytes: 0,
      totalBytes: 0,
    });
  }
  const percent =
    pull && pull.totalBytes > 0
      ? Math.min(100, Math.round((pull.completedBytes / pull.totalBytes) * 100))
      : 0;
  return { pull, error, downloading, percent, install, cancel: cancelPull };
}
