import Link from 'next/link';
import { notFound } from 'next/navigation';
import { PROVIDER_INFO, projectIdSchema } from '@agentgate/controller';
import {
  agentStore,
  cloud,
  context,
  customEndpoint,
  documents,
  ollama,
  projects,
  sessions,
} from '@/lib/controller';
import { removeContext, removeReference } from '@/app/actions';
import { AddContext, AddReference } from '@/components/knowledge-forms';
import { StartSession } from '@/components/start-session';
import { Panel } from '@/components/panel';
import { ModelSetup } from '@/components/model-setup';
import { Icon } from '@/components/icon';
export const dynamic = 'force-dynamic';
export default async function ProjectPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  if (!projectIdSchema.safeParse(id).success) notFound();
  const project = projects().find(id);
  if (!project) notFound();
  const sessionList = sessions().listSessions(id);
  const installed = await ollama()
    .listInstalled()
    .then((models) => ({ models, error: false }))
    .catch(() => ({ models: [] as string[], error: true }));
  const cloudStatus = await cloud()
    .status()
    .catch(() => null);
  const custom = await customEndpoint()
    .status()
    .catch(() => ({ configured: false as const }));
  const contextItems = context().list(id),
    preview = context().render(id),
    references = documents().list(id);
  const groups = [
    ...(installed.models.length
      ? [
          {
            label: 'Ollama (local)',
            provider: 'ollama',
            models: installed.models,
          },
        ]
      : []),
    ...(cloudStatus ?? [])
      .filter((entry) => entry.configured)
      .map((entry) => ({
        label: PROVIDER_INFO[entry.provider].name,
        provider: entry.provider,
        models: entry.models,
      })),
    ...(custom.configured
      ? [{ label: custom.name, provider: 'custom', models: custom.models }]
      : []),
  ];
  return (
    <>
      <Link href="/" className="breadcrumb-link">
        ← All projects
      </Link>
      <header className="project-header">
        <div className="page-heading">
          <span className="eyebrow">Project workspace</span>
          <h1>{project.name}</h1>
          <p>
            {sessionList.length}{' '}
            {sessionList.length === 1 ? 'session' : 'sessions'} ·{' '}
            {references.length} reference documents · Tools disabled
          </p>
        </div>
        <div className="project-header-actions">
          <Panel title="Shared context" trigger="Context" icon="context">
            <p className="muted">
              Every model receives this project context with each task. Add only
              goals, decisions, and outcomes you have verified.
            </p>
            <pre
              aria-label="Context shared with models"
              className="context-preview"
            >
              {preview || 'Nothing is shared yet.'}
            </pre>
            <ul className="context-items">
              {contextItems.map((item) => (
                <li key={item.id}>
                  <span>
                    <strong className="capitalize">{item.kind}</strong>
                    <br />
                    {item.text}
                  </span>
                  <form action={removeContext}>
                    <input type="hidden" name="projectId" value={id} />
                    <input type="hidden" name="id" value={item.id} />
                    <button
                      type="submit"
                      aria-label={`Remove ${item.kind}: ${item.text}`}
                      className="text-button"
                    >
                      Remove
                    </button>
                  </form>
                </li>
              ))}
            </ul>
            <AddContext projectId={id} />
          </Panel>
          <Panel
            title="Reference documents"
            trigger="References"
            icon="document"
          >
            <p className="muted">
              Retrieval uses passages from these documents. Files are read only
              from the configured reference folder. Suspect documents are
              quarantined by the security pipeline.
            </p>
            <ul className="context-items">
              {references.map((document) => (
                <li key={document.id}>
                  <div>
                    <strong>{document.title}</strong>
                    <p className="metadata">
                      {document.path} · {document.chunkCount} passages
                    </p>
                    <span
                      className={`status-label ${document.status === 'quarantined' ? 'failure' : ''}`}
                    >
                      {document.status}
                    </span>
                  </div>
                  <form action={removeReference}>
                    <input type="hidden" name="projectId" value={id} />
                    <input type="hidden" name="id" value={document.id} />
                    <button
                      type="submit"
                      aria-label={`Remove ${document.title}`}
                      className="text-button"
                    >
                      Remove
                    </button>
                  </form>
                </li>
              ))}
            </ul>
            {documents().configured ? (
              <AddReference projectId={id} />
            ) : (
              <p className="muted">
                Set <code>AGENTGATE_DOCS_ROOT</code> to a folder of .md or .txt
                files and restart to add references.
              </p>
            )}
            <Link href="/security" className="subtle-button mt-6">
              <Icon name="shield" />
              Inspect security findings
            </Link>
          </Panel>
        </div>
      </header>
      <div className="project-session-grid">
        <section aria-labelledby="sessions-title">
          <div className="section-heading">
            <h2 id="sessions-title">Agent sessions</h2>
            <span className="muted">Persisted on this computer</span>
          </div>
          {sessionList.length === 0 ? (
            <div className="empty-state">
              <span className="empty-icon">
                <Icon name="message" width={28} height={28} />
              </span>
              <h3>Your next conversation starts here.</h3>
              <p>
                Choose an available model to start. Shared project context
                follows you between sessions.
              </p>
            </div>
          ) : (
            <div className="session-list">
              {sessionList.map((session) => (
                <Link
                  className="session-link"
                  key={session.id}
                  href={`/projects/${id}/sessions/${session.id}`}
                >
                  <Icon name="message" />
                  <div>
                    <strong>{session.model.modelId}</strong>
                    <span>
                      {session.model.provider} ·{' '}
                      {session.createdAt.slice(0, 16).replace('T', ' ')} UTC
                    </span>
                  </div>
                  <Icon name="chevron" width={16} />
                </Link>
              ))}
            </div>
          )}
        </section>
        <section className="soft-surface" aria-labelledby="new-session-title">
          <h2 id="new-session-title" className="mb-5">
            New conversation
          </h2>
          {installed.error && agentStore().usesLocalModels() && (
            <p className="muted mb-5">
              Local models are starting. They appear here within a minute.
            </p>
          )}
          {cloudStatus === null && (
            <p role="alert" className="error-message mb-5">
              Cloud credentials could not be checked. Unlock the OS credential
              store to reconnect.
            </p>
          )}
          {groups.length > 0 ? (
            <StartSession projectId={id} groups={groups} />
          ) : (
            <div className="space-y-6">
              <p className="muted">
                Pick how this project gets a model. You can add the other later.
              </p>
              <div>
                <h3 className="mb-2 font-medium">Use an API key</h3>
                <p className="muted mb-3">
                  OpenRouter, Anthropic, OpenAI, Google, Groq, DeepSeek, Mistral
                  or xAI. Nothing to install.
                </p>
                <Link href="/models" className="subtle-button">
                  <Icon name="spark" />
                  Add an API key
                </Link>
              </div>
              <div>
                <h3 className="mb-2 font-medium">
                  Run a model on this computer
                </h3>
                <ModelSetup />
              </div>
            </div>
          )}
        </section>
      </div>
      <details className="mt-10 metadata">
        <summary className="cursor-pointer">Project details</summary>
        <p className="mt-3 break-all">
          ID: {id}
          <br />
          Created {project.createdAt.replace('T', ' ').replace('Z', ' UTC')}
        </p>
      </details>
    </>
  );
}
