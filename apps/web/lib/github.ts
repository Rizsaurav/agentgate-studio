import 'server-only';
import { listGithubRuns } from '@agentgate/controller';
import { repoRoot } from '@/lib/controller';

const CACHE_MS = 60_000;
type Runs = Awaited<ReturnType<typeof listGithubRuns>>;
const holder = globalThis as typeof globalThis & {
  githubRuns?: { at: number; pending: Promise<Runs> };
};

/** GitHub is a network call, so share one answer for a minute instead of asking on every page view. */
export function githubRuns(): Promise<Runs> {
  const cached = holder.githubRuns;
  if (cached && Date.now() - cached.at < CACHE_MS) return cached.pending;
  const pending = listGithubRuns(repoRoot());
  holder.githubRuns = { at: Date.now(), pending };
  return pending;
}
