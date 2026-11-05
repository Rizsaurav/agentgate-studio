import { spawn } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  lstatSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from 'node:path';
import type Database from 'better-sqlite3';
import { z } from 'zod';
import type { Project, ProjectService } from './projects';
import { projectNameSchema } from './projects';

const MAX_FILES = 5000;
const MAX_FILE_BYTES = 2_000_000;
const MAX_FOLDER_BYTES = 50_000_000;
const CLONE_TIMEOUT_MS = 5 * 60_000;

export const projectSummarySchema = z
  .object({
    language: z.string().max(80).nullable(),
    packageManager: z.string().max(80).nullable(),
    testCommand: z.string().max(200).nullable(),
    ciProvider: z.string().max(80).nullable(),
  })
  .strict();
export type ProjectSummary = z.infer<typeof projectSummarySchema>;

const summaryText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .nullable()
    .transform((value) => (value === '' ? null : value));

export const editableProjectSummarySchema = z
  .object({
    language: summaryText(80),
    packageManager: summaryText(80),
    testCommand: summaryText(200),
    ciProvider: summaryText(80),
  })
  .strict();

export const gitHubCloneUrlSchema = z
  .string()
  .trim()
  .min(1)
  .max(500)
  .transform((input, context) => {
    const scp =
      /^git@github\.com:([A-Za-z0-9][A-Za-z0-9-]{0,38})\/([A-Za-z0-9._-]{1,100}?)(?:\.git)?$/i.exec(
        input,
      );
    if (scp) return { remote: input, repository: `${scp[1]}/${scp[2]}` };

    let url: URL;
    try {
      url = new URL(input);
    } catch {
      context.addIssue({
        code: 'custom',
        message: 'Enter a GitHub repository URL or SSH remote.',
      });
      return z.NEVER;
    }
    const parts = url.pathname.replace(/\/+$/, '').split('/').filter(Boolean);
    if (
      !['https:', 'ssh:'].includes(url.protocol) ||
      url.hostname.toLowerCase() !== 'github.com' ||
      url.port !== '' ||
      url.search !== '' ||
      url.hash !== '' ||
      (url.protocol === 'https:' &&
        (url.username !== '' || url.password !== '')) ||
      (url.protocol === 'ssh:' && url.username !== 'git') ||
      parts.length !== 2
    ) {
      context.addIssue({
        code: 'custom',
        message:
          'Only HTTPS or SSH URLs for github.com repositories are supported.',
      });
      return z.NEVER;
    }
    const owner = parts[0] ?? '';
    const rawName = parts[1] ?? '';
    const name = rawName.replace(/\.git$/i, '');
    if (
      !/^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/.test(owner) ||
      !/^[A-Za-z0-9._-]{1,100}$/.test(name) ||
      name === '.' ||
      name === '..'
    ) {
      context.addIssue({
        code: 'custom',
        message: 'Enter a valid GitHub repository URL.',
      });
      return z.NEVER;
    }
    const repository = `${owner}/${name}`;
    return {
      remote:
        url.protocol === 'ssh:'
          ? `ssh://git@github.com/${repository}.git`
          : `https://github.com/${repository}.git`,
      repository,
    };
  });

export type ProjectSource = {
  projectId: string;
  sourceUrl: string | null;
  summary: ProjectSummary;
  fullHistory: boolean;
};

export interface ProjectSourceRepository {
  save(source: ProjectSource): void;
  find(projectId: string): ProjectSource | null;
  updateSummary(projectId: string, summary: ProjectSummary): void;
  setFullHistory(projectId: string): void;
  remove(projectId: string): void;
}

export class SqliteProjectSources implements ProjectSourceRepository {
  constructor(private readonly db: Database.Database) {}

  save(source: ProjectSource): void {
    this.db
      .prepare(
        `INSERT INTO project_sources (project_id, source_url, summary, full_history)
         VALUES (?, ?, ?, ?)`,
      )
      .run(
        source.projectId,
        source.sourceUrl,
        JSON.stringify(projectSummarySchema.parse(source.summary)),
        source.fullHistory ? 1 : 0,
      );
  }

  find(projectId: string): ProjectSource | null {
    const row = this.db
      .prepare(
        `SELECT project_id AS projectId, source_url AS sourceUrl, summary, full_history AS fullHistory
         FROM project_sources WHERE project_id = ?`,
      )
      .get(projectId) as
      | {
          projectId: string;
          sourceUrl: string | null;
          summary: string;
          fullHistory: number;
        }
      | undefined;
    if (!row) return null;
    const summary: unknown = JSON.parse(row.summary);
    return {
      projectId: row.projectId,
      sourceUrl: row.sourceUrl,
      summary: projectSummarySchema.parse(summary),
      fullHistory: row.fullHistory === 1,
    };
  }

  updateSummary(projectId: string, summary: ProjectSummary): void {
    const result = this.db
      .prepare('UPDATE project_sources SET summary = ? WHERE project_id = ?')
      .run(JSON.stringify(projectSummarySchema.parse(summary)), projectId);
    if (result.changes !== 1) throw new Error('Project source not found.');
  }

  setFullHistory(projectId: string): void {
    const result = this.db
      .prepare(
        'UPDATE project_sources SET full_history = 1 WHERE project_id = ?',
      )
      .run(projectId);
    if (result.changes !== 1) throw new Error('Project source not found.');
  }

  remove(projectId: string): void {
    this.db
      .prepare('DELETE FROM project_sources WHERE project_id = ?')
      .run(projectId);
  }
}

export type ProjectImportProgress = {
  phase: 'preparing' | 'receiving' | 'resolving' | 'writing';
  percent: number | null;
};
export type GitProgress = (progress: ProjectImportProgress) => void;
export type GitCommandRunner = (
  args: string[],
  options: {
    cwd?: string;
    signal: AbortSignal;
    onProgress: GitProgress;
  },
) => Promise<void>;

export class ProjectSourceError extends Error {
  constructor(
    message: string,
    readonly cancelled = false,
  ) {
    super(message);
    this.name = 'ProjectSourceError';
  }
}

function summaryFor(directory: string): ProjectSummary {
  const entries = new Set<string>();
  const ignored = new Set([
    '.git',
    '.next',
    'build',
    'dist',
    'node_modules',
    'target',
    'vendor',
    '.venv',
  ]);
  let visited = 0;
  const visit = (path: string, depth: number) => {
    if (depth > 4 || visited >= 2000) return;
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      visited += 1;
      entries.add(entry.name);
      if (entry.isDirectory() && !ignored.has(entry.name) && visited < 2000)
        visit(join(path, entry.name), depth + 1);
    }
  };
  visit(directory, 0);
  const rootEntries = new Set(readdirSync(directory));
  const hasTypeScript =
    rootEntries.has('tsconfig.json') ||
    [...entries].some((entry) => /\.(?:ts|tsx|mts|cts)$/.test(entry));
  let language: string | null = null;
  if (entries.has('package.json') || hasTypeScript)
    language = hasTypeScript ? 'TypeScript' : 'JavaScript';
  else if (
    entries.has('pyproject.toml') ||
    entries.has('requirements.txt') ||
    entries.has('setup.py')
  )
    language = 'Python';
  else if (entries.has('go.mod')) language = 'Go';
  else if (entries.has('Cargo.toml')) language = 'Rust';
  else if (entries.has('pom.xml') || entries.has('build.gradle'))
    language = 'Java';
  else if ([...entries].some((entry) => entry.endsWith('.sln')))
    language = 'C#';

  let packageManager: string | null = null;
  if (entries.has('pnpm-lock.yaml')) packageManager = 'pnpm';
  else if (entries.has('yarn.lock')) packageManager = 'Yarn';
  else if (entries.has('bun.lockb') || entries.has('bun.lock'))
    packageManager = 'Bun';
  else if (entries.has('package-lock.json')) packageManager = 'npm';
  else if (entries.has('poetry.lock')) packageManager = 'Poetry';
  else if (entries.has('uv.lock')) packageManager = 'uv';

  const packageTestCommand = entries.has('pnpm-lock.yaml')
    ? 'pnpm test'
    : entries.has('yarn.lock')
      ? 'yarn test'
      : entries.has('bun.lockb') || entries.has('bun.lock')
        ? 'bun test'
        : 'npm test';
  let testCommand: string | null = null;
  const packageJsonPath = join(directory, 'package.json');
  if (rootEntries.has('package.json') && lstatSync(packageJsonPath).isFile()) {
    try {
      const pkg: unknown = JSON.parse(readFileSync(packageJsonPath, 'utf8'));
      if (
        typeof pkg === 'object' &&
        pkg !== null &&
        'scripts' in pkg &&
        typeof pkg.scripts === 'object' &&
        pkg.scripts !== null &&
        'test' in pkg.scripts &&
        typeof pkg.scripts.test === 'string'
      )
        testCommand = packageTestCommand;
    } catch {
      // Invalid package metadata should not prevent a project from being opened.
      testCommand = null;
    }
  }
  if (
    !testCommand &&
    (entries.has('pytest.ini') || entries.has('pyproject.toml'))
  )
    testCommand = 'pytest';
  if (!testCommand && entries.has('go.mod')) testCommand = 'go test ./...';
  if (!testCommand && entries.has('Cargo.toml')) testCommand = 'cargo test';
  if (!testCommand && entries.has('pom.xml')) testCommand = 'mvn test';

  let ciProvider: string | null = null;
  const githubDirectory = join(directory, '.github');
  if (rootEntries.has('.github') && lstatSync(githubDirectory).isDirectory()) {
    const github = join(directory, '.github');
    if (readdirSync(github).includes('workflows'))
      ciProvider = 'GitHub Actions';
  }
  if (!ciProvider && entries.has('.gitlab-ci.yml')) ciProvider = 'GitLab CI';
  if (!ciProvider && entries.has('.circleci')) ciProvider = 'CircleCI';
  if (!ciProvider && entries.has('Jenkinsfile')) ciProvider = 'Jenkins';

  return { language, packageManager, testCommand, ciProvider };
}

function safeProjectPath(root: string, relativePath: string): string {
  if (
    relativePath.length === 0 ||
    relativePath.length > 500 ||
    isAbsolute(relativePath) ||
    relativePath.includes('\\') ||
    /[\p{Cc}\p{Cf}]/u.test(relativePath) ||
    relativePath
      .split('/')
      .some(
        (part) =>
          !part ||
          part === '.' ||
          part === '..' ||
          part.toLowerCase() === '.git',
      )
  )
    throw new Error('The selected folder contains an invalid path.');
  const destination = resolve(root, ...relativePath.split('/'));
  const rel = relative(root, destination);
  if (
    rel === '' ||
    rel === '..' ||
    rel.startsWith(`..${sep}`) ||
    isAbsolute(rel)
  )
    throw new Error('The selected folder contains an invalid path.');
  return destination;
}

const runGit: GitCommandRunner = (args, options) => {
  return new Promise((resolvePromise, reject) => {
    if (options.signal.aborted) {
      reject(new ProjectSourceError('Import cancelled.', true));
      return;
    }
    const child = spawn('git', args, {
      cwd: options.cwd,
      detached: process.platform !== 'win32',
      env: {
        ...process.env,
        GIT_TERMINAL_PROMPT: '0',
        GCM_INTERACTIVE: 'Never',
      },
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    let stderr = '';
    let timedOut = false;
    let settled = false;
    const terminate = () => {
      if (!child.pid) return;
      try {
        if (process.platform !== 'win32') process.kill(-child.pid, 'SIGTERM');
        else child.kill('SIGTERM');
      } catch {
        child.kill('SIGTERM');
      }
      const forceKill = setTimeout(() => {
        if (child.exitCode !== null) return;
        try {
          if (process.platform !== 'win32')
            process.kill(-child.pid!, 'SIGKILL');
          else child.kill('SIGKILL');
        } catch {
          child.kill('SIGKILL');
        }
      }, 2000);
      forceKill.unref();
    };
    const timeout = setTimeout(() => {
      timedOut = true;
      terminate();
    }, CLONE_TIMEOUT_MS);
    const onAbort = () => terminate();
    options.signal.addEventListener('abort', onAbort, { once: true });

    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (data: string) => {
      stderr = `${stderr}${data}`.slice(-20_000);
      for (const match of data.matchAll(
        /(Receiving objects|Resolving deltas|Updating files):\s+(\d+)%/g,
      )) {
        const label = match[1] ?? '';
        const phase =
          label === 'Resolving deltas'
            ? 'resolving'
            : label === 'Updating files'
              ? 'writing'
              : 'receiving';
        options.onProgress({
          phase,
          percent: Number.parseInt(match[2] ?? '', 10),
        });
      }
    });
    const cleanup = () => {
      if (settled) return false;
      settled = true;
      clearTimeout(timeout);
      options.signal.removeEventListener('abort', onAbort);
      return true;
    };
    child.once('error', (error: NodeJS.ErrnoException) => {
      if (!cleanup()) return;
      if (error.code === 'ENOENT')
        reject(
          new ProjectSourceError(
            'Git is not installed. Install Git, then try again.',
          ),
        );
      else if (error.code === 'ENOSPC')
        reject(
          new ProjectSourceError(
            'There is not enough disk space to import this project.',
          ),
        );
      else reject(new ProjectSourceError('Git could not be started.'));
    });
    child.once('close', (code) => {
      if (!cleanup()) return;
      if (options.signal.aborted) {
        reject(new ProjectSourceError('Import cancelled.', true));
        return;
      }
      if (timedOut) {
        reject(
          new ProjectSourceError(
            'The repository operation timed out. Check the connection and try again.',
          ),
        );
        return;
      }
      if (code === 0) {
        resolvePromise();
        return;
      }
      const detail = stderr.toLowerCase();
      if (/no space left on device|enospc/.test(detail))
        reject(
          new ProjectSourceError(
            'There is not enough disk space to import this project.',
          ),
        );
      else if (
        /could not resolve host|connection timed out|failed to connect|network is unreachable/.test(
          detail,
        )
      )
        reject(
          new ProjectSourceError(
            'GitHub could not be reached. Check the internet connection.',
          ),
        );
      else if (
        /authentication failed|permission denied|repository not found|could not read from remote|could not read username|terminal prompts disabled/.test(
          detail,
        )
      )
        reject(
          new ProjectSourceError(
            'The repository could not be accessed. Check its URL and your Git credentials.',
          ),
        );
      else
        reject(
          new ProjectSourceError(
            'Git could not import this repository. Check the URL and try again.',
          ),
        );
    });
  });
};

export class ProjectSourceService {
  constructor(
    private readonly projects: ProjectService,
    private readonly sources: ProjectSourceRepository,
    private readonly root: string,
    private readonly runCommand: GitCommandRunner = runGit,
  ) {}

  find(projectId: string): ProjectSource | null {
    return this.sources.find(projectId);
  }

  updateSummary(projectId: string, input: unknown): ProjectSource {
    const summary = editableProjectSummarySchema.parse(input);
    this.sources.updateSummary(projectId, summary);
    const source = this.sources.find(projectId);
    if (!source) throw new Error('Project source not found.');
    return source;
  }

  async cloneFromGitHub(
    input: { url: string; name?: string },
    options: { signal: AbortSignal; onProgress: GitProgress },
  ): Promise<Project> {
    const { remote, repository } = gitHubCloneUrlSchema.parse(input.url);
    const name = projectNameSchema.parse(
      input.name?.trim() || basename(repository),
    );
    return this.importDirectory(
      name,
      (directory) =>
        this.runCommand(
          [
            '-c',
            'protocol.file.allow=never',
            'clone',
            '--depth',
            '1',
            '--no-recurse-submodules',
            '--progress',
            '--',
            remote,
            directory,
          ],
          options,
        ),
      repository,
      options,
    );
  }

  async importFolder(
    input: {
      name: string;
      files: { path: string; bytes: Uint8Array }[];
    },
    options: { signal: AbortSignal; onProgress: GitProgress },
  ): Promise<Project> {
    const name = projectNameSchema.parse(input.name);
    if (
      input.files.length === 0 ||
      input.files.length > MAX_FILES ||
      new Set(input.files.map((file) => file.path)).size !== input.files.length
    )
      throw new Error(
        `Import between 1 and ${MAX_FILES} unique project files.`,
      );
    const total = input.files.reduce(
      (sum, file) => sum + file.bytes.byteLength,
      0,
    );
    if (total > MAX_FOLDER_BYTES)
      throw new Error('The selected folder is larger than 50 MB.');
    for (const file of input.files) {
      if (file.bytes.byteLength > MAX_FILE_BYTES)
        throw new Error(`A project file is larger than 2 MB: ${file.path}`);
      safeProjectPath(this.root, file.path);
    }
    return this.importDirectory(
      name,
      async (directory) => {
        options.onProgress({ phase: 'preparing', percent: null });
        for (const [index, file] of input.files.entries()) {
          if (options.signal.aborted)
            throw new ProjectSourceError('Import cancelled.', true);
          const destination = safeProjectPath(directory, file.path);
          mkdirSync(dirname(destination), { recursive: true, mode: 0o700 });
          writeFileSync(destination, file.bytes, { flag: 'wx', mode: 0o600 });
          if (index % 25 === 0 || index === input.files.length - 1)
            options.onProgress({
              phase: 'writing',
              percent: Math.round(((index + 1) / input.files.length) * 100),
            });
        }
      },
      null,
      options,
    );
  }

  async fetchFullHistory(
    projectId: string,
    options: { signal: AbortSignal; onProgress: GitProgress },
  ): Promise<void> {
    const source = this.sources.find(projectId);
    if (!source?.sourceUrl)
      throw new Error('This project has no GitHub repository.');
    const directory = join(this.root, projectId);
    const realRoot = realpathSync(this.root);
    const realDirectory = realpathSync(directory);
    if (!realDirectory.startsWith(`${realRoot}${sep}`))
      throw new Error('The project folder is outside managed storage.');
    await this.runCommand(['fetch', '--unshallow', '--progress', 'origin'], {
      ...options,
      cwd: realDirectory,
    });
    this.sources.setFullHistory(projectId);
  }

  private async importDirectory(
    name: string,
    populate: (directory: string) => Promise<void>,
    repository: string | null,
    options: { signal: AbortSignal; onProgress: GitProgress },
  ): Promise<Project> {
    mkdirSync(this.root, { recursive: true, mode: 0o700 });
    const realRoot = realpathSync(this.root);
    const staging = mkdtempSync(join(realRoot, '.import-'));
    const checkout = join(staging, 'checkout');
    mkdirSync(checkout, { mode: 0o700 });
    let project: Project | null = null;
    let finalPath: string | null = null;
    try {
      await populate(checkout);
      if (options.signal.aborted)
        throw new ProjectSourceError('Import cancelled.', true);
      const summary = summaryFor(checkout);
      project = this.projects.create({ name });
      finalPath = join(realRoot, project.id);
      renameSync(checkout, finalPath);
      const importedProject = repository
        ? this.projects.setRepository(project.id, repository)
        : project;
      this.sources.save({
        projectId: project.id,
        sourceUrl: repository ? `https://github.com/${repository}` : null,
        summary,
        fullHistory: false,
      });
      return importedProject;
    } catch (error) {
      if (finalPath) rmSync(finalPath, { recursive: true, force: true });
      if (project) {
        try {
          this.sources.remove(project.id);
          this.projects.remove(project.id);
        } catch (cleanupError) {
          throw new Error(
            `Import failed and project cleanup did not finish: ${
              cleanupError instanceof Error
                ? cleanupError.message
                : 'unknown cleanup error'
            }`,
            { cause: error },
          );
        }
      }
      throw error;
    } finally {
      rmSync(staging, { recursive: true, force: true });
    }
  }
}
