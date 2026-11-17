'use client';
import { useActionState, useId, useState } from 'react';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import {
  searchModels,
  suggestModels,
  type ModelChoice,
  type ModelGroup,
} from '@agentgate/controller/model-lists';
import { startSession } from '@/app/actions';
import { Button } from '@/components/ui/button';
import { modelLabel } from '@/lib/model-label';

const SEARCH_LIMIT = 50;

/**
 * Picks the model for a new conversation (#48): up to four suggestions (recently used here, then
 * each provider's first model), and a search over every model of every connected provider instead
 * of one long dropdown. The choice is kept in the URL, so a refresh does not lose it.
 */
export function StartSession({
  projectId,
  groups,
  recent,
}: {
  projectId: string;
  groups: ModelGroup[];
  /** `provider/model` values used in this project, most recent first. */
  recent: string[];
}) {
  const [state, action, pending] = useActionState(startSession, {
    error: null,
  });
  const router = useRouter();
  const pathname = usePathname();
  const params = useSearchParams();
  const suggested = suggestModels(groups, recent);
  const all = new Set(
    groups.flatMap((g) => g.models.map((m) => `${g.provider}/${m}`)),
  );
  const fromUrl = params.get('model');
  const [selected, setSelected] = useState(
    fromUrl && all.has(fromUrl) ? fromUrl : (suggested[0]?.value ?? ''),
  );
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const results = searchModels(groups, query, SEARCH_LIMIT);
  const ids = useId();

  function choose(value: string) {
    setSelected(value);
    const next = new URLSearchParams(params.toString());
    next.set('model', value);
    router.replace(`${pathname}?${next.toString()}`, { scroll: false });
  }

  function option(choice: ModelChoice, name: string, showGroup = true) {
    return (
      <li key={`${name}-${choice.value}`}>
        <label className="flex items-baseline gap-2 text-sm">
          <input
            type="radio"
            name={name}
            value={choice.value}
            checked={selected === choice.value}
            onChange={() => choose(choice.value)}
          />
          <span>{modelLabel(choice.model)}</span>
          {showGroup && <span className="muted">{choice.group}</span>}
        </label>
      </li>
    );
  }

  // Results come in provider order, so grouping keeps that order.
  const byGroup = new Map<string, ModelChoice[]>();
  for (const choice of results)
    byGroup.set(choice.group, [...(byGroup.get(choice.group) ?? []), choice]);
  return (
    <form action={action} className="space-y-4">
      <input type="hidden" name="projectId" value={projectId} />
      <input type="hidden" name="model" value={selected} />
      <fieldset>
        <legend className="block text-sm font-medium">Model</legend>
        <ul className="mt-2 space-y-2" aria-label="Suggested models">
          {suggested.map((choice) => option(choice, `${ids}-suggested`))}
        </ul>
        <button
          type="button"
          className="text-button mt-3"
          aria-expanded={open}
          aria-controls={`${ids}-all`}
          onClick={() => setOpen((value) => !value)}
        >
          {open ? 'Hide all models' : `All models (${all.size})`}
        </button>
        <div id={`${ids}-all`} hidden={!open} className="mt-3 space-y-3">
          <label
            htmlFor={`${ids}-search`}
            className="block text-sm font-medium"
          >
            Search all models
          </label>
          <input
            id={`${ids}-search`}
            type="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Part of a name, e.g. v4.1 flash"
            autoComplete="off"
            spellCheck={false}
            className="w-full rounded-md border border-stone-300 bg-white px-3 py-3 font-mono text-sm outline-teal-700"
          />
          {query.trim() === '' ? (
            <p className="text-sm muted">Type part of a model name.</p>
          ) : results.length === 0 ? (
            <p className="text-sm muted" role="status">
              No model matches “{query}”.
            </p>
          ) : (
            <div role="status" aria-live="polite">
              {[...byGroup].map(([group, choices]) => (
                <div key={group} className="mt-2">
                  <p className="text-xs font-semibold uppercase tracking-widest muted">
                    {group}
                  </p>
                  <ul className="mt-1 space-y-1">
                    {choices.map((choice) =>
                      option(choice, `${ids}-search-results`, false),
                    )}
                  </ul>
                </div>
              ))}
              {results.length === SEARCH_LIMIT && (
                <p className="mt-2 text-sm muted">
                  Showing the first {SEARCH_LIMIT}. Type more of the name to
                  narrow it.
                </p>
              )}
            </div>
          )}
        </div>
      </fieldset>
      {selected && (
        <p className="text-sm">
          Selected: <span className="font-mono">{selected}</span>
        </p>
      )}
      {state.error && (
        <p role="alert" className="text-sm text-red-800">
          {state.error}
        </p>
      )}
      <Button type="submit" disabled={pending || !selected}>
        {pending ? 'Starting…' : 'Start session'}
      </Button>
    </form>
  );
}
