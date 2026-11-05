'use client';
import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { Button } from '@/components/ui/button';
import type { ProjectImportProgress } from '@agentgate/controller';

type Event =
  | ({ type: 'progress' } & ProjectImportProgress)
  | { type: 'complete'; value: { id: string; name: string } }
  | { type: 'error'; message: string };

function isEvent(value: unknown): value is Event {
  if (typeof value !== 'object' || value === null || !('type' in value))
    return false;
  if (value.type === 'error')
    return 'message' in value && typeof value.message === 'string';
  if (value.type === 'complete')
    return (
      'value' in value &&
      typeof value.value === 'object' &&
      value.value !== null &&
      'id' in value.value &&
      typeof value.value.id === 'string' &&
      'name' in value.value &&
      typeof value.value.name === 'string'
    );
  return (
    value.type === 'progress' &&
    'phase' in value &&
    typeof value.phase === 'string' &&
    'percent' in value &&
    (value.percent === null || typeof value.percent === 'number')
  );
}

function progressText(progress: ProjectImportProgress): string {
  const phase: Record<ProjectImportProgress['phase'], string> = {
    preparing: 'Preparing project files',
    receiving: 'Receiving repository data',
    resolving: 'Resolving repository objects',
    writing: 'Writing project files',
  };
  return `${phase[progress.phase]}${
    progress.percent === null ? '…' : ` · ${progress.percent}%`
  }`;
}

const SKIP_DIRECTORIES = new Set([
  '.git',
  '.next',
  'build',
  'dist',
  'node_modules',
  'target',
  'vendor',
  '.venv',
]);
const MAX_FILES = 5000;
const MAX_FILE_BYTES = 2_000_000;
const MAX_FOLDER_BYTES = 50_000_000;

export function ProjectSourceImport() {
  const router = useRouter();
  const folderInput = useRef<HTMLInputElement>(null);
  const active = useRef<AbortController | null>(null);
  const [url, setUrl] = useState('');
  const [name, setName] = useState('');
  const [fileCount, setFileCount] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [pending, setPending] = useState(false);

  useEffect(() => {
    folderInput.current?.setAttribute('webkitdirectory', '');
  }, []);

  async function submit(data: FormData, initialStatus: string) {
    setError(null);
    setStatus(initialStatus);
    setPending(true);
    const abort = new AbortController();
    active.current = abort;
    try {
      const response = await fetch('/api/projects/import', {
        method: 'POST',
        body: data,
        signal: abort.signal,
      });
      if (!response.ok) {
        const body: unknown = await response.json().catch(() => null);
        const message =
          typeof body === 'object' &&
          body !== null &&
          'error' in body &&
          typeof body.error === 'string'
            ? body.error
            : 'The project import request failed.';
        throw new Error(message);
      }
      if (!response.body)
        throw new Error('The import progress stream is unavailable.');
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      let completed = false;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          if (!line) continue;
          let value: unknown;
          try {
            value = JSON.parse(line);
          } catch {
            throw new Error('The import progress response was invalid.');
          }
          if (!isEvent(value))
            throw new Error('The import progress response was invalid.');
          if (value.type === 'progress') setStatus(progressText(value));
          if (value.type === 'error') throw new Error(value.message);
          if (value.type === 'complete') {
            completed = true;
            router.push(`/projects/${value.value.id}`);
            return;
          }
        }
      }
      if (!completed) throw new Error('The project import ended unexpectedly.');
    } catch (failure) {
      if (failure instanceof DOMException && failure.name === 'AbortError') {
        setStatus('Import canceled. Any partial project files are removed.');
      } else {
        setStatus(null);
        setError(
          failure instanceof Error
            ? failure.message
            : 'The project could not be imported.',
        );
      }
    } finally {
      if (active.current === abort) active.current = null;
      setPending(false);
    }
  }

  function importUrl(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData();
    form.set('sourceType', 'github');
    form.set('url', url.trim());
    form.set('name', name.trim());
    void submit(form, 'Starting shallow GitHub clone…');
  }

  async function importFolder(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    try {
      const selected = Array.from(folderInput.current?.files ?? []);
      if (selected.length === 0)
        throw new Error('Choose a project folder first.');
      const paths = selected.map((file) => file.webkitRelativePath);
      const folder = paths[0]?.split('/')[0];
      if (!folder || paths.some((path) => !path.startsWith(`${folder}/`)))
        throw new Error('Choose one project folder at a time.');
      const files = selected.flatMap((file, index) => {
        const path = paths[index];
        if (!path) return [];
        const relative = path.slice(folder.length + 1);
        if (relative.split('/').some((part) => SKIP_DIRECTORIES.has(part)))
          return [];
        return [{ path: relative, file }];
      });
      if (files.length === 0 || files.length > MAX_FILES)
        throw new Error(
          `Choose a folder with between 1 and ${MAX_FILES} files.`,
        );
      if (files.some(({ file }) => file.size > MAX_FILE_BYTES))
        throw new Error('Project files must be 2 MB or smaller.');
      if (
        files.reduce((sum, { file }) => sum + file.size, 0) > MAX_FOLDER_BYTES
      )
        throw new Error('The selected folder is larger than 50 MB.');
      const form = new FormData();
      form.set('sourceType', 'folder');
      form.set('name', name.trim() || folder);
      form.set('paths', JSON.stringify(files.map(({ path }) => path)));
      for (const { file } of files) form.append('files', file);
      await submit(form, 'Uploading selected project files…');
    } catch (failure) {
      setStatus(null);
      setError(
        failure instanceof Error
          ? failure.message
          : 'The selected folder could not be read.',
      );
    }
  }

  return (
    <section className="mt-8 border-t border-stone-300 pt-7">
      <h3 className="font-semibold">Open an existing project</h3>
      <p className="muted mt-2">
        Clone a GitHub repository or choose a local folder. Repository imports
        start with shallow history; no Git credentials are requested or stored.
      </p>
      <form onSubmit={importUrl} className="mt-4 space-y-3">
        <label htmlFor="project-git-url" className="block text-sm font-medium">
          GitHub repository URL
        </label>
        <input
          id="project-git-url"
          type="text"
          value={url}
          onChange={(event) => setUrl(event.currentTarget.value)}
          required
          maxLength={500}
          placeholder="https://github.com/owner/repository or git@github.com:owner/repository.git"
          autoComplete="url"
          spellCheck={false}
          className="w-full rounded-md border border-stone-300 bg-white px-3 py-2"
        />
        <Button type="submit" disabled={pending || !url.trim()}>
          {pending ? 'Importing…' : 'Clone repository'}
        </Button>
      </form>
      <form onSubmit={importFolder} className="mt-6 space-y-3">
        <label
          htmlFor="project-source-name"
          className="block text-sm font-medium"
        >
          Project name (optional)
        </label>
        <input
          id="project-source-name"
          value={name}
          onChange={(event) => setName(event.currentTarget.value)}
          maxLength={80}
          placeholder="Defaults to the repository or folder name"
          className="w-full rounded-md border border-stone-300 bg-white px-3 py-2"
        />
        <label
          htmlFor="project-source-folder"
          className="block text-sm font-medium"
        >
          Local project folder
        </label>
        <input
          ref={folderInput}
          id="project-source-folder"
          type="file"
          multiple
          onChange={(event) =>
            setFileCount(event.currentTarget.files?.length ?? 0)
          }
          className="w-full text-sm"
        />
        <p className="muted text-sm">
          {fileCount
            ? `${fileCount} file(s) selected; generated and dependency folders are skipped.`
            : 'Up to 5,000 files and 50 MB. Git metadata is not copied.'}
        </p>
        <Button type="submit" disabled={pending || fileCount === 0}>
          {pending ? 'Importing…' : 'Import local folder'}
        </Button>
      </form>
      {pending && (
        <div className="mt-4 space-y-2">
          <p role="status" aria-live="polite" className="muted">
            {status}
          </p>
          <Button
            type="button"
            variant="outline"
            onClick={() => active.current?.abort()}
          >
            Cancel import
          </Button>
        </div>
      )}
      {!pending && status && (
        <p role="status" className="muted mt-4">
          {status}
        </p>
      )}
      {error && (
        <p role="alert" className="error-message mt-4">
          {error}
        </p>
      )}
    </section>
  );
}
