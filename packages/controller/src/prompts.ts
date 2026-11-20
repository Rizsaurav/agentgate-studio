import type Database from 'better-sqlite3';
import { z } from 'zod';
import { detectSecrets } from './policy';
import { projectIdSchema, type ProjectRepository } from './projects';

/** Version 0: the built-in prompt every project uses until it activates one of its own. */
export const DEFAULT_SYSTEM_PROMPT =
  'You are a helpful assistant inside AGENTGATE Studio. Answer concisely.';
export const MAX_PROMPT_CHARS = 4000;

export const promptTextSchema = z
  .string()
  .trim()
  .min(1, 'Write a prompt first.')
  .max(
    MAX_PROMPT_CHARS,
    `Keep the prompt under ${MAX_PROMPT_CHARS} characters.`,
  );
const versionSchema = z.number().int().nonnegative();

export const evalStatusSchema = z.enum([
  'queued',
  'running',
  'passed',
  'failed',
  'error',
]);
export const promptVersionSchema = z
  .object({
    version: versionSchema,
    text: z.string(),
    createdAt: z.iso.datetime().nullable(),
    /** The required-suite run that checked this version; null when it was never evaluated. */
    evalRunId: z.uuid().nullable(),
    evalStatus: evalStatusSchema.nullable(),
    active: z.boolean(),
  })
  .strict();
export type PromptVersion = z.infer<typeof promptVersionSchema>;
export type ActivePrompt = { version: number; text: string };

/** Looks up the status of an evaluation run; supplied by the evaluation store. */
export type EvalStatusLookup = (
  runId: string,
) => z.infer<typeof evalStatusSchema> | null;

type Row = {
  version: number;
  text: string;
  createdAt: string;
  evalRunId: string | null;
};

/**
 * Per-project system prompts, kept as numbered immutable versions. Saving never changes what
 * runs use: a version becomes active only after the required evaluation suite has passed with
 * it in place. Rolling back is activating an earlier version, under the same gate.
 */
export class PromptService {
  constructor(
    private readonly db: Database.Database,
    private readonly projects: ProjectRepository,
    private readonly evalStatus: EvalStatusLookup,
  ) {}

  /** The prompt runs use now: the active version, or the built-in default (version 0). */
  active(projectIdInput: unknown): ActivePrompt {
    const projectId = projectIdSchema.parse(projectIdInput);
    const row = this.db
      .prepare(
        'SELECT v.version, v.text FROM active_prompts a JOIN prompt_versions v ON v.project_id = a.project_id AND v.version = a.version WHERE a.project_id = ?',
      )
      .get(projectId) as { version: number; text: string } | undefined;
    return row ?? { version: 0, text: DEFAULT_SYSTEM_PROMPT };
  }

  /** Every version, newest first, ending with the built-in default. */
  history(projectIdInput: unknown): PromptVersion[] {
    const projectId = projectIdSchema.parse(projectIdInput);
    const active = this.active(projectId).version;
    const rows = this.db
      .prepare(
        'SELECT version, text, created_at AS createdAt, eval_run_id AS evalRunId FROM prompt_versions WHERE project_id = ? ORDER BY version DESC',
      )
      .all(projectId) as Row[];
    return z.array(promptVersionSchema).parse([
      ...rows.map((row) => ({
        ...row,
        evalStatus: row.evalRunId ? this.evalStatus(row.evalRunId) : null,
        active: row.version === active,
      })),
      {
        version: 0,
        text: DEFAULT_SYSTEM_PROMPT,
        createdAt: null,
        evalRunId: null,
        evalStatus: null,
        active: active === 0,
      },
    ]);
  }

  /** Saves a new, inactive version. Text that looks like a credential is refused. */
  save(projectIdInput: unknown, textInput: unknown): PromptVersion {
    const projectId = projectIdSchema.parse(projectIdInput);
    if (!this.projects.find(projectId)) throw new Error('Unknown project.');
    const text = promptTextSchema.parse(textInput);
    if (detectSecrets(text).length > 0)
      throw new Error(
        'The prompt looks like it contains a credential. Prompts are stored and sent to models, so keep secrets out of them.',
      );
    const createdAt = new Date().toISOString();
    const version = this.db.transaction(() => {
      const { next } = this.db
        .prepare(
          'SELECT COALESCE(MAX(version), 0) + 1 AS next FROM prompt_versions WHERE project_id = ?',
        )
        .get(projectId) as { next: number };
      this.db
        .prepare(
          'INSERT INTO prompt_versions (project_id, version, text, created_at) VALUES (?, ?, ?, ?)',
        )
        .run(projectId, next, text, createdAt);
      return next;
    })();
    return promptVersionSchema.parse({
      version,
      text,
      createdAt,
      evalRunId: null,
      evalStatus: null,
      active: false,
    });
  }

  find(projectIdInput: unknown, versionInput: unknown): PromptVersion | null {
    const version = versionSchema.parse(versionInput);
    return (
      this.history(projectIdInput).find((entry) => entry.version === version) ??
      null
    );
  }

  /** Links the evaluation run that checks a version; a newer run replaces the older link. */
  recordEvaluation(
    projectIdInput: unknown,
    versionInput: unknown,
    evalRunId: string,
  ): void {
    const projectId = projectIdSchema.parse(projectIdInput);
    const version = versionSchema.parse(versionInput);
    const changed = this.db
      .prepare(
        'UPDATE prompt_versions SET eval_run_id = ? WHERE project_id = ? AND version = ?',
      )
      .run(z.uuid().parse(evalRunId), projectId, version).changes;
    if (changed === 0) throw new Error('Unknown prompt version.');
  }

  /**
   * Makes a version the one runs use. Fails closed: anything but a passed evaluation of that
   * exact version is refused. Version 0, the built-in default, is always allowed.
   */
  activate(projectIdInput: unknown, versionInput: unknown): void {
    const projectId = projectIdSchema.parse(projectIdInput);
    const version = versionSchema.parse(versionInput);
    if (version === 0) {
      this.db
        .prepare('DELETE FROM active_prompts WHERE project_id = ?')
        .run(projectId);
      return;
    }
    const entry = this.find(projectId, version);
    if (!entry) throw new Error('Unknown prompt version.');
    if (entry.evalStatus !== 'passed')
      throw new Error(
        `Version ${version} cannot be activated: the required evaluation suite has not passed with it.`,
      );
    this.db
      .prepare(
        'INSERT INTO active_prompts (project_id, version) VALUES (?, ?) ON CONFLICT(project_id) DO UPDATE SET version = excluded.version',
      )
      .run(projectId, version);
  }
}

export type DiffLine = { kind: 'same' | 'added' | 'removed'; text: string };

/** A line diff from `before` to `after` (longest common subsequence); prompts are short. */
export function diffLines(before: string, after: string): DiffLine[] {
  const a = before.split('\n'),
    b = after.split('\n');
  const lcs = Array.from({ length: a.length + 1 }, () =>
    new Array<number>(b.length + 1).fill(0),
  );
  for (let i = a.length - 1; i >= 0; i--)
    for (let j = b.length - 1; j >= 0; j--)
      lcs[i]![j] =
        a[i] === b[j]
          ? lcs[i + 1]![j + 1]! + 1
          : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!);
  const lines: DiffLine[] = [];
  let i = 0,
    j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      lines.push({ kind: 'same', text: a[i]! });
      i++;
      j++;
    } else if (lcs[i + 1]![j]! >= lcs[i]![j + 1]!)
      lines.push({ kind: 'removed', text: a[i++]! });
    else lines.push({ kind: 'added', text: b[j++]! });
  }
  while (i < a.length) lines.push({ kind: 'removed', text: a[i++]! });
  while (j < b.length) lines.push({ kind: 'added', text: b[j++]! });
  return lines;
}
