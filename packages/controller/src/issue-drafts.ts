import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { promisify } from 'node:util';
import type Database from 'better-sqlite3';
import { z } from 'zod';
import { describeGhError } from './github-ci';
import { detectExfiltrationLink, redactSecrets } from './policy';

/**
 * D3 (#26): GitHub issues the assistant drafts from a failed CI run. A draft is only ever saved
 * here; it reaches GitHub when the user reviews it in the app and clicks to open it. The assistant
 * has no tool that posts or pushes anything.
 *
 * The draft is written by a model that has read a CI log, and a log is untrusted: it can carry
 * instructions, credentials or links built to leak data. So every draft is cleaned before it is
 * saved, and again before it is posted: credentials redacted, @mentions defused so a draft cannot
 * notify people, and a draft with a data-leaking link is refused.
 */

const KEEP_DRAFTS = 50;
const ISSUE_URL = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/issues\/\d+$/;
const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f‪-‮⁦-⁩]/g;
/** `@name` outside code, which GitHub turns into a notification. */
const MENTION =
  /(^|[^\w`/])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38})(?:\/[\w.-]+)?)/g;

/** Credentials redacted, control characters removed, and mentions wrapped in code so nobody is pinged. */
export function cleanIssueText(text: string): string {
  return redactSecrets(text.replace(CONTROL, '')).replace(
    MENTION,
    (_, before: string, name: string) => `${before}\`@${name}\``,
  );
}

const draftText = (min: number, max: number) =>
  z
    .string()
    .trim()
    .min(min)
    .max(max)
    .transform(cleanIssueText)
    .refine((text) => !detectExfiltrationLink(text), {
      message:
        'The draft contains a link that could leak data, so it was not saved.',
    });

export const issueDraftInputSchema = z
  .object({
    title: draftText(8, 120).refine((title) => !title.includes('\n'), {
      message: 'The title must be one line.',
    }),
    body: draftText(20, 4000),
  })
  .strict();
export type IssueDraftInput = z.infer<typeof issueDraftInputSchema>;

export const issueDraftSchema = z
  .object({
    id: z.string(),
    createdAt: z.string(),
    /** The failure's signature (see ci-log.ts): one open draft per failure. */
    signature: z.string(),
    runId: z.number().int().positive(),
    title: z.string(),
    body: z.string(),
    status: z.enum(['open', 'posting', 'posted', 'dismissed']),
    issueUrl: z.string().nullable(),
  })
  .strict();
export type IssueDraft = z.infer<typeof issueDraftSchema>;

/** Opens an issue and returns its URL. Injected so tests never reach GitHub. */
export type IssuePoster = (title: string, body: string) => Promise<string>;

const COLUMNS = `id, created_at AS createdAt, signature, run_id AS runId, title, body, status,
  issue_url AS issueUrl`;

export class IssueDrafts {
  constructor(
    private readonly db: Database.Database,
    private readonly now: () => Date = () => new Date(),
  ) {}

  /** Saves a draft for a failed run, replacing the open draft for the same failure if there is one. */
  draft(input: {
    signature: string;
    runId: number;
    title: unknown;
    body: unknown;
  }): IssueDraft {
    const { title, body } = issueDraftInputSchema.parse({
      title: input.title,
      body: input.body,
    });
    const runId = z.number().int().positive().parse(input.runId);
    const signature = z
      .string()
      .regex(/^[a-f0-9]{16}$/)
      .parse(input.signature);
    this.db.transaction(() => {
      const open = this.db
        .prepare(
          "SELECT id FROM issue_drafts WHERE signature = ? AND status = 'open'",
        )
        .get(signature) as { id: string } | undefined;
      if (open)
        this.db
          .prepare(
            'UPDATE issue_drafts SET title = ?, body = ?, run_id = ?, created_at = ? WHERE id = ?',
          )
          .run(title, body, runId, this.now().toISOString(), open.id);
      else
        this.db
          .prepare(
            `INSERT INTO issue_drafts (id, created_at, signature, run_id, title, body, status)
             VALUES (?, ?, ?, ?, ?, ?, 'open')`,
          )
          .run(
            randomUUID(),
            this.now().toISOString(),
            signature,
            runId,
            title,
            body,
          );
      this.db
        .prepare(
          `DELETE FROM issue_drafts WHERE status != 'posting' AND id NOT IN (
             SELECT id FROM issue_drafts ORDER BY created_at DESC, rowid DESC LIMIT ?)`,
        )
        .run(KEEP_DRAFTS);
    })();
    const saved = this.db
      .prepare(
        `SELECT ${COLUMNS} FROM issue_drafts WHERE signature = ? AND status = 'open'`,
      )
      .get(signature);
    return issueDraftSchema.parse(saved);
  }

  list(limit: number): IssueDraft[] {
    return z
      .array(issueDraftSchema)
      .parse(
        this.db
          .prepare(
            `SELECT ${COLUMNS} FROM issue_drafts ORDER BY created_at DESC, rowid DESC LIMIT ?`,
          )
          .all(limit),
      );
  }

  dismiss(id: string): void {
    const changed = this.db
      .prepare(
        "UPDATE issue_drafts SET status = 'dismissed' WHERE id = ? AND status = 'open'",
      )
      .run(id).changes;
    if (changed === 0) throw new Error('That draft is no longer open.');
  }

  /**
   * Opens the issue on GitHub with the text the user approved, which they may have edited. The
   * draft is claimed first, so a double click cannot open two issues; on failure it is reopened.
   */
  async post(
    id: string,
    approved: { title: unknown; body: unknown },
    poster: IssuePoster,
  ): Promise<string> {
    const { title, body } = issueDraftInputSchema.parse(approved);
    const draft = this.find(id);
    const claimed = this.db
      .prepare(
        "UPDATE issue_drafts SET status = 'posting', title = ?, body = ? WHERE id = ? AND status = 'open'",
      )
      .run(title, body, id).changes;
    if (!draft || claimed === 0)
      throw new Error('That draft is no longer open.');
    const footer = `\n\n---\nDrafted by the AGENTGATE Studio assistant from workflow run ${draft.runId}, reviewed and opened by a person.`;
    let url: string;
    try {
      url = (await poster(title, `${body}${footer}`)).trim();
      if (!ISSUE_URL.test(url))
        throw new Error('GitHub did not return an issue link.');
    } catch (error) {
      this.db
        .prepare(
          "UPDATE issue_drafts SET status = 'open' WHERE id = ? AND status = 'posting'",
        )
        .run(id);
      throw error;
    }
    this.db
      .prepare(
        "UPDATE issue_drafts SET status = 'posted', issue_url = ? WHERE id = ?",
      )
      .run(url, id);
    return url;
  }

  private find(id: string): IssueDraft | null {
    const row = this.db
      .prepare(`SELECT ${COLUMNS} FROM issue_drafts WHERE id = ?`)
      .get(id);
    return row === undefined ? null : issueDraftSchema.parse(row);
  }
}

/** Posts through the signed-in `gh` CLI, in the repository checked out at `cwd`. */
export function ghIssuePoster(cwd: string): IssuePoster {
  const exec = promisify(execFile);
  return async (title, body) => {
    try {
      const { stdout } = await exec(
        'gh',
        ['issue', 'create', '--title', title, '--body', body],
        {
          cwd,
          timeout: 20_000,
          maxBuffer: 1024 * 1024,
          env: {
            ...process.env,
            GH_PROMPT_DISABLED: '1',
            GH_NO_UPDATE_NOTIFIER: '1',
          },
        },
      );
      // gh prints the new issue's URL as its last line.
      return stdout.trim().split('\n').at(-1) ?? '';
    } catch (error) {
      throw new Error(describeGhError(error));
    }
  };
}
