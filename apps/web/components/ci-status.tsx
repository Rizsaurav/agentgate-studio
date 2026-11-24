'use client';
import { useActionState, useEffect, useState } from 'react';
import type {
  CiFailure,
  WorkflowRun,
  WorkflowState,
} from '@agentgate/controller';
import { connectRepository, fixWithAgent } from '@/app/actions';
import { Button } from '@/components/ui/button';

type Groups = { label: string; provider: string; models: string[] }[];
type Status =
  | { loading: true }
  | { loading: false; available: true; runs: WorkflowRun[] }
  | { loading: false; available: false; message: string };

const ACTIVE_MS = 10_000;
const IDLE_MS = 30_000;

const LABEL: Record<WorkflowState, string> = {
  passed: 'Passed',
  failed: 'Failed',
  running: 'Running',
  queued: 'Queued',
  cancelled: 'Cancelled',
  skipped: 'Skipped',
};
const PILL: Partial<Record<WorkflowState, string>> = {
  passed: 'positive',
  failed: 'failure',
};

/** "3 min ago" from an ISO time; coarse on purpose, the strip is a glance. */
function age(iso: string, now: number): string {
  const minutes = Math.max(0, Math.round((now - Date.parse(iso)) / 60_000));
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours} h ago`;
  return `${Math.round(hours / 24)} days ago`;
}

/** The GitHub repository a project shows CI for. Empty disconnects it. */
export function ConnectRepository({
  projectId,
  repository,
}: {
  projectId: string;
  repository: string | null;
}) {
  const [state, action, pending] = useActionState(connectRepository, {
    error: null,
  });
  return (
    <form action={action} className="ci-connect">
      <input type="hidden" name="projectId" value={projectId} />
      <label htmlFor="repository" className="block text-sm font-medium">
        GitHub repository
      </label>
      <div className="ci-connect-row">
        <input
          id="repository"
          name="repository"
          defaultValue={repository ?? ''}
          placeholder="owner/name or https://github.com/owner/name"
          autoComplete="off"
          spellCheck={false}
          className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 outline-teal-700"
        />
        <Button type="submit" disabled={pending}>
          {pending ? 'Saving…' : repository ? 'Save' : 'Connect'}
        </Button>
      </div>
      <p className="metadata">
        Uses your GitHub sign-in through the gh CLI. The app never asks for,
        stores or shows a token.
        {repository ? ' Leave it empty and save to disconnect.' : ''}
      </p>
      {state.error && (
        <p role="alert" className="error-message">
          {state.error}
        </p>
      )}
    </form>
  );
}

/** The newest run of each workflow, refreshed every 10 seconds while one is running and every 30 otherwise. */
export function CiStrip({
  projectId,
  repository,
  groups,
}: {
  projectId: string;
  repository: string;
  groups: Groups;
}) {
  const [status, setStatus] = useState<Status>({ loading: true });
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    let stopped = false;
    const poll = async () => {
      let next = IDLE_MS;
      if (document.visibilityState === 'visible') {
        try {
          const response = await fetch(`/api/projects/${projectId}/ci`, {
            cache: 'no-store',
          });
          const body = (await response.json()) as
            | { connected: false }
            | ({ connected: true } & (
                | { available: true; runs: WorkflowRun[] }
                | { available: false; message: string }
              ));
          if (stopped) return;
          if (body.connected) {
            setStatus({ loading: false, ...body });
            if (
              body.available &&
              body.runs.some(
                (run) => run.state === 'running' || run.state === 'queued',
              )
            )
              next = ACTIVE_MS;
          }
          setNow(Date.now());
        } catch {
          if (!stopped)
            setStatus({
              loading: false,
              available: false,
              message: 'The app could not be reached. It retries shortly.',
            });
        }
      }
      if (!stopped) timer = setTimeout(poll, next);
    };
    void poll();
    const onVisible = () => {
      if (document.visibilityState !== 'visible') return;
      clearTimeout(timer);
      void poll();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      stopped = true;
      clearTimeout(timer);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [projectId]);

  if (status.loading)
    return (
      <p role="status" className="muted">
        Checking GitHub…
      </p>
    );
  if (!status.available)
    return (
      <p role="status" className="muted">
        {status.message}
      </p>
    );
  if (status.runs.length === 0)
    return (
      <p role="status" className="muted">
        No workflow runs yet on {repository}.
      </p>
    );
  return (
    <ul
      className="ci-runs"
      aria-label={`Latest workflow runs on ${repository}`}
    >
      {status.runs.map((run) => (
        <li key={run.workflow}>
          <div className="ci-run-row">
            <strong className="ci-workflow">{run.workflow}</strong>
            <span className="metadata ci-branch">{run.branch}</span>
            <span className={`status-label ${PILL[run.state] ?? ''}`}>
              {LABEL[run.state]}
            </span>
            <a
              href={run.url}
              target="_blank"
              rel="noopener noreferrer"
              className="metadata ci-age"
            >
              {age(run.createdAt, now)}
              <span className="sr-only"> (opens the run on GitHub)</span>
            </a>
          </div>
          {run.state === 'failed' && (
            <FailureDetails
              projectId={projectId}
              runId={run.runId}
              groups={groups}
            />
          )}
        </li>
      ))}
    </ul>
  );
}

function FailureDetails({
  projectId,
  runId,
  groups,
}: {
  projectId: string;
  runId: number;
  groups: Groups;
}) {
  const [failure, setFailure] = useState<
    | { loading: true }
    | { loading: false; failure: CiFailure | null; error: string | null }
  >({ loading: true });
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (!open) return;
    let stopped = false;
    void fetch(`/api/projects/${projectId}/ci/${runId}`, { cache: 'no-store' })
      .then((response) => response.json())
      .then((body: { failure: CiFailure | null; error: string | null }) => {
        if (!stopped) setFailure({ loading: false, ...body });
      })
      .catch(() => {
        if (!stopped)
          setFailure({
            loading: false,
            failure: null,
            error: 'The run could not be read.',
          });
      });
    return () => {
      stopped = true;
    };
  }, [open, projectId, runId]);
  const [state, action, pending] = useActionState(fixWithAgent, {
    error: null,
  });
  return (
    <details
      className="answer-details ci-failure"
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary>Why it failed</summary>
      {failure.loading ? (
        <p role="status" className="muted">
          Reading the failed steps…
        </p>
      ) : failure.failure ? (
        <>
          <p>
            Failing job:{' '}
            <strong>
              {failure.failure.jobs.length > 0
                ? failure.failure.jobs.join(', ')
                : 'not reported'}
            </strong>
          </p>
          <pre
            className="context-preview"
            aria-label="Last lines of the failed steps"
          >
            {failure.failure.logTail || 'The failed steps printed nothing.'}
          </pre>
          {groups.length > 0 ? (
            <form action={action} className="ci-fix">
              <input type="hidden" name="projectId" value={projectId} />
              <input type="hidden" name="runId" value={runId} />
              <label htmlFor={`fix-model-${runId}`} className="sr-only">
                Model for the agent
              </label>
              <select
                id={`fix-model-${runId}`}
                name="model"
                required
                className="rounded-md border border-stone-300 bg-white px-3 py-2 outline-teal-700"
              >
                {groups.map((group) => (
                  <optgroup key={group.provider} label={group.label}>
                    {group.models.map((model) => (
                      <option key={model} value={`${group.provider}/${model}`}>
                        {model}
                      </option>
                    ))}
                  </optgroup>
                ))}
              </select>
              <Button type="submit" disabled={pending}>
                {pending ? 'Starting…' : 'Fix with agent'}
              </Button>
            </form>
          ) : (
            <p className="muted">Add a model to fix this with the agent.</p>
          )}
          <p className="metadata">
            Starts a session with only this log tail as the task. It is scanned
            like any task, and the agent proposes a change; it cannot change
            anything itself.
          </p>
          {state.error && (
            <p role="alert" className="error-message">
              {state.error}
            </p>
          )}
        </>
      ) : (
        <p role="status" className="muted">
          {failure.error}
        </p>
      )}
    </details>
  );
}
