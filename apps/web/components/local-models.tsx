'use client';
import { useState } from 'react';
import { useModelPull } from './use-model-pull';
import { Button } from '@/components/ui/button';

type Recommended = {
  id: string;
  label: string;
  downloadGb: number;
  minRamGb: number;
  fits: boolean;
  best: boolean;
  blocker: 'memory' | 'disk' | null;
};

export function LocalModels({
  recommended,
  installed,
  ollamaReady,
  ramGb,
}: {
  recommended: Recommended[];
  installed: { name: string; sizeBytes: number }[];
  ollamaReady: boolean;
  ramGb: number;
}) {
  const { pull, error, downloading, percent, install, cancel } = useModelPull();
  const [custom, setCustom] = useState('');
  const installedNames = new Set(installed.map((model) => model.name));

  return (
    <div className="space-y-6">
      {installed.length > 0 && (
        <ul className="space-y-1 text-sm" aria-label="Installed local models">
          {installed.map((model) => (
            <li key={model.name} className="flex justify-between gap-4">
              <span className="font-mono">{model.name}</span>
              <span className="text-stone-600">
                {(model.sizeBytes / 1024 ** 3).toFixed(1)} GB
              </span>
            </li>
          ))}
        </ul>
      )}
      {pull && (
        <div role="status" className="rounded-md bg-stone-100 p-4 text-sm">
          <p className="font-medium">
            {pull.model}:{' '}
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
          {pull.status === 'failed' && (
            <p className="mt-1 text-red-800">{pull.message}</p>
          )}
        </div>
      )}
      {error && (
        <p role="alert" className="text-sm text-red-800">
          {error}
        </p>
      )}
      <div>
        <h3 className="text-sm font-medium">
          Recommended for this computer ({ramGb} GB memory)
        </h3>
        <ul className="mt-3 space-y-3">
          {recommended.map((model) => (
            <li
              key={model.id}
              className="flex flex-wrap items-center justify-between gap-3 text-sm"
            >
              <span>
                <span className="font-medium">{model.label}</span>{' '}
                <span className="font-mono text-xs text-stone-600">
                  {model.id}
                </span>
                {model.best && (
                  <span className="ml-2 rounded bg-teal-100 px-2 py-0.5 text-xs text-teal-900">
                    Best fit
                  </span>
                )}
                <span className="block text-xs text-stone-600">
                  about {model.downloadGb} GB download
                  {model.blocker === 'memory' &&
                    ` · needs about ${model.minRamGb} GB memory`}
                  {model.blocker === 'disk' && ' · not enough free disk space'}
                </span>
              </span>
              {installedNames.has(model.id) ? (
                <span className="text-xs text-teal-800">Installed</span>
              ) : (
                <Button
                  type="button"
                  variant={model.best ? 'default' : 'outline'}
                  disabled={!ollamaReady || downloading || !model.fits}
                  aria-label={`Install ${model.label}`}
                  onClick={() => void install(model.id)}
                >
                  Install
                </Button>
              )}
            </li>
          ))}
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
        <Button
          type="submit"
          variant="outline"
          disabled={!ollamaReady || downloading || !custom.trim()}
        >
          Install
        </Button>
      </form>
    </div>
  );
}
