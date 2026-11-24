'use client';
import { useActionState } from 'react';
import { startSession } from '@/app/actions';
import { Button } from '@/components/ui/button';
import { modelLabel } from '@/lib/model-label';

export function StartSession({
  projectId,
  groups,
}: {
  projectId: string;
  groups: { label: string; provider: string; models: string[] }[];
}) {
  const [state, action, pending] = useActionState(startSession, {
    error: null,
  });
  return (
    <form action={action} className="space-y-4">
      <input type="hidden" name="projectId" value={projectId} />
      <label htmlFor="model" className="block text-sm font-medium">
        Model
      </label>
      <select
        id="model"
        name="model"
        required
        className="w-full rounded-md border border-stone-300 bg-white px-3 py-3 outline-teal-700"
      >
        {groups.map((group) => (
          <optgroup key={group.provider} label={group.label}>
            {group.models.map((model) => (
              <option key={model} value={`${group.provider}/${model}`}>
                {modelLabel(model)}
              </option>
            ))}
          </optgroup>
        ))}
      </select>
      {state.error && (
        <p role="alert" className="text-sm text-red-800">
          {state.error}
        </p>
      )}
      <Button type="submit" disabled={pending}>
        {pending ? 'Starting…' : 'Start session'}
      </Button>
    </form>
  );
}
