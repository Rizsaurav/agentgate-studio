'use client';
import { useActionState, useCallback, useEffect, useState } from 'react';
import {
  askAssistant,
  connectAssistant,
  decideProposal,
  dismissIssueDraft,
  disconnectAssistant,
  postIssueDraft,
  setAssistantEnabled,
} from '@/app/actions';
import { Button } from '@/components/ui/button';
import { Panel } from './panel';
import type { Spending } from '@agentgate/controller';

type Finding = {
  id: string;
  severity: 'info' | 'warning' | 'critical';
  title: string;
  detail: string;
};
type Note = {
  id: string;
  createdAt: string;
  kind: 'question' | 'answer' | 'finding' | 'action' | 'proposal';
  text: string;
  status: 'open' | 'approved' | 'dismissed';
  /** What approving a proposal does; null for every other kind of note. */
  request: 'action' | 'install' | null;
};
type IssueDraft = {
  id: string;
  createdAt: string;
  runId: number;
  title: string;
  body: string;
  status: 'open' | 'posting' | 'posted' | 'dismissed';
  issueUrl: string | null;
};
type Status = {
  spending: Spending;
  nearCap: boolean;
  enabled: boolean;
  configured: boolean;
  working: boolean;
  unavailable: string | null;
  tokensLeft: number;
  dailyTokens: number;
  model: string;
  findings: Finding[];
  notes: Note[];
  drafts: IssueDraft[];
};

const POLL_MS = 15_000;
const BUSY_POLL_MS = 2000;
const KIND_LABEL: Record<Note['kind'], string> = {
  question: 'You asked',
  answer: 'Assistant',
  finding: 'Looked into',
  action: 'Did',
  proposal: 'Suggests installing',
};
const PROPOSAL_LABEL: Record<'action' | 'install', string> = {
  action: 'Waiting for your approval',
  install: 'Suggests installing',
};

/** The assistant's status, always in the title bar, with its panel one click away. */
export function AssistantEntry() {
  const [status, setStatus] = useState<Status | null>(null);
  const refresh = useCallback(async () => {
    try {
      const response = await fetch('/api/assistant', { cache: 'no-store' });
      if (response.ok) setStatus((await response.json()) as Status);
    } catch {
      // The server is restarting or offline; the next poll tries again.
    }
  }, []);
  const working = status?.working ?? false;
  useEffect(() => {
    void refresh();
    const timer = setInterval(
      () => {
        if (document.visibilityState === 'visible') void refresh();
      },
      working ? BUSY_POLL_MS : POLL_MS,
    );
    return () => clearInterval(timer);
  }, [refresh, working]);

  const problems =
    status?.findings.filter((finding) => finding.severity !== 'info') ?? [];
  const badge = !status
    ? undefined
    : problems.length > 0
      ? {
          text: `${problems.length} issue${problems.length === 1 ? '' : 's'}`,
          tone: problems.some((f) => f.severity === 'critical')
            ? ('bad' as const)
            : ('warn' as const),
        }
      : { text: 'All good', tone: 'ok' as const };
  return (
    <Panel title="Assistant" trigger="Assistant" icon="activity" badge={badge}>
      {status ? (
        <AssistantBody status={status} refresh={refresh} />
      ) : (
        <p role="status" className="muted">
          Loading…
        </p>
      )}
    </Panel>
  );
}

function AssistantBody({
  status,
  refresh,
}: {
  status: Status;
  refresh: () => Promise<void>;
}) {
  const [question, setQuestion] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [connect, connectAction, connecting] = useActionState(
    connectAssistant,
    { error: null, saved: false },
  );
  useEffect(() => {
    if (connect.saved) void refresh();
  }, [connect.saved, refresh]);

  async function run(task: Promise<{ error: string | null } | void>) {
    const result = await task;
    setError(result?.error ?? null);
    await refresh();
  }
  const used = status.dailyTokens - status.tokensLeft;
  return (
    <div className="space-y-6">
      <section className="panel-section">
        <h3>Right now</h3>
        {status.findings.length === 0 ? (
          <p className="muted">
            Local models, the security scanner and the latest evaluation look
            healthy.
          </p>
        ) : (
          <ul className="context-items">
            {status.findings.map((finding) => (
              <li key={finding.id}>
                <div>
                  <strong>{finding.title}</strong>
                  <p className="metadata">{finding.detail}</p>
                  <span
                    className={`status-label ${finding.severity === 'critical' ? 'failure' : ''}`}
                  >
                    {finding.severity}
                  </span>
                </div>
              </li>
            ))}
          </ul>
        )}
        <p className="metadata mt-3">
          The watchdog checks every 30 seconds and restarts Ollama or the
          scanner for you if they stop. It does not install anything without
          your approval.
        </p>
      </section>

      {!status.configured ? (
        <section className="panel-section">
          <h3>Turn on the assistant</h3>
          <p className="muted">
            The assistant uses {status.model} through OpenRouter to explain
            problems and fix them. It only sees system state: service status,
            evaluation case names and counts of blocked items. It never sees
            your documents, conversations or other keys.
          </p>
          <form action={connectAction} className="mt-3 space-y-3">
            <label
              htmlFor="assistant-key"
              className="block text-sm font-medium"
            >
              OpenRouter API key
            </label>
            <input
              id="assistant-key"
              name="apiKey"
              type="password"
              autoComplete="off"
              spellCheck={false}
              required
              className="w-full rounded-md border border-stone-300 bg-white px-3 py-3 font-mono text-sm outline-teal-700"
            />
            {connect.error && (
              <p role="alert" className="error-message">
                {connect.error}
              </p>
            )}
            <Button type="submit" disabled={connecting}>
              {connecting ? 'Checking…' : 'Test and save key'}
            </Button>
          </form>
        </section>
      ) : (
        <>
          <section className="panel-section">
            <h3>Ask</h3>
            <form
              className="space-y-3"
              onSubmit={(event) => {
                event.preventDefault();
                const text = question;
                setQuestion('');
                void run(askAssistant(text));
              }}
            >
              <label htmlFor="assistant-question" className="sr-only">
                Question for the assistant
              </label>
              <textarea
                id="assistant-question"
                value={question}
                onChange={(event) => setQuestion(event.target.value)}
                maxLength={500}
                rows={2}
                placeholder="Why did the evaluation fail? Is the scanner running?"
                className="w-full rounded-md border border-stone-300 bg-white px-3 py-3 text-sm outline-teal-700"
              />
              {(error ?? status.unavailable) && (
                <p role="alert" className="error-message">
                  {error ?? status.unavailable}
                </p>
              )}
              <Button
                type="submit"
                disabled={
                  !question.trim() ||
                  status.working ||
                  status.unavailable !== null
                }
              >
                {status.working ? 'Working…' : 'Ask'}
              </Button>
            </form>
          </section>

          {status.drafts.length > 0 && (
            <section className="panel-section">
              <h3>Issue drafts</h3>
              <p className="muted">
                Drafted from a failed CI run. Nothing is posted until you review
                the text and open it. The log it was written from is untrusted,
                so check what it says.
              </p>
              <ul className="context-items" aria-label="Issue drafts">
                {status.drafts.map((draft) => (
                  <li key={draft.id}>
                    <DraftReview draft={draft} run={run} />
                  </li>
                ))}
              </ul>
            </section>
          )}

          <section className="panel-section">
            <h3>Activity</h3>
            {status.notes.length === 0 ? (
              <p className="muted">Nothing yet.</p>
            ) : (
              <ul className="context-items" aria-label="Assistant activity">
                {status.notes.map((note) => (
                  <li key={note.id}>
                    <div>
                      <span className="metadata">
                        {note.request
                          ? PROPOSAL_LABEL[note.request]
                          : KIND_LABEL[note.kind]}{' '}
                        · {note.createdAt.slice(11, 16)} UTC
                      </span>
                      <p>{note.text}</p>
                      {note.kind === 'proposal' && note.status === 'open' && (
                        <div className="mt-2 flex gap-2">
                          <Button
                            type="button"
                            onClick={() =>
                              void run(decideProposal(note.id, true))
                            }
                          >
                            {note.request === 'action'
                              ? 'Approve'
                              : 'Install it'}
                          </Button>
                          <Button
                            type="button"
                            variant="outline"
                            onClick={() =>
                              void run(decideProposal(note.id, false))
                            }
                          >
                            Dismiss
                          </Button>
                        </div>
                      )}
                      {note.kind === 'proposal' && note.status !== 'open' && (
                        <span className="status-label">{note.status}</span>
                      )}
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </section>

          <section className="panel-section">
            <h3>Limits and spending</h3>
            <p className="muted">
              {used.toLocaleString()} of {status.dailyTokens.toLocaleString()}{' '}
              tokens used today. It stops at the limit, looks into each problem
              once every 30 minutes, and uses no model for routine fixes.
            </p>
            <SpendingSummary
              spending={status.spending}
              nearCap={status.nearCap}
            />
            <div className="mt-3 flex flex-wrap gap-2">
              <Button
                type="button"
                variant="outline"
                onClick={() => void run(setAssistantEnabled(!status.enabled))}
              >
                {status.enabled ? 'Turn off' : 'Turn on'}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={() => void run(disconnectAssistant())}
              >
                Remove key
              </Button>
            </div>
          </section>
        </>
      )}
    </div>
  );
}

/** One draft: editable until opened; once opened, a link to the issue. */
function DraftReview({
  draft,
  run,
}: {
  draft: IssueDraft;
  run: (task: Promise<{ error: string | null } | void>) => Promise<void>;
}) {
  const [title, setTitle] = useState(draft.title);
  const [body, setBody] = useState(draft.body);
  const [busy, setBusy] = useState(false);
  if (draft.status === 'posted' && draft.issueUrl)
    return (
      <div>
        <span className="metadata">Opened on GitHub</span>
        <p>
          <a href={draft.issueUrl} target="_blank" rel="noreferrer">
            {draft.title}
          </a>
        </p>
      </div>
    );
  const titleId = `draft-title-${draft.id}`;
  const bodyId = `draft-body-${draft.id}`;
  return (
    <div className="min-w-0 flex-1 space-y-2">
      <span className="metadata">
        Workflow run {draft.runId} · {draft.createdAt.slice(11, 16)} UTC
      </span>
      <label htmlFor={titleId} className="block text-sm font-medium">
        Title
      </label>
      <input
        id={titleId}
        value={title}
        maxLength={120}
        onChange={(event) => setTitle(event.target.value)}
        className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-sm outline-teal-700"
      />
      <label htmlFor={bodyId} className="block text-sm font-medium">
        Body
      </label>
      <textarea
        id={bodyId}
        value={body}
        maxLength={4000}
        rows={6}
        onChange={(event) => setBody(event.target.value)}
        className="w-full rounded-md border border-stone-300 bg-white px-3 py-2 font-mono text-xs outline-teal-700"
      />
      <div className="flex gap-2">
        <Button
          type="button"
          disabled={busy || draft.status !== 'open'}
          onClick={async () => {
            setBusy(true);
            await run(postIssueDraft(draft.id, title, body));
            setBusy(false);
          }}
        >
          {busy || draft.status === 'posting'
            ? 'Opening…'
            : 'Open issue on GitHub'}
        </Button>
        <Button
          type="button"
          variant="outline"
          disabled={busy || draft.status !== 'open'}
          onClick={() => void run(dismissIssueDraft(draft.id))}
        >
          Discard
        </Button>
      </div>
    </div>
  );
}

const usd = (value: number) =>
  value === 0 ? '$0' : value < 0.01 ? '<$0.01' : `$${value.toFixed(2)}`;

/** Tokens and estimated cost: today, the last seven days, and a bar per day (#20). */
function SpendingSummary({
  spending,
  nearCap,
}: {
  spending: Spending;
  nearCap: boolean;
}) {
  const peak = Math.max(1, ...spending.days.map((entry) => entry.tokens));
  return (
    <div className="mt-3 space-y-3">
      {nearCap && (
        <p role="alert" className="warning-text">
          Over 80 percent of today&apos;s token limit is used. The assistant
          stops at the limit until tomorrow.
        </p>
      )}
      <dl className="grid grid-cols-2 gap-2 text-sm">
        <div>
          <dt className="metadata">Today</dt>
          <dd>
            {spending.today.tokens.toLocaleString()} tokens ·{' '}
            {usd(spending.today.costUsd)}
          </dd>
        </div>
        <div>
          <dt className="metadata">Last 7 days</dt>
          <dd>
            {spending.week.tokens.toLocaleString()} tokens ·{' '}
            {usd(spending.week.costUsd)}
          </dd>
        </div>
      </dl>
      <ol className="flex h-16 items-end gap-1" aria-label="Tokens per day">
        {spending.days.map((entry) => (
          <li
            key={entry.day}
            className="flex-1 rounded-sm bg-teal-700"
            style={{ height: `${Math.max(2, (entry.tokens / peak) * 100)}%` }}
            title={`${entry.day}: ${entry.tokens.toLocaleString()} tokens, ${usd(entry.costUsd)}`}
          >
            <span className="sr-only">
              {entry.day}: {entry.tokens.toLocaleString()} tokens,{' '}
              {usd(entry.costUsd)}
            </span>
          </li>
        ))}
      </ol>
      <p className="metadata">
        Costs are estimates from the provider&apos;s published prices.
      </p>
    </div>
  );
}
