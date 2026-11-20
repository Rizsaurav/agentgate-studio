'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { removeModel } from '@/app/actions';
import { modelLabel } from '@/lib/model-label';
import { useModelPull } from './use-model-pull';
import { Button } from '@/components/ui/button';

import type { CatalogModel } from '@agentgate/controller';

const SHOWN = 10;

export function LocalModels({
  recommended,
  installed,
  summary,
  recommendedError,
}: {
  recommended: CatalogModel[];
  installed: { name: string; sizeBytes: number }[];
  summary: string;
  recommendedError: string | null;
}) {
  const router = useRouter();
  const {
    pull,
    queued,
    error,
    downloading,
    percent,
    install,
    unqueue,
    cancel,
  } = useModelPull();
  const [custom, setCustom] = useState('');
  const [selected, setSelected] = useState<string[]>([]);
  const [removeError, setRemoveError] = useState<string | null>(null);
  // Largest models that fit first, then a few that do not, so the reason is visible.
  const shown = [...recommended]
    .sort(
      (a, b) =>
        Number(b.fits) - Number(a.fits) || b.parametersB - a.parametersB,
    )
    .slice(0, SHOWN);
  const installedNames = new Set(installed.map((model) => model.name));
  const pending = (id: string) =>
    (downloading && pull?.model === id) || queued.includes(id);

  async function installSelected() {
    for (const id of selected) await install(id);
    setSelected([]);
  }
  async function remove(name: string) {
    if (!window.confirm(`Remove ${modelLabel(name)} from this computer?`))
      return;
    setRemoveError(null);
    const result = await removeModel(name);
    if (result.error) setRemoveError(result.error);
    router.refresh();
  }

  return (
    <div className="space-y-6">
      {installed.length > 0 && (
        <div>
          <h3 className="text-sm font-medium">Installed</h3>
          <p className="metadata mt-1">
            Each one is offered in the chat under “Ollama (local)” when you
            start a conversation.
          </p>
          <ul
            className="mt-3 space-y-2 text-sm"
            aria-label="Installed local models"
          >
            {installed.map((model) => (
              <li
                key={model.name}
                className="flex flex-wrap items-center justify-between gap-3"
              >
                <span>
                  <span className="font-medium">{modelLabel(model.name)}</span>
                  <span className="block font-mono text-xs text-stone-600">
                    {model.name} · {(model.sizeBytes / 1024 ** 3).toFixed(1)} GB
                  </span>
                </span>
                <Button
                  type="button"
                  variant="outline"
                  aria-label={`Remove ${model.name}`}
                  onClick={() => void remove(model.name)}
                >
                  Remove
                </Button>
              </li>
            ))}
          </ul>
          {removeError && (
            <p role="alert" className="mt-2 text-sm text-red-800">
              {removeError}
            </p>
          )}
        </div>
      )}
      {pull && (pull.status !== 'done' || queued.length > 0) && (
        <div role="status" className="rounded-md bg-stone-100 p-4 text-sm">
          <p className="font-medium">
            {modelLabel(pull.model)}:{' '}
            {pull.status === 'downloading' ? `${percent}%` : pull.message}
          </p>
          {downloading && (
            <>
              <progress
                value={percent}
                max={100}
                aria-label={`Downloading ${pull.model}`}
                className="mt-2 w-full"
              />
              <p className="mt-1 text-xs text-stone-600">{pull.message}</p>
              <Button
                type="button"
                variant="outline"
                className="mt-3"
                onClick={() => void cancel()}
              >
                Cancel download
              </Button>
            </>
          )}
          {queued.length > 0 && (
            <p className="mt-2 text-xs text-stone-600">
              Next: {queued.map(modelLabel).join(', ')}
            </p>
          )}
        </div>
      )}
      {error && (
        <p role="alert" className="text-sm text-red-800">
          {error}
        </p>
      )}
      <div>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h3 className="text-sm font-medium">
            Recommended for this computer ({summary})
          </h3>
          <Button
            type="button"
            disabled={selected.length === 0}
            onClick={() => void installSelected()}
          >
            Install selected{selected.length ? ` (${selected.length})` : ''}
          </Button>
        </div>
        <p className="metadata mt-1">
          Sizes are already chosen to fit this computer. Pick as many as you
          like; they install one after another and each is checked before it is
          offered in the chat.
        </p>
        {recommendedError && (
          <p role="alert" className="mt-3 text-sm text-red-800">
            {recommendedError}
          </p>
        )}
        <ul className="mt-3 space-y-3" aria-label="Recommended models">
          {shown.map((model) => {
            const isInstalled = installedNames.has(model.id);
            const canPick = model.fits && !isInstalled && !pending(model.id);
            return (
              <li
                key={model.id}
                className="flex flex-wrap items-center justify-between gap-3 text-sm"
              >
                <label className="flex items-start gap-3">
                  <input
                    type="checkbox"
                    className="mt-1"
                    disabled={!canPick}
                    checked={selected.includes(model.id)}
                    aria-label={`Select ${model.label}`}
                    onChange={(event) =>
                      setSelected((current) =>
                        event.target.checked
                          ? [...current, model.id]
                          : current.filter((id) => id !== model.id),
                      )
                    }
                  />
                  <span>
                    <span className="font-medium">{model.label}</span>{' '}
                    <span className="font-mono text-xs text-stone-600">
                      {model.quantization}
                    </span>
                    {model.best && (
                      <span className="ml-2 rounded bg-teal-100 px-2 py-0.5 text-xs text-teal-900">
                        Best fit
                      </span>
                    )}
                    <span className="block text-xs text-stone-600">
                      {model.parametersB}B parameters · {model.downloadGb} GB
                      download
                      {model.blocker === 'memory' &&
                        ' · too large for this computer’s memory'}
                      {model.blocker === 'disk' &&
                        ' · not enough free disk space'}
                    </span>
                  </span>
                </label>
                {isInstalled ? (
                  <span className="text-xs text-teal-800">Installed</span>
                ) : downloading && pull?.model === model.id ? (
                  <span className="text-xs text-stone-600">{percent}%</span>
                ) : queued.includes(model.id) ? (
                  <Button
                    type="button"
                    variant="outline"
                    aria-label={`Take ${model.label} off the queue`}
                    onClick={() => void unqueue(model.id)}
                  >
                    Queued · undo
                  </Button>
                ) : (
                  <Button
                    type="button"
                    variant={model.best ? 'default' : 'outline'}
                    disabled={!model.fits}
                    aria-label={`Install ${model.label}`}
                    onClick={() => void install(model.id)}
                  >
                    Install
                  </Button>
                )}
              </li>
            );
          })}
        </ul>
      </div>
      <form
        className="flex flex-wrap items-end gap-3"
        onSubmit={(event) => {
          event.preventDefault();
          void install(custom);
        }}
      >
        <div className="grow">
          <label htmlFor="custom-model" className="block text-sm font-medium">
            Another Ollama model
          </label>
          <input
            id="custom-model"
            value={custom}
            onChange={(event) => setCustom(event.target.value)}
            placeholder="e.g. gemma2:2b"
            autoComplete="off"
            spellCheck={false}
            className="mt-1 w-full rounded-md border border-stone-300 bg-white px-3 py-3 font-mono text-sm outline-teal-700"
          />
        </div>
        <Button type="submit" variant="outline" disabled={!custom.trim()}>
          Install
        </Button>
      </form>
    </div>
  );
}
