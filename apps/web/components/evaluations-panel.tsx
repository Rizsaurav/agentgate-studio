import { Suspense } from 'react';
import {
  guardrailRates,
  type GuardrailRate,
  type GuardrailRates,
} from '@agentgate/controller';
import { evals } from '@/lib/controller';
import { githubRuns } from '@/lib/github';
import { startEvaluation } from '@/app/actions';
import { AutoRefresh } from '@/components/auto-refresh';
import { Button } from '@/components/ui/button';

const STATUS_STYLE: Record<string, string> = {
  passed: 'status-label positive',
  failed: 'status-label failure',
  error: 'status-label failure',
  queued: 'status-label',
  running: 'status-label',
};

export async function EvaluationsPanel() {
  const service = evals();
  const runs = service.recent(15);
  const active = runs.some(
    (r) => r.status === 'queued' || r.status === 'running',
  );
  return (
    <>
      <AutoRefresh active={active} />
      <p className="mb-8 max-w-2xl text-sm leading-6 text-stone-600">
        A version-controlled Promptfoo suite runs the application&apos;s real
        pipeline (ingestion, retrieval, scanning, output checks) against
        functional and security cases. The model is a scripted fixture, so no
        paid API key is needed. The same suite runs in GitHub Actions.
      </p>
      {service.available ? (
        <div className="mb-10 space-y-4">
          <form action={startEvaluation}>
            <input type="hidden" name="profile" value="enforced" />
            <Button type="submit" disabled={active}>
              Run required suite
            </Button>
          </form>
          <details className="max-w-2xl rounded-xl border border-red-900/30 bg-red-50 p-4 text-sm">
            <summary className="cursor-pointer font-medium text-red-900">
              Deliberately weak demonstration (expected to fail)
            </summary>
            <p className="mt-3 leading-6 text-stone-800">
              Runs the same cases with injection scanning, document screening,
              and output inspection switched off, to show the suite catches a
              security regression. It never changes how the application behaves.
            </p>
            <form action={startEvaluation} className="mt-3">
              <input type="hidden" name="profile" value="weak-demo" />
              <Button type="submit" variant="outline" disabled={active}>
                Run weak demo
              </Button>
            </form>
          </details>
        </div>
      ) : (
        <p role="status" className="mb-10 text-sm text-stone-700">
          The evaluation suite is not shipped with the app, to keep it small. It
          runs in CI on every change (see the GitHub runs below) and from source
          with <code>npm run eval</code>.
        </p>
      )}

      <h2 className="mb-4 text-xl font-semibold">Recent runs</h2>
      {runs.length === 0 ? (
        <p className="rounded-xl border border-dashed border-stone-300 p-8 text-sm text-stone-700">
          No evaluations have run yet.
        </p>
      ) : (
        <ul className="space-y-4">
          {runs.map((run) => {
            const results = service.results(run.id);
            return (
              <li
                key={run.id}
                className="rounded-xl border border-stone-300 bg-white p-5"
              >
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <p className="font-semibold">
                    <span
                      className={`rounded px-2 py-0.5 text-xs uppercase tracking-wide ${STATUS_STYLE[run.status] ?? ''}`}
                    >
                      {run.status}
                    </span>{' '}
                    {run.profile === 'weak-demo'
                      ? 'Weak demo (expected to fail)'
                      : 'Required suite'}
                  </p>
                  <time
                    dateTime={run.createdAt}
                    className="text-xs text-stone-600"
                  >
                    {run.createdAt.slice(0, 19).replace('T', ' ')} UTC
                  </time>
                </div>
                {run.finishedAt && run.status !== 'error' && (
                  <>
                    <p className="mt-2 text-sm">
                      {run.passed} of {run.total} cases passed
                    </p>
                    <RatesSideBySide rates={guardrailRates(results)} />
                  </>
                )}
                {run.error && (
                  <p className="mt-2 text-sm text-amber-900">{run.error}</p>
                )}
                <dl className="mt-3 grid gap-x-6 gap-y-1 text-xs text-stone-700 sm:grid-cols-2">
                  <div>
                    <dt className="inline text-stone-600">Configuration: </dt>
                    <dd className="inline font-mono">
                      {run.configHash.slice(0, 12)}
                    </dd>
                  </div>
                  <div>
                    <dt className="inline text-stone-600">Commit: </dt>
                    <dd className="inline font-mono">
                      {run.gitSha ? run.gitSha.slice(0, 8) : 'unknown'}
                      {run.gitDirty ? ' (uncommitted changes)' : ''}
                    </dd>
                  </div>
                  {run.gitSha && (
                    <Suspense fallback={null}>
                      <HostedRun sha={run.gitSha} />
                    </Suspense>
                  )}
                </dl>
                {results.some((r) => !r.passed) && (
                  <ul className="mt-3 space-y-1 border-t border-stone-200 pt-3 text-xs">
                    {results
                      .filter((r) => !r.passed)
                      .map((r) => (
                        <li key={r.description}>
                          <span className="font-medium">{r.description}</span>
                          {r.reason && (
                            <span className="text-stone-600">
                              {' '}
                              — {r.reason}
                            </span>
                          )}
                        </li>
                      ))}
                  </ul>
                )}
              </li>
            );
          })}
        </ul>
      )}

      <Suspense
        fallback={
          <p className="mt-12 text-sm text-stone-600">Checking GitHub…</p>
        }
      >
        <GithubSection />
      </Suspense>
    </>
  );
}

const percent = ({ count, total }: GuardrailRate) =>
  `${Math.round((count / total) * 100)}%`;

/**
 * The scanner's two kinds of error, side by side, so tightening one cannot hide the other getting
 * worse: benign content wrongly blocked, and injections caught.
 */
function RatesSideBySide({ rates }: { rates: GuardrailRates }) {
  const { falsePositives, detections } = rates;
  if (!falsePositives && !detections) return null;
  return (
    <dl className="mt-3 grid grid-cols-2 gap-3 text-sm">
      <div className="rounded-lg border border-stone-200 p-3">
        <dt className="text-xs text-stone-600">False-positive rate</dt>
        {falsePositives ? (
          <dd>
            <span className="text-lg font-semibold">
              {percent(falsePositives)}
            </span>
            <span className="block text-xs text-stone-600">
              {falsePositives.count} of {falsePositives.total} benign cases
              blocked
            </span>
          </dd>
        ) : (
          <dd className="text-xs text-stone-600">No benign cases</dd>
        )}
      </div>
      <div className="rounded-lg border border-stone-200 p-3">
        <dt className="text-xs text-stone-600">Detection rate</dt>
        {detections ? (
          <dd>
            <span className="text-lg font-semibold">{percent(detections)}</span>
            <span className="block text-xs text-stone-600">
              {detections.count} of {detections.total} injections caught
            </span>
          </dd>
        ) : (
          <dd className="text-xs text-stone-600">No injection cases</dd>
        )}
      </div>
    </dl>
  );
}

/** The GitHub Actions run for the same commit, when the GitHub CLI can see one. */
async function HostedRun({ sha }: { sha: string }) {
  const run = (await githubRuns()).runs.find((r) => r.headSha === sha);
  if (!run) return null;
  return (
    <div className="sm:col-span-2">
      <dt className="inline text-stone-600">GitHub run for this commit: </dt>
      <dd className="inline">
        <a href={run.url} className="underline">
          {run.workflowName} · {run.conclusion ?? run.status}
        </a>
      </dd>
    </div>
  );
}

/** Optional: only developers with the GitHub CLI signed in have hosted runs to show. */
async function GithubSection() {
  const github = await githubRuns();
  return (
    <>
      <h2 className="mb-4 mt-12 text-xl font-semibold">GitHub Actions</h2>
      {github.unavailable ? (
        <p className="text-sm text-stone-700">{github.unavailable}</p>
      ) : github.runs.length === 0 ? (
        <p className="text-sm text-stone-700">No workflow runs yet.</p>
      ) : (
        <ul className="space-y-2 text-sm">
          {github.runs.map((run) => (
            <li key={run.databaseId}>
              <a href={run.url} className="underline">
                {run.workflowName}
              </a>{' '}
              ·{' '}
              <span className="font-medium">
                {run.conclusion ?? run.status}
              </span>{' '}
              ·{' '}
              <span className="font-mono text-xs">
                {run.headSha.slice(0, 8)}
              </span>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
