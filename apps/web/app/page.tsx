import Link from 'next/link';
import { projects, sessions } from '@/lib/controller';
import { CreateProject } from '@/components/create-project';
import { Icon } from '@/components/icon';
export const dynamic = 'force-dynamic';
export default function Workspace() {
  const items = projects().list();
  return (
    <>
      <header className="page-heading">
        <span className="eyebrow">Your local workspace</span>
        <h1>A place for your next idea.</h1>
        <p>
          Continue a conversation, bring your context, and put your models to
          work.
        </p>
      </header>
      <div className="project-grid">
        <section aria-labelledby="projects-title">
          <div className="section-heading">
            <h2 id="projects-title">Projects</h2>
            <span className="muted">{items.length} saved locally</span>
          </div>
          {items.length === 0 ? (
            <div className="empty-state">
              <span className="empty-icon">
                <Icon name="workspace" width={28} height={28} />
              </span>
              <h3>Start with a project</h3>
              <p>
                A persistent home for conversations, models, and shared context.
              </p>
            </div>
          ) : (
            <ul className="project-list">
              {items.map((project) => {
                const count = sessions().listSessions(project.id).length;
                return (
                  <li key={project.id}>
                    <Link href={`/projects/${project.id}`}>
                      <span className="project-symbol">
                        <Icon name="cube" width={22} height={22} />
                      </span>
                      <div>
                        <h3>{project.name}</h3>
                        <p>
                          {count} {count === 1 ? 'session' : 'sessions'}
                          <span>·</span>Created {project.createdAt.slice(0, 10)}
                        </p>
                      </div>
                      <Icon name="arrow" />
                    </Link>
                  </li>
                );
              })}
            </ul>
          )}
        </section>
        <section
          id="new-project"
          className="create-project-panel"
          aria-labelledby="create-title"
        >
          <span className="eyebrow">Make room for something new</span>
          <h2 id="create-title">New project</h2>
          <CreateProject />
        </section>
      </div>
      <div className="workspace-note">
        <Icon name="key" />
        <p>
          Saved locally. Cloud models receive the context you send. Agent tools
          are disabled.
        </p>
      </div>
    </>
  );
}
