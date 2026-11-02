'use client';
import Link from 'next/link';
import { usePathname, useRouter } from 'next/navigation';
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Icon, type IconName } from './icon';
import { Panel } from './panel';

type ProjectLink = { id: string; name: string };
export function AppShell({
  projects,
  models,
  children,
}: {
  projects: ProjectLink[];
  models: ReactNode;
  children: ReactNode;
}) {
  const pathname = usePathname();
  const router = useRouter();
  const command = useRef<HTMLDialogElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const [query, setQuery] = useState('');
  const [mobileOpen, setMobileOpen] = useState(false);
  const commands: { label: string; href: string; icon: IconName }[] = [
    { label: 'Workspace', href: '/', icon: 'workspace' },
    { label: 'Security & Verification', href: '/security', icon: 'shield' },
    { label: 'Models & Providers', href: '/models', icon: 'cube' },
    ...projects.map((project) => ({
      label: project.name,
      href: `/projects/${project.id}`,
      icon: 'message' as const,
    })),
  ];
  const filtered = commands.filter((item) =>
    item.label.toLowerCase().includes(query.toLowerCase()),
  );
  const openCommand = () => {
    setQuery('');
    command.current?.showModal();
    search.current?.focus();
  };
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey)) return;
      if (event.key.toLowerCase() === 'k') {
        event.preventDefault();
        openCommand();
      }
      if (event.key === '1' || event.key === '2') {
        event.preventDefault();
        command.current?.close();
        router.push(event.key === '1' ? '/' : '/security');
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [router]);
  const navigate = () => {
    command.current?.close();
    setMobileOpen(false);
  };
  return (
    <div className="app-shell">
      <aside
        className={`sidebar ${mobileOpen ? 'is-open' : ''}`}
        aria-label="Main navigation"
      >
        <Link href="/" className="brand" onClick={navigate}>
          <span className="brand-mark">
            <Icon name="cube" width={25} height={25} />
          </span>
          <strong>AGENTGATE</strong>
          <span>Studio</span>
        </Link>
        <nav className="primary-nav">
          <Link
            href="/"
            onClick={navigate}
            aria-current={
              !pathname.startsWith('/security') && pathname !== '/models'
                ? 'page'
                : undefined
            }
          >
            <Icon name="workspace" />
            Workspace
          </Link>
          <Link
            href="/security"
            onClick={navigate}
            aria-current={pathname.startsWith('/security') ? 'page' : undefined}
          >
            <Icon name="shield" />
            Security & Verification
          </Link>
        </nav>
        <div className="sidebar-label">
          <span>Projects</span>
          <Link
            href="/#new-project"
            aria-label="Create project"
            onClick={navigate}
          >
            <Icon name="plus" width={15} height={15} />
          </Link>
        </div>
        <nav className="project-nav" aria-label="Projects">
          {projects.map((project) => (
            <Link
              key={project.id}
              href={`/projects/${project.id}`}
              onClick={navigate}
              aria-current={pathname.includes(project.id) ? 'page' : undefined}
            >
              <span className="project-dot" />
              <span>{project.name}</span>
            </Link>
          ))}
          {projects.length === 0 && (
            <p className="sidebar-empty">Create a project to begin.</p>
          )}
        </nav>
        <div className="sidebar-bottom">
          <span className="local-mark">
            <Icon name="key" width={16} height={16} />
          </span>
          <div>
            <strong>Local workspace</strong>
            <span>Stored on this computer</span>
          </div>
        </div>
      </aside>
      <div className="workspace-frame">
        <header className="titlebar">
          <button
            type="button"
            className="icon-button mobile-menu"
            aria-label="Toggle navigation"
            aria-expanded={mobileOpen}
            onClick={() => setMobileOpen(!mobileOpen)}
          >
            <Icon name="menu" />
          </button>
          <span className="titlebar-breadcrumb">
            Studio <span>/</span>{' '}
            {pathname.startsWith('/security')
              ? 'Security & Verification'
              : pathname === '/models'
                ? 'Providers'
                : 'Workspace'}
          </span>
          <div className="titlebar-actions">
            <Panel title="Models & Providers" trigger="Models" icon="cube">
              {models}
            </Panel>
            <button
              type="button"
              className="command-trigger"
              onClick={openCommand}
              aria-label="Open command palette"
            >
              <Icon name="search" />
              <kbd>⌘ K</kbd>
            </button>
            <Panel title="Settings" trigger="" icon="settings">
              <section className="panel-section">
                <h3>Local by design</h3>
                <p>
                  Projects and conversations are stored on this computer. Saved
                  provider keys use the operating system credential store. Agent
                  tools are disabled.
                </p>
              </section>
              <section className="panel-section">
                <h3>Keyboard shortcuts</h3>
                <dl className="shortcut-list">
                  <dt>Find a project or view</dt>
                  <dd>⌘ K</dd>
                  <dt>Workspace</dt>
                  <dd>⌘ 1</dd>
                  <dt>Security & Verification</dt>
                  <dd>⌘ 2</dd>
                  <dt>Send a task</dt>
                  <dd>⌘ Return</dd>
                  <dt>Close a panel</dt>
                  <dd>Escape</dd>
                </dl>
              </section>
            </Panel>
          </div>
        </header>
        <main id="main-content" className="workspace-content">
          {children}
        </main>
      </div>
      <dialog
        ref={command}
        className="command-palette"
        aria-label="Command palette"
        onClick={(event) => {
          if (event.target === event.currentTarget) command.current?.close();
        }}
      >
        <div className="command-search">
          <Icon name="search" />
          <input
            ref={search}
            aria-label="Search commands and projects"
            placeholder="Go to a project or view…"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && filtered[0]) {
                navigate();
                router.push(filtered[0].href);
              }
            }}
          />
          <button
            className="icon-button"
            type="button"
            aria-label="Close command palette"
            onClick={() => command.current?.close()}
          >
            <Icon name="close" />
          </button>
        </div>
        <nav aria-label="Command results">
          {filtered.map((item) => (
            <Link key={item.href} href={item.href} onClick={navigate}>
              <Icon name={item.icon} />
              <span>{item.label}</span>
              <Icon name="chevron" width={14} />
            </Link>
          ))}
          {filtered.length === 0 && <p>No matching projects or views.</p>}
        </nav>
        <footer>
          Return to open the first result · Tab to browse · Escape to close
        </footer>
      </dialog>
    </div>
  );
}
