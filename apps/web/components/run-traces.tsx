import Link from 'next/link';
import type {
  Run,
  RunStatus,
  RunTrace,
  RunTraceStage,
} from '@agentgate/controller';

const STAGE_STATUS_LABELS: Record<RunTraceStage['status'], string> = {
  done: 'Done',
  blocked: 'Blocked',
  failed: 'Failed',
  'not-run': 'Not run',
  pending: 'Pending',
  cancelled: 'Cancelled',
};

const STAGE_STATUS_BADGE: Record<RunTraceStage['status'], string> = {
  done: 'bg-teal-100 text-teal-900',
  blocked: 'bg-red-100 text-red-900',
  failed: 'bg-red-100 text-red-900',
  'not-run': 'bg-stone-200 text-stone-700',
  pending: 'bg-amber-100 text-amber-900',
  cancelled: 'bg-stone-200 text-stone-700',
};

const RUN_STATUS_BADGE: Record<RunStatus, string> = {
  queued: 'bg-amber-100 text-amber-900',
  running: 'bg-amber-100 text-amber-900',
  completed: 'bg-teal-100 text-teal-900',
  failed: 'bg-red-100 text-red-900',
  cancelled: 'bg-stone-200 text-stone-700',
  blocked: 'bg-red-100 text-red-900',
};

const SECURITY_STAGE_LABELS = {
  input: 'Task check',
  ingestion: 'Document ingestion',
  retrieval: 'Retrieved content',
  output: 'Answer check',
} as const;

function formatTimestamp(iso: string): string {
  return iso.slice(0, 19).replace('T', ' ');
}

/** Truncate by code point, so a surrogate pair is never split in half. */
function shortPrompt(prompt: string): string {
  const points = [...prompt];
  return points.length > 200 ? `${points.slice(0, 200).join('')}…` : prompt;
}

export type RunTraceItem = { run: Run; trace: RunTrace | null };

/**
 * Per-run timelines built only from already-stored run events, retrieved
 * sources, and security events. No model text or retrieved excerpts are
 * shown here; full security findings live on the Security page.
 */
export function RunTraces({
  items,
  totalRuns,
}: {
  items: RunTraceItem[];
  totalRuns: number;
}) {
  if (items.length === 0) return null;
  const shown = items;
  return (
    <section aria-labelledby="run-traces-title" className="mt-12">
      <h2
        id="run-traces-title"
        className="mb-2 text-xl font-semibold tracking-tight"
      >
        Run traces
      </h2>
      <p className="mb-6 max-w-2xl text-sm leading-6 text-stone-600">
        What each run actually did, in order: task check, retrieval, generation,
        and answer check. A stage marked “Not run” did not happen for that run,
        for example generation after an early block. Traces show the run state
        when this page loaded; the chat refreshes the page when an active run
        finishes.
      </p>
      {totalRuns > shown.length && (
        <p className="mb-4 text-sm text-stone-600">
          Showing the latest {shown.length} of {totalRuns} runs.
        </p>
      )}
      <ol className="space-y-4">
        {shown.map(({ run, trace }, index) => (
          <li
            key={run.id}
            className="rounded-xl border border-stone-300 bg-white p-5"
          >
            {trace === null ? (
              <>
                <p className="text-sm font-medium">
                  <span
                    className={`mr-2 rounded px-2 py-0.5 text-xs uppercase tracking-wide ${RUN_STATUS_BADGE[run.status]}`}
                  >
                    {run.status}
                  </span>
                  {shortPrompt(run.prompt)}
                </p>
                <p className="mt-3 text-sm text-stone-600">
                  Trace unavailable for this run: a stored event for this run
                  could not be parsed.
                </p>
              </>
            ) : (
              <details open={index === 0}>
                <summary className="cursor-pointer rounded focus-visible:outline-2 focus-visible:outline-teal-700">
                  <span
                    className={`mr-2 rounded px-2 py-0.5 text-xs uppercase tracking-wide ${RUN_STATUS_BADGE[trace.run.status]}`}
                  >
                    {trace.run.status}
                  </span>
                  <span className="break-words text-sm font-medium">
                    {shortPrompt(trace.run.prompt)}
                  </span>
                </summary>
                <p className="mt-3 text-xs text-stone-600">
                  Started{' '}
                  <time dateTime={trace.run.createdAt}>
                    {formatTimestamp(trace.run.createdAt)}
                  </time>{' '}
                  UTC
                  {trace.run.finishedAt && (
                    <>
                      {' '}
                      · Finished{' '}
                      <time dateTime={trace.run.finishedAt}>
                        {formatTimestamp(trace.run.finishedAt)}
                      </time>{' '}
                      UTC
                    </>
                  )}
                </p>
                {trace.run.error && (
                  <p className="mt-2 text-sm text-red-800">{trace.run.error}</p>
                )}
                <ol className="mt-4 space-y-3">
                  {trace.stages.map((stage) => (
                    <li key={stage.key} className="flex gap-3 text-sm">
                      <span
                        className={`h-fit shrink-0 rounded px-2 py-0.5 text-xs uppercase tracking-wide ${STAGE_STATUS_BADGE[stage.status]}`}
                      >
                        {STAGE_STATUS_LABELS[stage.status]}
                      </span>
                      <span>
                        <span className="font-medium">{stage.label}: </span>
                        {stage.detail}
                      </span>
                    </li>
                  ))}
                </ol>
                {trace.sources.length > 0 && (
                  <div className="mt-4">
                    <p className="text-xs font-semibold uppercase tracking-widest text-stone-600">
                      Retrieved sources
                    </p>
                    <ul className="mt-2 list-disc space-y-1 pl-5 text-sm">
                      {trace.sources.map((source) => (
                        <li key={`${source.documentId}-${source.seq}`}>
                          {source.title} · chunk {source.seq}
                        </li>
                      ))}
                    </ul>
                  </div>
                )}
                {trace.securityEvents.length > 0 && (
                  <div className="mt-4">
                    <p className="text-xs font-semibold uppercase tracking-widest text-stone-600">
                      Security events for this run
                    </p>
                    <ul className="mt-2 space-y-2 text-sm">
                      {trace.securityEvents.map((event) => (
                        <li key={event.id}>
                          <span className="font-mono text-sm">
                            {event.rule}
                          </span>{' '}
                          · {SECURITY_STAGE_LABELS[event.stage]} ·{' '}
                          {event.outcome}
                          {event.score !== null &&
                            ` · score ${event.score.toFixed(2)}`}
                          <span className="block text-stone-600">
                            {event.detail}
                          </span>
                        </li>
                      ))}
                    </ul>
                    <p className="mt-3 text-xs text-stone-600">
                      Full findings, including any stored evidence, are on the{' '}
                      <Link href="/security" className="underline">
                        Security page
                      </Link>
                      .
                    </p>
                  </div>
                )}
              </details>
            )}
          </li>
        ))}
      </ol>
    </section>
  );
}
