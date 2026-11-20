import {
  formatDuration,
  type ProjectTraceSummary,
} from '@agentgate/controller';

/**
 * A project's runs at a glance (#11): the slowest runs and where their time went, the rules that
 * blocked most, and tokens and cost per day. Built from run telemetry, so it holds numbers only.
 */
export function RunPerformance({ summary }: { summary: ProjectTraceSummary }) {
  if (summary.runs === 0) return null;
  return (
    <section
      className="soft-surface mb-8"
      aria-labelledby="run-performance-title"
    >
      <div className="section-heading">
        <h2 id="run-performance-title">Run performance</h2>
        <span className="muted">
          Last {summary.runs} run{summary.runs === 1 ? '' : 's'} · kept 30 days
        </span>
      </div>
      <div className="grid gap-6 md:grid-cols-3">
        <div>
          <h3 className="text-sm font-semibold">Slowest runs</h3>
          <ol className="mt-2 space-y-1 text-sm">
            {summary.slowest.map((run) => (
              <li key={run.runId}>
                {formatDuration(run.durationMs)}
                <span className="muted">
                  {' '}
                  · {run.status}
                  {run.stage && ` · most in ${run.stage}`}
                </span>
              </li>
            ))}
          </ol>
        </div>
        <div>
          <h3 className="text-sm font-semibold">Most blocked rules</h3>
          {summary.blockedRules.length === 0 ? (
            <p className="mt-2 text-sm muted">No run was blocked.</p>
          ) : (
            <ol className="mt-2 space-y-1 text-sm">
              {summary.blockedRules.map(({ rule, count }) => (
                <li key={rule}>
                  <span className="font-mono">{rule}</span>
                  <span className="muted"> · {count}</span>
                </li>
              ))}
            </ol>
          )}
        </div>
        <div>
          <h3 className="text-sm font-semibold">Tokens and cost per day</h3>
          <table className="mt-2 w-full text-sm">
            <thead>
              <tr className="muted text-left">
                <th scope="col" className="font-normal">
                  Day
                </th>
                <th scope="col" className="font-normal">
                  Runs
                </th>
                <th scope="col" className="font-normal">
                  Tokens in / out
                </th>
                <th scope="col" className="font-normal">
                  Cost
                </th>
              </tr>
            </thead>
            <tbody>
              {summary.perDay.slice(0, 14).map((day) => (
                <tr key={day.day}>
                  <td>{day.day}</td>
                  <td>{day.runs}</td>
                  <td>
                    {day.inputTokens} / {day.outputTokens}
                  </td>
                  <td>
                    {day.costUsd > 0 ? `$${day.costUsd.toFixed(4)}` : '–'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </section>
  );
}
