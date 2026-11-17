import Link from 'next/link';
import { checkServices } from '@agentgate/controller';
import {
  agentStore,
  endpoints,
  projects,
  security,
  telemetry,
} from '@/lib/controller';
import { clearTelemetry, setTelemetry } from '@/app/actions';
import { Button } from '@/components/ui/button';
import { EvaluationsPanel } from '@/components/evaluations-panel';
import { Icon } from '@/components/icon';
export const dynamic = 'force-dynamic';
const STAGES = {
  input: 'Task check',
  ingestion: 'Document ingestion',
  retrieval: 'Retrieved content',
  output: 'Answer check',
} as const;
export default async function SecurityPage({
  searchParams,
}: {
  searchParams: Promise<{ view?: string }>;
}) {
  const view =
    (await searchParams).view === 'evaluations' ? 'evaluations' : 'findings';
  const events = security().recent(100),
    checks = await checkServices({
      ...endpoints(),
      usesLocalModels: agentStore().usesLocalModels(),
    });
  const scanner = checks.find((check) => check.name.includes('scanner'));
  const names = new Map(
    projects()
      .list()
      .map((project) => [project.id, project.name]),
  );
  return (
    <>
      <header className="page-heading">
        <span className="eyebrow">Inspect. Verify. Improve.</span>
        <h1>Security & Verification</h1>
        <p>
          Enforced protections, attributable findings, and repeatable tests.
          These checks reduce risk; they do not guarantee protection from every
          attack.
        </p>
      </header>
      <div className="security-overview">
        <div>
          <Icon name="shield" />
          <span>LLM Guard scanner</span>
          <span
            className={`status-label ${scanner?.ok ? 'positive' : 'failure'}`}
          >
            {scanner?.ok ? 'Reachable' : 'Unavailable · fails closed'}
          </span>
        </div>
        <div>
          <Icon name="key" />
          <span>Agent tools</span>
          <span className="status-label">Disabled</span>
        </div>
      </div>
      <section
        className="soft-surface mb-5"
        aria-labelledby="telemetry-heading"
      >
        <h2 id="telemetry-heading">Run telemetry</h2>
        <p>
          Each run&apos;s stage timings, tokens, scanner scores and blocking
          rule are kept on this computer for 30 days. No prompt, answer or
          document text is stored.
        </p>
        <div className="flex gap-3 items-center">
          <form action={setTelemetry}>
            <input
              type="hidden"
              name="enabled"
              value={telemetry().enabled ? 'off' : 'on'}
            />
            <Button type="submit" variant="outline">
              {telemetry().enabled ? 'Turn off' : 'Turn on'}
            </Button>
          </form>
          <form action={clearTelemetry}>
            <Button type="submit" variant="outline">
              Clear telemetry
            </Button>
          </form>
          <span className="status-label">
            {telemetry().enabled ? 'On' : 'Off'}
          </span>
        </div>
      </section>
      {!scanner?.ok && (
        <p role="alert" className="error-message mb-5">
          Tasks and new documents are blocked until the security scanner is
          available. {scanner?.fix}
        </p>
      )}
      <nav className="view-tabs" aria-label="Security views">
        <Link
          href="/security"
          aria-current={view === 'findings' ? 'page' : undefined}
        >
          <Icon name="shield" />
          Guardrails & findings
        </Link>
        <Link
          href="/security?view=evaluations"
          aria-current={view === 'evaluations' ? 'page' : undefined}
        >
          <Icon name="activity" />
          Evaluations
        </Link>
      </nav>
      {view === 'evaluations' ? (
        <EvaluationsPanel />
      ) : (
        <>
          <section className="guardrail-grid" aria-label="Enforced protections">
            <div>
              <Icon name="shield" />
              <h2>Input & retrieval</h2>
              <p>
                LLM Guard scans prompts and documents. Suspicious content is
                blocked or quarantined.
              </p>
            </div>
            <div>
              <Icon name="document" />
              <h2>Output inspection</h2>
              <p>
                Deterministic rules check answers for secrets and prohibited
                content before delivery.
              </p>
            </div>
            <div>
              <Icon name="key" />
              <h2>Restricted capabilities</h2>
              <p>
                No shell or filesystem tools are granted to the agent.
                References stay within the approved folder.
              </p>
            </div>
          </section>
          <div className="section-heading">
            <h2>Security findings</h2>
            <span className="muted">
              {events.length === 100 ? 'Latest 100' : events.length} recorded
            </span>
          </div>
          {events.length === 0 ? (
            <div className="empty-state">
              <span className="empty-icon">
                <Icon name="shield" width={28} height={28} />
              </span>
              <h3>No findings recorded</h3>
              <p>
                Real blocked or quarantined content will appear here with its
                source and enforced rule.
              </p>
            </div>
          ) : (
            <ul className="findings-list">
              {events.map((event) => (
                <li key={event.id}>
                  <div className="finding-heading">
                    <span
                      className={`status-label ${event.outcome === 'released' ? '' : 'failure'}`}
                    >
                      <Icon name="warning" width={12} />
                      {event.outcome}
                    </span>
                    <strong>{event.rule}</strong>
                    <time dateTime={event.createdAt}>
                      {event.createdAt.slice(0, 19).replace('T', ' ')} UTC
                    </time>
                  </div>
                  <p className="finding-description">{event.detail}</p>
                  <div className="finding-source">
                    <span>{STAGES[event.stage]}</span>
                    <span>Source: {event.source}</span>
                    <Link href={`/projects/${event.projectId}`}>
                      {names.get(event.projectId) ?? 'Unknown project'} ↗
                    </Link>
                  </div>
                  <details className="finding-evidence">
                    <summary>Evidence & technical details</summary>
                    <dl>
                      <dt>Rule</dt>
                      <dd>{event.rule}</dd>
                      <dt>Finding ID</dt>
                      <dd>{event.id}</dd>
                      {event.score !== null && (
                        <>
                          <dt>Scanner score</dt>
                          <dd>{event.score.toFixed(2)}</dd>
                        </>
                      )}
                    </dl>
                    {event.evidence && (
                      <blockquote>{event.evidence}</blockquote>
                    )}
                  </details>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </>
  );
}
