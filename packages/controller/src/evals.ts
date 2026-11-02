import { createHash, randomUUID } from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import type Database from 'better-sqlite3';
import { z } from 'zod';

const run = promisify(execFile);
export const EVAL_TIMEOUT_MS = 10 * 60_000;
const MAX_REASON = 300;

export const evalProfileSchema = z.enum(['enforced', 'weak-demo']);
export type EvalProfile = z.infer<typeof evalProfileSchema>;
const CONFIGURATIONS: Record<EvalProfile, string> = {
  enforced: 'promptfooconfig.yaml',
  'weak-demo': 'weak.promptfooconfig.yaml',
};

export const evalRunSchema = z
  .object({
    id: z.uuid(),
    profile: evalProfileSchema,
    status: z.enum(['queued', 'running', 'passed', 'failed', 'error']),
    configHash: z.string().length(64),
    gitSha: z.string().nullable(),
    gitDirty: z.boolean(),
    total: z.number().int().nonnegative(),
    passed: z.number().int().nonnegative(),
    failed: z.number().int().nonnegative(),
    error: z.string().nullable(),
    createdAt: z.iso.datetime(),
    finishedAt: z.iso.datetime().nullable(),
  })
  .strict();
export type EvalRun = z.infer<typeof evalRunSchema>;
export const evalResultSchema = z
  .object({
    description: z.string(),
    passed: z.boolean(),
    reason: z.string().nullable(),
  })
  .strict();
export type EvalResult = z.infer<typeof evalResultSchema>;

/** The parts of Promptfoo's JSON output the application relies on. */
const promptfooOutputSchema = z.object({
  results: z.object({
    results: z.array(
      z.object({
        success: z.boolean(),
        error: z.string().nullish(),
        testCase: z.object({ description: z.string().optional() }),
        gradingResult: z
          .object({
            reason: z.string().optional(),
            componentResults: z
              .array(
                z.object({ pass: z.boolean(), reason: z.string().optional() }),
              )
              .optional(),
          })
          .nullish(),
      }),
    ),
  }),
});

const RUN_COLUMNS =
  'id, profile, status, config_hash AS configHash, git_sha AS gitSha, git_dirty AS gitDirty, total, passed, failed, error, created_at AS createdAt, finished_at AS finishedAt';
type RunRow = Omit<EvalRun, 'gitDirty'> & { gitDirty: number };
const toRun = (row: RunRow): EvalRun =>
  evalRunSchema.parse({ ...row, gitDirty: row.gitDirty === 1 });

export class SqliteEvals {
  constructor(private readonly db: Database.Database) {}

  create(
    profile: EvalProfile,
    configHash: string,
    gitSha: string | null,
    gitDirty: boolean,
  ): EvalRun {
    const created = evalRunSchema.parse({
      id: randomUUID(),
      profile,
      status: 'queued',
      configHash,
      gitSha,
      gitDirty,
      total: 0,
      passed: 0,
      failed: 0,
      error: null,
      createdAt: new Date().toISOString(),
      finishedAt: null,
    });
    this.db
      .prepare(
        'INSERT INTO eval_runs (id, profile, status, config_hash, git_sha, git_dirty, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
      )
      .run(
        created.id,
        profile,
        'queued',
        configHash,
        gitSha,
        gitDirty ? 1 : 0,
        created.createdAt,
      );
    return created;
  }

  claimNext(): EvalRun | null {
    return this.db.transaction(() => {
      const row = this.db
        .prepare(
          `SELECT ${RUN_COLUMNS} FROM eval_runs WHERE status = 'queued' ORDER BY created_at, id LIMIT 1`,
        )
        .get() as RunRow | undefined;
      if (!row) return null;
      this.db
        .prepare("UPDATE eval_runs SET status = 'running' WHERE id = ?")
        .run(row.id);
      return { ...toRun(row), status: 'running' as const };
    })();
  }

  finish(
    id: string,
    outcome:
      | { status: 'passed' | 'failed'; results: EvalResult[] }
      | { status: 'error'; error: string },
  ): void {
    this.db.transaction(() => {
      if (outcome.status === 'error') {
        this.db
          .prepare(
            "UPDATE eval_runs SET status = 'error', error = ?, finished_at = ? WHERE id = ?",
          )
          .run(
            outcome.error.slice(0, MAX_REASON),
            new Date().toISOString(),
            id,
          );
        return;
      }
      const insert = this.db.prepare(
        'INSERT INTO eval_results (run_id, idx, description, passed, reason) VALUES (?, ?, ?, ?, ?)',
      );
      outcome.results.forEach((result, idx) =>
        insert.run(
          id,
          idx,
          result.description,
          result.passed ? 1 : 0,
          result.reason,
        ),
      );
      const passed = outcome.results.filter((r) => r.passed).length;
      this.db
        .prepare(
          'UPDATE eval_runs SET status = ?, total = ?, passed = ?, failed = ?, finished_at = ? WHERE id = ?',
        )
        .run(
          outcome.status,
          outcome.results.length,
          passed,
          outcome.results.length - passed,
          new Date().toISOString(),
          id,
        );
    })();
  }

  failInterrupted(): void {
    this.db
      .prepare(
        "UPDATE eval_runs SET status = 'error', error = 'Interrupted by an application restart.', finished_at = ? WHERE status = 'running'",
      )
      .run(new Date().toISOString());
  }

  recent(limit: number): EvalRun[] {
    const rows = this.db
      .prepare(
        `SELECT ${RUN_COLUMNS} FROM eval_runs ORDER BY created_at DESC, id LIMIT ?`,
      )
      .all(limit) as RunRow[];
    return rows.map(toRun);
  }

  results(runId: string): EvalResult[] {
    const rows = this.db
      .prepare(
        'SELECT description, passed, reason FROM eval_results WHERE run_id = ? ORDER BY idx',
      )
      .all(runId) as {
      description: string;
      passed: number;
      reason: string | null;
    }[];
    return rows.map((row) =>
      evalResultSchema.parse({ ...row, passed: row.passed === 1 }),
    );
  }
}

/** What the evaluation depends on: change any of it and the hash changes. */
export async function configurationIdentity(
  repoRoot: string,
): Promise<{ configHash: string; gitSha: string | null; gitDirty: boolean }> {
  const hash = createHash('sha256');
  const files = [
    ...listFiles(join(repoRoot, 'evals')),
    join(repoRoot, 'scanner', 'requirements.txt'),
    join(repoRoot, 'package.json'),
  ].sort();
  for (const file of files) {
    hash.update(file.slice(repoRoot.length));
    hash.update(readFileSync(file));
  }
  const configHash = hash.digest('hex');
  const git = async (...args: string[]) =>
    (await run('git', args, { cwd: repoRoot, timeout: 5000 })).stdout.trim();
  try {
    return {
      configHash,
      gitSha: await git('rev-parse', 'HEAD'),
      gitDirty: (await git('status', '--porcelain')).length > 0,
    };
  } catch {
    return { configHash, gitSha: null, gitDirty: false };
  }
}

function listFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory()
      ? listFiles(join(directory, entry.name))
      : entry.name.startsWith('.')
        ? []
        : [join(directory, entry.name)],
  );
}

/** Runs the version-controlled Promptfoo suite as a bounded child process, one at a time. */
export class EvalService {
  private draining: Promise<void> | null = null;

  constructor(
    private readonly repository: SqliteEvals,
    private readonly repoRoot: string,
    private readonly timeoutMs: number = EVAL_TIMEOUT_MS,
    private readonly env: Record<string, string | undefined> = process.env,
  ) {}

  get available(): boolean {
    return existsSync(join(this.repoRoot, 'evals', 'promptfooconfig.yaml'));
  }

  start(): void {
    this.repository.failInterrupted();
    this.kick();
  }

  async enqueue(profileInput: unknown): Promise<EvalRun> {
    const profile = evalProfileSchema.parse(profileInput);
    if (!this.available)
      throw new Error(
        'The evaluation suite is not available in this installation.',
      );
    const identity = await configurationIdentity(this.repoRoot);
    const created = this.repository.create(
      profile,
      identity.configHash,
      identity.gitSha,
      identity.gitDirty,
    );
    this.kick();
    return created;
  }

  recent(limit = 20): EvalRun[] {
    return this.repository.recent(limit);
  }
  results(runId: string): EvalResult[] {
    return this.repository.results(runId);
  }
  async idle(): Promise<void> {
    while (this.draining) await this.draining;
  }

  private kick(): void {
    if (this.draining) return;
    this.draining = this.drain().finally(() => {
      this.draining = null;
    });
  }

  private async drain(): Promise<void> {
    for (
      let next = this.repository.claimNext();
      next;
      next = this.repository.claimNext()
    ) {
      try {
        this.repository.finish(next.id, await this.execute(next.profile));
      } catch (error) {
        console.error(
          'Evaluation failed:',
          error instanceof Error ? error.name : 'unknown',
        );
        this.repository.finish(next.id, {
          status: 'error',
          error:
            error instanceof Error ? error.message : 'The evaluation failed.',
        });
      }
    }
  }

  private async execute(profile: EvalProfile) {
    const directory = mkdtempSync(join(tmpdir(), 'agentgate-eval-run-'));
    const output = join(directory, 'result.json');
    try {
      const code = await this.spawnSuite(
        CONFIGURATIONS[profile],
        output,
        directory,
      );
      // Promptfoo exits 100 when assertions fail; anything else non-zero is an infrastructure error.
      if (code !== 0 && code !== 100)
        throw new Error(`The evaluation process exited with code ${code}.`);
      if (!existsSync(output))
        throw new Error('The evaluation produced no result file.');
      const parsed = promptfooOutputSchema.parse(
        JSON.parse(readFileSync(output, 'utf8')),
      );
      const results = parsed.results.results.map((item) => ({
        description: item.testCase.description ?? 'Unnamed case',
        passed: item.success,
        reason: item.success
          ? null
          : firstLine(
              item.error ??
                item.gradingResult?.componentResults?.find((c) => !c.pass)
                  ?.reason ??
                item.gradingResult?.reason ??
                'Failed',
            ),
      }));
      if (results.length === 0) throw new Error('The evaluation ran no cases.');
      return {
        status: results.every((r) => r.passed)
          ? ('passed' as const)
          : ('failed' as const),
        results,
      };
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  }

  private spawnSuite(
    configuration: string,
    output: string,
    directory: string,
  ): Promise<number | null> {
    return new Promise((resolve, reject) => {
      const child = spawn(
        process.execPath,
        [
          '--import',
          join(this.repoRoot, 'node_modules', 'tsx', 'dist', 'loader.mjs'),
          join(
            this.repoRoot,
            'node_modules',
            'promptfoo',
            'dist',
            'src',
            'entrypoint.js',
          ),
          'eval',
          '--no-cache',
          '--no-write',
          '--no-progress-bar',
          '-c',
          configuration,
          '-o',
          output,
        ],
        {
          cwd: join(this.repoRoot, 'evals'),
          detached: true,
          stdio: 'ignore',
          // Only what the suite needs: no cloud keys or other secrets are inherited.
          env: childEnvironment(this.env, join(directory, 'promptfoo')),
        },
      );
      const timer = setTimeout(() => {
        if (child.pid !== undefined) process.kill(-child.pid, 'SIGKILL');
        reject(new Error('The evaluation timed out.'));
      }, this.timeoutMs);
      child.once('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
      child.once('exit', (code) => {
        clearTimeout(timer);
        resolve(code);
      });
    });
  }
}

function firstLine(text: string): string {
  return (text.split('\n')[0] ?? text).slice(0, MAX_REASON);
}

const ghRunSchema = z.array(
  z.object({
    databaseId: z.number().int(),
    status: z.string(),
    conclusion: z.string().nullable(),
    headSha: z.string(),
    url: z.url(),
    workflowName: z.string(),
    createdAt: z.string(),
  }),
);
export type GithubRun = z.infer<typeof ghRunSchema>[number];

/** Recent GitHub Actions runs through the authenticated `gh` CLI; empty with a reason when unavailable. */
export async function listGithubRuns(
  repoRoot: string,
): Promise<{ runs: GithubRun[]; unavailable: string | null }> {
  try {
    const { stdout } = await run(
      'gh',
      [
        'run',
        'list',
        '--limit',
        '10',
        '--json',
        'databaseId,status,conclusion,headSha,url,workflowName,createdAt',
      ],
      { cwd: repoRoot, timeout: 10_000 },
    );
    return { runs: ghRunSchema.parse(JSON.parse(stdout)), unavailable: null };
  } catch {
    return {
      runs: [],
      unavailable:
        'No GitHub repository is connected, or the GitHub CLI is not signed in.',
    };
  }
}

function childEnvironment(
  source: Record<string, string | undefined>,
  promptfooConfigDir: string,
): NodeJS.ProcessEnv {
  const wanted = {
    PATH: source.PATH,
    HOME: source.HOME,
    AGENTGATE_SCANNER_URL: source.AGENTGATE_SCANNER_URL,
    PROMPTFOO_CONFIG_DIR: promptfooConfigDir,
    PROMPTFOO_DISABLE_TELEMETRY: '1',
    PROMPTFOO_DISABLE_UPDATE: '1',
  };
  // Cast: Next's types make NODE_ENV mandatory on ProcessEnv, but the child needs no such value.
  return Object.fromEntries(
    Object.entries(wanted).filter(([, value]) => value !== undefined),
  ) as NodeJS.ProcessEnv;
}
