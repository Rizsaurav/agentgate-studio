'use client';
import { useActionState, useEffect, useRef, useState } from 'react';
import type { FormEvent } from 'react';
import Link from 'next/link';
import { importProject, type ImportProjectState } from '@/app/actions';
import { Button } from '@/components/ui/button';

const initial: ImportProjectState = {
  error: null,
  notice: null,
  projectId: null,
};

export function ImportProject() {
  const [state, submit, pending] = useActionState(importProject, initial);
  const folderInput = useRef<HTMLInputElement>(null);
  const [fileCount, setFileCount] = useState(0);
  const [selectionError, setSelectionError] = useState<string | null>(null);
  useEffect(() => {
    folderInput.current?.setAttribute('webkitdirectory', '');
  }, []);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSelectionError(null);
    try {
      const selected = Array.from(folderInput.current?.files ?? []);
      if (selected.length === 0)
        throw new Error('Choose a project folder to import.');
      const paths = selected.map((file) => file.webkitRelativePath);
      const root = paths[0]?.split('/')[0];
      if (!root || paths.some((path) => !path.startsWith(`${root}/`)))
        throw new Error('Choose one project folder at a time.');
      const relative = new Map<string, File>();
      for (const [index, path] of paths.entries()) {
        const file = selected[index];
        if (!file) continue;
        const localPath = path.slice(root.length + 1);
        if (relative.has(localPath))
          throw new Error('The selected folder has duplicate file paths.');
        relative.set(localPath, file);
      }

      const manifestFile = relative.get('agentgate.project.json');
      if (!manifestFile)
        throw new Error(
          'The folder must contain agentgate.project.json at its root.',
        );
      if (manifestFile.size > 100_000)
        throw new Error('The project manifest is too large.');
      const manifest = await manifestFile.text();
      let value: unknown;
      try {
        value = JSON.parse(manifest);
      } catch {
        throw new Error('The project manifest is not valid JSON.');
      }
      if (
        typeof value !== 'object' ||
        value === null ||
        !('documents' in value) ||
        !Array.isArray(value.documents) ||
        value.documents.length === 0 ||
        value.documents.length > 50 ||
        !value.documents.every((path) => typeof path === 'string')
      )
        throw new Error('The manifest must list between 1 and 50 documents.');

      const documents = value.documents.map((path) => {
        const file = relative.get(path);
        if (!file) throw new Error(`The manifest file is missing: ${path}`);
        if (file.size === 0) throw new Error(`The document is empty: ${path}`);
        if (file.size > 200_000)
          throw new Error(`The document is too large: ${path}`);
        return { path, file };
      });
      if (new Set(documents.map(({ path }) => path)).size !== documents.length)
        throw new Error('The manifest lists duplicate document paths.');
      if (documents.reduce((sum, { file }) => sum + file.size, 0) > 10_000_000)
        throw new Error(
          'The selected project documents are too large to import.',
        );

      const formData = new FormData();
      formData.set('manifest', manifest);
      formData.set(
        'relativePaths',
        JSON.stringify(documents.map(({ path }) => path)),
      );
      for (const { file } of documents) formData.append('files', file);
      submit(formData);
    } catch (error) {
      setSelectionError(
        error instanceof Error
          ? error.message
          : 'The folder could not be read.',
      );
    }
  }

  return (
    <section className="mt-8 border-t border-stone-300 pt-7">
      <h3 className="font-semibold">Import a demo folder</h3>
      <p className="muted mt-2">
        Choose a folder with an <code>agentgate.project.json</code> manifest.
        Only the documents listed there are uploaded; each is screened before it
        can be used.
      </p>
      <form onSubmit={handleSubmit} className="mt-4 space-y-3">
        <label htmlFor="project-folder" className="block text-sm font-medium">
          Project folder
        </label>
        <input
          ref={folderInput}
          id="project-folder"
          type="file"
          multiple
          accept=".json,.md,.txt,application/json,text/plain,text/markdown"
          onChange={(event) => {
            setFileCount(event.currentTarget.files?.length ?? 0);
            setSelectionError(null);
          }}
          className="w-full text-sm"
        />
        <p className="muted text-sm">
          {fileCount > 0
            ? `${fileCount} file(s) selected.`
            : 'The manifest supports goals, decisions, references, and suggested questions.'}
        </p>
        {selectionError && (
          <p role="alert" className="error-message">
            {selectionError}
          </p>
        )}
        {state.error && (
          <p role="alert" className="error-message">
            {state.error}
          </p>
        )}
        {state.notice && (
          <p role="status" className="muted">
            {state.notice}{' '}
            {state.projectId && (
              <Link
                href={`/projects/${state.projectId}`}
                className="text-button"
              >
                Open project
              </Link>
            )}
          </p>
        )}
        {state.error && state.projectId && (
          <Link href={`/projects/${state.projectId}`} className="text-button">
            Open partially imported project
          </Link>
        )}
        <Button type="submit" disabled={pending || fileCount === 0}>
          {pending ? 'Importing and screening…' : 'Import project'}
        </Button>
      </form>
    </section>
  );
}
