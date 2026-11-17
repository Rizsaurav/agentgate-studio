import Link from 'next/link';
import {
  SPAN_LABELS,
  formatDuration,
  slowestSpan,
  usage,
  type Run,
  type RunStatus,
  type RunTrace,
  type RunTraceStage,
  type Trace,
} from '@agentgate/controller';

const STAGE_STATUS_LABELS: Record<RunTraceStage['status'], string> = {
  done: 'Done',
  blocked: 'Blocked',
  failed: 'Failed',
  'not-run': 'Not run',
  pending: 'Pending',
  cancelled: 'Cancelled',
};

type Tone = 'ok' | 'bad' | 'pending' | 'neutral';

const STAGE_STATUS_BADGE: Record<RunTraceStage['status'], Tone> = {
  done: 'ok',
  blocked: 'bad',
  failed: 'bad',
  'not-run': 'neutral',
  pending: 'pending',
  cancelled: 'neutral',
};

const RUN_STATUS_BADGE: Record<RunStatus, Tone> = {
  queued: 'pending',
  running: 'pending',
  completed: 'ok',
  failed: 'bad',
  cancelled: 'neutral',
  blocked: 'bad',
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

export type RunTraceItem = {
  run: Run;
  trace: RunTrace | null;
  /** Stage timings, tokens and scores from run telemetry (#10); null when none was recorded. */
  timing: Trace | null;
};

const SPAN_STATUS_TONE: Record<Trace['spans'][number]['status'], Tone> = {
  ok: 'ok',
  blocked: 'bad',
  error: 'bad',
  cancelled: 'neutral',
};

/**
 * Where the time went, stage by stage, with the numbers the run recorded. Bars are decorative;
 * every duration is also given as text, so the view reads the same without them.
 */
function Timeline({ timing, threshold }: { timing: Trace; threshold: number }) {
  const slowest = slowestSpan(timing);
  const used = usage(timing);
  const total = Math.max(timing.durationMs, 1);
  return (
    <div className="mt-4">
      <p className="text-xs font-semibold uppercase tracking-widest muted">
        Timeline
      </p>
      <p className="mt-2 text-sm">
        {formatDuration(timing.durationMs)} in all
        {slowest && (
          <>
            ; most of it in{' '}
            <span className="font-medium">{SPAN_LABELS[slowest.name]}</span> (
            {formatDuration(slowest.durationMs)})
          </>
        )}
        {timing.rule && (
          <>
            . Blocked by rule <span className="font-mono">{timing.rule}</span>
          </>
        )}
        .
        {used.inputTokens !== null && (
          <>
            {' '}
            {used.inputTokens} tokens in, {used.outputTokens ?? 0} out
            {used.costUsd !== null && `, $${used.costUsd.toFixed(4)}`}.
          </>
        )}
      </p>
      <ol className="mt-3 space-y-2">
        {timing.spans.map((span) => {
          const score = span.attributes['agentgate.scanner.score'];
          const passages = span.attributes['agentgate.passages'];
          return (
            <li key={`${span.name}-${span.startMs}`} className="text-sm">
              <div className="flex flex-wrap items-baseline gap-3">
                <span
                  className="trace-badge shrink-0"
                  data-tone={SPAN_STATUS_TONE[span.status]}
                >
                  {span.status}
                </span>
                <span className="font-medium">{SPAN_LABELS[span.name]}</span>
                <span className="muted">{formatDuration(span.durationMs)}</span>
                {score !== undefined && (
                  <span className="muted">
                    scanner score {score.toFixed(2)} (blocks at{' '}
                    {threshold.toFixed(2)})
                  </span>
                )}
                {passages !== undefined && (
                  <span className="muted">
                    {passages} passage{passages === 1 ? '' : 's'}
                  </span>
                )}
                {span.attributes['agentgate.rule'] && (
                  <span className="font-mono">
                    {span.attributes['agentgate.rule']}
                  </span>
                )}
              </div>
              <div
                aria-hidden="true"
                className="mt-1 h-1.5 rounded bg-white/10"
              >
                <div
                  className="h-1.5 rounded bg-violet-400"
                  style={{
                    marginLeft: `${(span.startMs / total) * 100}%`,
                    width: `${Math.max((span.durationMs / total) * 100, 0.5)}%`,
                  }}
                />
              </div>
            </li>
          );
        })}
      </ol>
    </div>
  );
}

/**
 * Per-run timelines built only from already-stored run events, retrieved
 * sources, and security events. No model text or retrieved excerpts are
 * shown here; full security findings live on the Security page.
 */
export function RunTraces({
  items,
  totalRuns,
  threshold,
}: {
  items: RunTraceItem[];
  totalRuns: number;
  /** The scanner's prompt-injection threshold, shown beside each score. */
  threshold: number;
}) {
  if (items.length === 0) return null;
  const shown = items;
  return (
    <section aria-labelledby="run-traces-title" className="mt-12">
      <h2 id="run-traces-title" className="mb-2 text-xl font-semibold">
        Run traces
      </h2>
      <p className="mb-6 max-w-2xl text-sm leading-6 muted">
        What each run actually did, in order: task check, retrieval, generation,
        and answer check. A stage marked “Not run” did not happen for that run,
        for example generation after an early block. Traces show the run state
        when this page loaded; the chat refreshes the page when an active run
        finishes.
      </p>
      {totalRuns > shown.length && (
        <p className="mb-4 text-sm muted">
          Showing the latest {shown.length} of {totalRuns} runs.
        </p>
      )}
      <ol className="space-y-4">
        {shown.map(({ run, trace, timing }, index) => (
          <li key={run.id} className="activity-panel">
            {trace === null ? (
              <>
                <p className="text-sm font-medium">
                  <span
                    className="trace-badge mr-2"
                    data-tone={RUN_STATUS_BADGE[run.status]}
                  >
                    {run.status}
                  </span>
                  {shortPrompt(run.prompt)}
                </p>
                <p className="mt-3 text-sm muted">
                  Trace unavailable for this run: a stored event for this run
                  could not be parsed.
                </p>
              </>
            ) : (
              <details open={index === 0}>
                <summary className="cursor-pointer rounded ">
                  <span
                    className="trace-badge mr-2"
                    data-tone={RUN_STATUS_BADGE[trace.run.status]}
                  >
                    {trace.run.status}
                  </span>
                  <span className="break-words text-sm font-medium">
                    {shortPrompt(trace.run.prompt)}
                  </span>
                </summary>
                <p className="mt-3 text-xs muted">
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
                  <p className="mt-2 text-sm error-text">{trace.run.error}</p>
                )}
                <ol className="mt-4 space-y-3">
                  {trace.stages.map((stage) => (
                    <li key={stage.key} className="flex gap-3 text-sm">
                      <span
                        className="trace-badge h-fit shrink-0"
                        data-tone={STAGE_STATUS_BADGE[stage.status]}
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
                {timing && <Timeline timing={timing} threshold={threshold} />}
                {trace.sources.length > 0 && (
                  <div className="mt-4">
                    <p className="text-xs font-semibold uppercase tracking-widest muted">
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
                    <p className="text-xs font-semibold uppercase tracking-widest muted">
                      Security events for this run
                    </p>
                    <ul className="mt-2 space-y-2 text-sm">
                      {trace.securityEvents.map((event) => (
                        <li key={event.id}>
                          <Link
                            href={`/security#finding-${event.id}`}
                            className="font-mono text-sm underline"
                          >
                            {event.rule}
                          </Link>{' '}
                          · {SECURITY_STAGE_LABELS[event.stage]} ·{' '}
                          {event.outcome}
                          {event.score !== null &&
                            ` · score ${event.score.toFixed(2)}`}
                          <span className="block muted">{event.detail}</span>
                        </li>
                      ))}
                    </ul>
                    <p className="mt-3 text-xs muted">
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
