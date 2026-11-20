'use client';
import { useActionState } from 'react';
import type { DiffLine, PromptVersion } from '@agentgate/controller';
import { managePrompt, type FormState } from '@/app/actions';
import { Button } from '@/components/ui/button';

const initial: FormState = { error: null, notice: null };

export type PromptVersionView = PromptVersion & {
  /** Changes from the previous version; empty for the built-in default. */
  diff: DiffLine[];
};

const EVAL_LABEL: Record<NonNullable<PromptVersion['evalStatus']>, string> = {
  queued: 'Evaluation queued',
  running: 'Evaluating',
  passed: 'Evaluation passed',
  failed: 'Evaluation failed',
  error: 'Evaluation could not run',
};

/** Versioned system prompt: edit, evaluate, activate, compare and roll back (#27). */
export function SystemPrompt({
  projectId,
  versions,
  evalsAvailable,
}: {
  projectId: string;
  versions: PromptVersionView[];
  evalsAvailable: boolean;
}) {
  const [state, action, pending] = useActionState(managePrompt, initial);
  const active = versions.find((entry) => entry.active);
  return (
    <div className="space-y-5">
      <p className="muted">
        Every run in this project starts with this prompt. A saved version is
        used only after the required evaluation suite passes with it in place.
        The suite uses a scripted model, so a pass shows the protections still
        hold, not how a real model follows your wording.
      </p>
      <form action={action} className="space-y-3">
        <input type="hidden" name="projectId" value={projectId} />
        <input type="hidden" name="intent" value="save" />
        <label htmlFor="prompt-text" className="block text-sm font-medium">
          New version
        </label>
        <textarea
          id="prompt-text"
          name="text"
          required
          maxLength={4000}
          rows={5}
          defaultValue={active?.text}
          className="w-full rounded-md border border-stone-300 bg-white px-3 py-3 font-mono text-sm outline-teal-700"
        />
        <p className="metadata">
          Never put credentials in a prompt: text that looks like one is
          refused.
        </p>
        <Button type="submit" disabled={pending}>
          Save version
        </Button>
      </form>
      {state.error && (
        <p role="alert" className="text-sm text-red-800">
          {state.error}
        </p>
      )}
      {state.notice && !state.error && (
        <p role="status" className="text-sm text-teal-800">
          {state.notice}
        </p>
      )}
      <ol className="context-items" aria-label="Prompt versions">
        {versions.map((entry) => (
          <li key={entry.version}>
            <div className="min-w-0 flex-1">
              <strong>
                {entry.version === 0
                  ? 'Version 0 · built-in'
                  : `Version ${entry.version}`}
              </strong>
              {entry.active && (
                <span className="status-label positive ml-2">Active</span>
              )}
              <p className="metadata">
                {entry.createdAt
                  ? `${entry.createdAt.slice(0, 16).replace('T', ' ')} UTC · `
                  : ''}
                {entry.version === 0
                  ? 'Always allowed'
                  : entry.evalStatus
                    ? EVAL_LABEL[entry.evalStatus]
                    : 'Not evaluated'}
              </p>
              <details className="answer-details">
                <summary>
                  {entry.diff.length > 0
                    ? 'Changes from the previous version'
                    : 'Prompt text'}
                </summary>
                <pre className="context-preview whitespace-pre-wrap">
                  {entry.diff.length > 0
                    ? entry.diff.map((line, index) => (
                        <span
                          key={index}
                          className={
                            line.kind === 'added'
                              ? 'block text-teal-800'
                              : line.kind === 'removed'
                                ? 'block text-red-800 line-through'
                                : 'block'
                          }
                        >
                          {line.kind === 'added'
                            ? '+ '
                            : line.kind === 'removed'
                              ? '- '
                              : '  '}
                          {line.text}
                        </span>
                      ))
                    : entry.text}
                </pre>
              </details>
            </div>
            {!entry.active && (
              <form action={action} className="flex flex-col gap-2">
                <input type="hidden" name="projectId" value={projectId} />
                <input type="hidden" name="version" value={entry.version} />
                {entry.version !== 0 &&
                  evalsAvailable &&
                  entry.evalStatus !== 'passed' &&
                  entry.evalStatus !== 'queued' &&
                  entry.evalStatus !== 'running' && (
                    <button
                      type="submit"
                      name="intent"
                      value="evaluate"
                      className="text-button"
                      disabled={pending}
                    >
                      Run evaluation
                    </button>
                  )}
                <button
                  type="submit"
                  name="intent"
                  value="activate"
                  className="text-button"
                  disabled={
                    pending ||
                    (entry.version !== 0 && entry.evalStatus !== 'passed')
                  }
                  aria-label={`Activate version ${entry.version}`}
                >
                  {active && entry.version < active.version
                    ? 'Roll back'
                    : 'Activate'}
                </button>
              </form>
            )}
          </li>
        ))}
      </ol>
    </div>
  );
}
