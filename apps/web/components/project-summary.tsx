'use client';
import { useState } from 'react';
import type { ProjectSummary } from '@agentgate/controller';
import { Button } from '@/components/ui/button';

const FIELDS: {
  key: keyof ProjectSummary;
  label: string;
  placeholder: string;
}[] = [
  { key: 'language', label: 'Language', placeholder: 'e.g. TypeScript' },
  {
    key: 'packageManager',
    label: 'Package manager',
    placeholder: 'e.g. pnpm',
  },
  { key: 'testCommand', label: 'Test command', placeholder: 'e.g. pnpm test' },
  {
    key: 'ciProvider',
    label: 'CI provider',
    placeholder: 'e.g. GitHub Actions',
  },
];

export function ProjectSummary({
  projectId,
  initial,
}: {
  projectId: string;
  initial: ProjectSummary;
}) {
  const [summary, setSummary] = useState(initial);
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  async function save(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setPending(true);
    setStatus(null);
    setError(null);
    try {
      const response = await fetch(
        `/api/projects/${projectId}/source/summary`,
        {
          method: 'PATCH',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(summary),
        },
      );
      const result: unknown = await response.json();
      if (!response.ok)
        throw new Error(
          typeof result === 'object' &&
            result !== null &&
            'error' in result &&
            typeof result.error === 'string'
            ? result.error
            : 'The project summary could not be saved.',
        );
      setStatus('Project summary saved.');
    } catch (failure) {
      setError(
        failure instanceof Error
          ? failure.message
          : 'The project summary could not be saved.',
      );
    } finally {
      setPending(false);
    }
  }

  return (
    <form onSubmit={save} className="mt-6 space-y-3">
      <h2 className="font-semibold">Project summary</h2>
      <p className="muted text-sm">
        Detected from the project files. Review and correct it if needed.
      </p>
      <div className="grid gap-3 sm:grid-cols-2">
        {FIELDS.map(({ key, label, placeholder }) => (
          <label key={key} className="block text-sm font-medium">
            {label}
            <input
              value={summary[key] ?? ''}
              maxLength={key === 'testCommand' ? 200 : 80}
              placeholder={placeholder}
              onChange={(event) =>
                setSummary((current) => ({
                  ...current,
                  [key]: event.currentTarget.value,
                }))
              }
              className="mt-1 w-full rounded-md border border-stone-300 bg-white px-3 py-2"
            />
          </label>
        ))}
      </div>
      <Button type="submit" disabled={pending}>
        {pending ? 'Saving…' : 'Save summary'}
      </Button>
      {status && (
        <p role="status" className="muted">
          {status}
        </p>
      )}
      {error && (
        <p role="alert" className="error-message">
          {error}
        </p>
      )}
    </form>
  );
}
