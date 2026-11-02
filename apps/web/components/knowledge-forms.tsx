'use client';
import { useActionState } from 'react';
import { addContext, addReference, type FormState } from '@/app/actions';
import { Button } from '@/components/ui/button';

const initial: FormState = { error: null, notice: null };

function Feedback({ state }: { state: FormState }) {
  return (
    <>
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
    </>
  );
}

export function AddContext({ projectId }: { projectId: string }) {
  const [state, action, pending] = useActionState(addContext, initial);
  return (
    <form action={action} className="space-y-3">
      <input type="hidden" name="projectId" value={projectId} />
      <label htmlFor="context-kind" className="block text-sm font-medium">
        Add to shared context
      </label>
      <select
        id="context-kind"
        name="kind"
        className="w-full rounded-md border border-stone-300 bg-white px-3 py-3 outline-teal-700"
      >
        <option value="goal">Goal</option>
        <option value="decision">Approved decision</option>
        <option value="outcome">Verified outcome</option>
      </select>
      <label htmlFor="context-text" className="sr-only">
        Context text
      </label>
      <textarea
        id="context-text"
        name="text"
        required
        maxLength={500}
        rows={2}
        className="w-full rounded-md border border-stone-300 bg-white px-3 py-3 outline-teal-700"
      />
      <Feedback state={state} />
      <Button type="submit" disabled={pending}>
        {pending ? 'Adding…' : 'Add'}
      </Button>
    </form>
  );
}

export function AddReference({ projectId }: { projectId: string }) {
  const [state, action, pending] = useActionState(addReference, initial);
  return (
    <form action={action} className="space-y-3">
      <input type="hidden" name="projectId" value={projectId} />
      <label htmlFor="reference-files" className="block text-sm font-medium">
        Add your documents (.md or .txt, up to 200 KB each)
      </label>
      <input
        id="reference-files"
        name="files"
        type="file"
        multiple
        accept=".md,.txt,text/plain,text/markdown"
        className="w-full text-sm"
      />
      <details>
        <summary className="cursor-pointer text-sm">
          Or use a file already in the reference folder
        </summary>
        <label
          htmlFor="reference-path"
          className="mt-3 block text-sm font-medium"
        >
          File or folder in the reference folder
        </label>
        <input
          id="reference-path"
          name="path"
          maxLength={300}
          defaultValue="."
          autoComplete="off"
          className="mt-2 w-full rounded-md border border-stone-300 bg-white px-3 py-3 font-mono text-sm outline-teal-700"
        />
      </details>
      <Feedback state={state} />
      <Button type="submit" disabled={pending}>
        {pending ? 'Adding…' : 'Add reference'}
      </Button>
    </form>
  );
}
