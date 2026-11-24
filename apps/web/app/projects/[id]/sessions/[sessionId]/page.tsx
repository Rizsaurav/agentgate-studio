import Link from 'next/link';
import { notFound } from 'next/navigation';
import { projectIdSchema, sessionIdSchema } from '@agentgate/controller';
import { projects, security, sessions, context } from '@/lib/controller';
import { RunTraces } from '@/components/run-traces';
import { SessionChat } from '@/components/session-chat';
import { Panel } from '@/components/panel';
import { Icon } from '@/components/icon';
export const dynamic = 'force-dynamic';
export default async function SessionPage({
  params,
}: {
  params: Promise<{ id: string; sessionId: string }>;
}) {
  const { id, sessionId } = await params;
  if (
    !projectIdSchema.safeParse(id).success ||
    !sessionIdSchema.safeParse(sessionId).success
  )
    notFound();
  const project = projects().find(id),
    session = sessions().findSession(sessionId);
  if (!project || !session || session.projectId !== id) notFound();
  const runs = sessions().listRuns(session.id),
    active = runs.find(
      (run) => run.status === 'queued' || run.status === 'running',
    ),
    completed = runs.filter((run) => run.status === 'completed'),
    last = runs.at(-1);
  // Cap before mapping, so trace() and forRun() are not run for every run in a long session.
  const traceItems = runs
    .toReversed()
    .slice(0, 20)
    .map((run) => ({
      run,
      trace: sessions().traceForRun(run, security().forRun(run.id)),
    }));
  return (
    <>
      <Link href={`/projects/${id}`} className="breadcrumb-link">
        ← {project.name}
      </Link>
      <header className="project-header">
        <div className="page-heading">
          <span className="eyebrow">{project.name}</span>
          <h1>Agent session</h1>
          <p>
            {session.model.modelId} · {session.model.provider} · Saved locally
          </p>
        </div>
        <Panel title="Shared context" trigger="Context" icon="context">
          <p className="muted">
            This project context is shared with the selected model. The current
            conversation remains in this session.
          </p>
          <pre
            className="context-preview"
            aria-label="Context shared with models"
          >
            {context().render(id) || 'Nothing is shared yet.'}
          </pre>
          <Link href={`/projects/${id}`} className="subtle-button">
            <Icon name="context" />
            Manage project context
          </Link>
        </Panel>
      </header>
      {last?.error &&
        (last.status === 'failed' || last.status === 'blocked') && (
          <div role="alert" className="error-message mb-6">
            <p>
              Last run {last.status}: {last.error}
            </p>
            {last.status === 'blocked' && (
              <Link href="/security" className="text-teal-800 underline">
                Inspect the security finding
              </Link>
            )}
          </div>
        )}
      <div className="run-layout">
        <SessionChat
          key={session.id}
          projectId={id}
          sources={completed.map((run) => sessions().sources(run.id))}
          sessionId={session.id}
          turns={sessions().view(session.id)}
          activeRunId={active?.id ?? null}
          activePrompt={active?.prompt ?? null}
        />
        <aside className="run-sidebar" aria-label="Session details">
          <section className="activity-panel">
            <h2>Selected model</h2>
            <div className="model-name flex items-center gap-2">
              <Icon name="cube" />
              {session.model.modelId}
            </div>
            <p className="metadata mt-2">
              {session.model.provider === 'ollama'
                ? 'Local · Ollama'
                : session.model.provider}
            </p>
            <Link
              href={`/projects/${id}`}
              className="text-button mt-4 inline-block"
            >
              Start a session with another model →
            </Link>
          </section>
          <section className="activity-panel">
            <h2>Task activity</h2>
            {runs.length === 0 ? (
              <p className="metadata">No tasks have run in this session.</p>
            ) : (
              <ul className="activity-list">
                {runs
                  .slice(-5)
                  .reverse()
                  .map((run) => (
                    <li className="activity-item" key={run.id}>
                      <Icon
                        name={
                          run.status === 'completed'
                            ? 'check'
                            : run.status === 'failed' ||
                                run.status === 'blocked'
                              ? 'warning'
                              : run.status === 'cancelled'
                                ? 'stop'
                                : 'activity'
                        }
                        width={14}
                      />
                      <div>
                        <span className="capitalize">{run.status}</span>
                        <time dateTime={run.createdAt}>
                          {run.createdAt.slice(11, 19)} UTC
                        </time>
                      </div>
                    </li>
                  ))}
              </ul>
            )}
          </section>
          <section className="activity-panel">
            <h2>Protection</h2>
            <p className="metadata">
              Input, retrieved content, and answers pass through the enforced
              security pipeline.
            </p>
            <Link href="/security" className="text-button mt-3 inline-block">
              Security & Verification →
            </Link>
          </section>
        </aside>
      </div>
      <RunTraces items={traceItems} totalRuns={runs.length} />
    </>
  );
}
