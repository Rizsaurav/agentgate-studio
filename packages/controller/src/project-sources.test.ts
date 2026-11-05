import {
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
  ProjectService,
  ProjectSourceService,
  type GitCommandRunner,
  SqliteProjects,
  SqliteProjectSources,
  gitHubCloneUrlSchema,
  openDatabase,
} from './index';

const directories: string[] = [];
const connections: ReturnType<typeof openDatabase>[] = [];
afterEach(() => {
  for (const db of connections.splice(0)) db.close();
  for (const directory of directories.splice(0))
    rmSync(directory, { recursive: true, force: true });
});

function setup() {
  const directory = mkdtempSync(join(tmpdir(), 'agentgate-project-source-'));
  directories.push(directory);
  const db = openDatabase(join(directory, 'agentgate.sqlite'));
  connections.push(db);
  const projects = new ProjectService(new SqliteProjects(db));
  const sources = new SqliteProjectSources(db);
  return {
    directory,
    projects,
    sources,
    service: new ProjectSourceService(
      projects,
      sources,
      join(directory, 'projects'),
    ),
  };
}

describe('project source imports', () => {
  it.each([
    ['https://github.com/acme/widget', 'acme/widget'],
    ['https://github.com/acme/widget.git', 'acme/widget'],
    ['git@github.com:acme/widget.git', 'acme/widget'],
    ['ssh://git@github.com/acme/widget.git', 'acme/widget'],
  ])('normalizes GitHub source %s', (url, repository) => {
    expect(gitHubCloneUrlSchema.parse(url).repository).toBe(repository);
  });

  it.each([
    'https://example.com/acme/widget',
    'https://github.com.evil.example/acme/widget',
    'https://user:password@github.com/acme/widget',
    'https://github.com:8443/acme/widget',
    'https://github.com/acme/widget?token=secret',
    'file:///etc/passwd',
    'git@evil.example:acme/widget.git',
    'ssh://other@github.com/acme/widget',
    'https://github.com/acme/../../outside',
  ])('rejects unsafe Git remotes: %s', (url) => {
    expect(() => gitHubCloneUrlSchema.parse(url)).toThrow();
  });

  it('stores a local project tree and detects editable project conventions', async () => {
    const { directory, service, sources } = setup();
    const project = await service.importFolder(
      {
        name: 'Local project',
        files: [
          {
            path: 'package.json',
            bytes: Buffer.from(
              JSON.stringify({ scripts: { test: 'vitest run' } }),
            ),
          },
          { path: 'pnpm-lock.yaml', bytes: Buffer.from('lockfileVersion: 9') },
          {
            path: '.github/workflows/ci.yml',
            bytes: Buffer.from('name: CI'),
          },
          { path: 'src/index.ts', bytes: Buffer.from('export {};') },
        ],
      },
      { signal: new AbortController().signal, onProgress: () => {} },
    );
    const saved = sources.find(project.id);

    expect(saved).toEqual({
      projectId: project.id,
      sourceUrl: null,
      summary: {
        language: 'TypeScript',
        packageManager: 'pnpm',
        testCommand: 'pnpm test',
        ciProvider: 'GitHub Actions',
      },
      fullHistory: false,
    });

    expect(
      readFileSync(
        join(directory, 'projects', project.id, 'src', 'index.ts'),
        'utf8',
      ),
    ).toBe('export {};');
    expect(
      statSync(join(directory, 'projects', project.id, 'src', 'index.ts'))
        .mode & 0o777,
    ).toBe(0o600);
    service.updateSummary(project.id, {
      language: 'TypeScript',
      packageManager: 'pnpm',
      testCommand: 'pnpm test --runInBand',
      ciProvider: 'GitHub Actions',
    });
    expect(sources.find(project.id)?.summary.testCommand).toBe(
      'pnpm test --runInBand',
    );
  });

  it('shallow-clones a validated GitHub remote, persists its summary, and can fetch full history', async () => {
    const directory = mkdtempSync(
      join(tmpdir(), 'agentgate-project-source-git-'),
    );
    directories.push(directory);
    const db = openDatabase(join(directory, 'agentgate.sqlite'));
    connections.push(db);
    const projects = new ProjectService(new SqliteProjects(db));
    const sources = new SqliteProjectSources(db);
    const calls: string[][] = [];
    const fakeGit: GitCommandRunner = async (args) => {
      calls.push(args);
      if (args.includes('clone')) {
        const destination = args.at(-1);
        if (!destination)
          throw new Error('Clone destination was not provided.');
        writeFileSync(
          join(destination, 'package.json'),
          JSON.stringify({ scripts: { test: 'vitest run' } }),
        );
        writeFileSync(join(destination, 'package-lock.json'), '{}');
      }
    };
    const service = new ProjectSourceService(
      projects,
      sources,
      join(directory, 'projects'),
      fakeGit,
    );
    const project = await service.cloneFromGitHub(
      { url: 'https://github.com/acme/widget.git' },
      { signal: new AbortController().signal, onProgress: () => {} },
    );
    expect(calls[0]).toContain('--depth');
    expect(calls[0]).toContain('1');
    expect(calls[0]).toContain('https://github.com/acme/widget.git');
    expect(project.repository).toBe('acme/widget');
    expect(sources.find(project.id)?.sourceUrl).toBe(
      'https://github.com/acme/widget',
    );
    expect(sources.find(project.id)?.summary).toMatchObject({
      language: 'JavaScript',
      packageManager: 'npm',
      testCommand: 'npm test',
    });

    await service.fetchFullHistory(project.id, {
      signal: new AbortController().signal,
      onProgress: () => {},
    });
    expect(calls[1]).toEqual(['fetch', '--unshallow', '--progress', 'origin']);
    expect(sources.find(project.id)?.fullHistory).toBe(true);
  });

  it('removes partial local folder files when the import is canceled', async () => {
    const { directory, projects, service } = setup();
    const controller = new AbortController();
    await expect(
      service.importFolder(
        {
          name: 'Canceled project',
          files: [
            { path: 'one.txt', bytes: Buffer.from('one') },
            { path: 'two.txt', bytes: Buffer.from('two') },
          ],
        },
        {
          signal: controller.signal,
          onProgress: () => controller.abort(),
        },
      ),
    ).rejects.toThrow('Import cancelled.');
    expect(projects.list()).toEqual([]);
    expect(readdirSync(join(directory, 'projects'))).toEqual([]);
  });

  it.each([
    '../outside.txt',
    '/etc/passwd',
    'nested/../../outside',
    'nested\\outside',
    '.git/config',
  ])('rejects unsafe uploaded paths: %s', async (path) => {
    const { service, projects } = setup();
    await expect(
      service.importFolder(
        {
          name: 'Unsafe folder',
          files: [{ path, bytes: Buffer.from('text') }],
        },
        { signal: new AbortController().signal, onProgress: () => {} },
      ),
    ).rejects.toThrow();
    expect(projects.list()).toEqual([]);
  });
});
