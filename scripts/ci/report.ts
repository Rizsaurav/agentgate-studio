import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { z } from 'zod';
import {
  ISSUE_LABELS,
  SCHEDULED_EVENTS,
  WATCHED_WORKFLOWS,
  type Job,
  type Occurrence,
  type WorkflowRun,
  badge,
  currentResults,
  historySchema,
  issueBody,
  issueSchema,
  issueTitle,
  jobSchema,
  logExcerpt,
  nextHistory,
  passingComment,
  planIssues,
  resultsPage,
  stillFailingComment,
} from './scheduled';

/**
 * F5 (#24), run by .github/workflows/scheduled-report.yml:
 *   tsx scripts/ci/report.ts issues        one issue per failing check of run $RUN_ID
 *   tsx scripts/ci/report.ts page <dir>    the results page, badge and JSON, written to <dir>
 */
const env = z
  .object({
    GITHUB_TOKEN: z.string().min(1),
    GITHUB_REPOSITORY: z.string().regex(/^[\w.-]+\/[\w.-]+$/),
    /** Set by GitHub Actions; a test points it at a fake server. */
    GITHUB_API_URL: z.string().url().default('https://api.github.com'),
    RUN_ID: z.string().regex(/^\d+$/).optional(),
    /** The published page, to carry its history forward; unset until Pages is enabled. */
    PAGES_URL: z.string().url().optional().or(z.literal('')),
  })
  .parse(process.env);
const repo = env.GITHUB_REPOSITORY;
const api = env.GITHUB_API_URL.replace(/\/$/, '');

async function github(
  path: string,
  init: { method?: string; body?: unknown } = {},
): Promise<unknown> {
  const response = await fetch(`${api}${path}`, {
    method: init.method ?? 'GET',
    headers: {
      authorization: `Bearer ${env.GITHUB_TOKEN}`,
      accept: 'application/vnd.github+json',
      'x-github-api-version': '2022-11-28',
      ...(init.body ? { 'content-type': 'application/json' } : {}),
    },
    ...(init.body ? { body: JSON.stringify(init.body) } : {}),
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok)
    throw new Error(
      `GitHub API ${init.method ?? 'GET'} ${path} answered ${response.status}.`,
    );
  return response.status === 204 ? null : response.json();
}

const runSchema = z
  .object({
    id: z.number(),
    name: z.string(),
    event: z.string(),
    head_sha: z.string(),
    head_branch: z.string().nullable(),
    html_url: z.string().url(),
    workflow_id: z.number(),
    updated_at: z.string(),
  })
  .loose();
type Run = z.infer<typeof runSchema>;

async function jobsOf(runId: number): Promise<Job[]> {
  const page = z
    .object({ jobs: z.array(jobSchema) })
    .loose()
    .parse(
      await github(`/repos/${repo}/actions/runs/${runId}/jobs?per_page=100`),
    );
  return page.jobs;
}

/** Recent completed scheduled runs of a workflow, newest first. */
async function scheduledRuns(
  workflowId: number,
  query: string,
): Promise<Run[]> {
  const page = z
    .object({ workflow_runs: z.array(runSchema) })
    .loose()
    .parse(
      await github(
        `/repos/${repo}/actions/workflows/${workflowId}/runs?per_page=20&${query}`,
      ),
    );
  return page.workflow_runs.filter((run) =>
    SCHEDULED_EVENTS.includes(run.event),
  );
}

/** The job log's end. A log that cannot be read is said so in the issue, not hidden. */
async function jobLog(job: Job): Promise<string> {
  const response = await fetch(
    `${api}/repos/${repo}/actions/jobs/${job.id}/logs`,
    {
      headers: {
        authorization: `Bearer ${env.GITHUB_TOKEN}`,
        accept: 'application/vnd.github+json',
      },
      signal: AbortSignal.timeout(30_000),
    },
  );
  if (!response.ok)
    return `(The log could not be read: GitHub answered ${response.status}. Open the job link above.)`;
  return logExcerpt(await response.text());
}

async function reportIssues(): Promise<void> {
  if (!env.RUN_ID) throw new Error('RUN_ID is required for issues.');
  const run = runSchema.parse(
    await github(`/repos/${repo}/actions/runs/${env.RUN_ID}`),
  );
  if (!SCHEDULED_EVENTS.includes(run.event)) {
    console.log(
      `Run ${run.id} was started by ${run.event}; nothing to report.`,
    );
    return;
  }
  const lastGood =
    (
      await scheduledRuns(
        run.workflow_id,
        `status=success&branch=${encodeURIComponent(run.head_branch ?? '')}`,
      )
    ).find((candidate) => candidate.id < run.id)?.head_sha ?? null;
  const open = z
    .array(issueSchema)
    .parse(
      await github(
        `/repos/${repo}/issues?state=open&per_page=100&labels=${encodeURIComponent(ISSUE_LABELS[0] ?? '')}`,
      ),
    );
  const actions = planIssues(run.name, await jobsOf(run.id), open);
  for (const action of actions) {
    if (action.kind === 'close') {
      await github(`/repos/${repo}/issues/${action.issue}/comments`, {
        method: 'POST',
        body: { body: passingComment(run.html_url, run.head_sha) },
      });
      await github(`/repos/${repo}/issues/${action.issue}`, {
        method: 'PATCH',
        body: { state: 'closed', state_reason: 'completed' },
      });
      console.log(`Closed #${action.issue}: ${action.key} passes again.`);
      continue;
    }
    const occurrence: Occurrence = {
      repository: repo,
      runUrl: run.html_url,
      job: action.job,
      sha: run.head_sha,
      lastGoodSha: lastGood,
      log: await jobLog(action.job),
    };
    if (action.kind === 'update') {
      await github(`/repos/${repo}/issues/${action.issue}/comments`, {
        method: 'POST',
        body: { body: stillFailingComment(occurrence) },
      });
      console.log(`Updated #${action.issue}: ${action.key} still fails.`);
    } else {
      const created = z
        .object({ number: z.number() })
        .loose()
        .parse(
          await github(`/repos/${repo}/issues`, {
            method: 'POST',
            body: {
              title: issueTitle(action.key),
              body: issueBody(action.key, occurrence),
              labels: ISSUE_LABELS,
            },
          }),
        );
      console.log(`Opened #${created.number}: ${action.key} fails.`);
    }
  }
  if (actions.length === 0) console.log('No issue to open, update or close.');
}

async function previousHistory() {
  if (!env.PAGES_URL) return [];
  const response = await fetch(
    new URL('history.json', `${env.PAGES_URL.replace(/\/?$/, '/')}`),
    {
      signal: AbortSignal.timeout(30_000),
    },
  );
  // Not published yet: the history starts now. Any other answer stops the job.
  if (response.status === 404) return [];
  if (!response.ok)
    throw new Error(`The published history answered ${response.status}.`);
  return historySchema.parse(await response.json());
}

async function buildPage(directory: string): Promise<void> {
  const listing = z
    .object({
      workflows: z.array(
        z.object({ id: z.number(), name: z.string() }).loose(),
      ),
    })
    .loose()
    .parse(await github(`/repos/${repo}/actions/workflows?per_page=100`));
  const runs: WorkflowRun[] = [];
  for (const name of WATCHED_WORKFLOWS) {
    const workflow = listing.workflows.find((w) => w.name === name);
    if (!workflow) continue;
    const latest = (await scheduledRuns(workflow.id, 'status=completed'))[0];
    if (!latest) continue;
    runs.push({
      workflow: name,
      url: latest.html_url,
      sha: latest.head_sha,
      finishedAt: latest.updated_at,
      jobs: await jobsOf(latest.id),
    });
  }
  const now = new Date().toISOString();
  const results = currentResults(runs);
  const history = nextHistory(await previousHistory(), results, now);
  mkdirSync(directory, { recursive: true });
  writeFileSync(
    join(directory, 'results.json'),
    JSON.stringify(results, null, 2),
  );
  writeFileSync(
    join(directory, 'history.json'),
    JSON.stringify(history, null, 2),
  );
  writeFileSync(join(directory, 'badge.json'), JSON.stringify(badge(results)));
  writeFileSync(
    join(directory, 'index.html'),
    resultsPage(repo, results, history, now),
  );
  console.log(`Wrote ${results.length} results to ${directory}.`);
}

const [command, argument] = process.argv.slice(2);
if (command === 'issues') await reportIssues();
else if (command === 'page' && argument) await buildPage(argument);
else throw new Error('Usage: report.ts issues | page <directory>');
