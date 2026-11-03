'use client';
import { useActionState } from 'react';
import { connectCustomEndpoint } from '@/app/actions';
import { Button } from '@/components/ui/button';

const field =
  'w-full rounded-md border border-stone-300 bg-white px-3 py-3 outline-teal-700';

/** Any OpenAI-compatible server: LM Studio, vLLM, llama.cpp, LiteLLM or a company gateway. */
export function CustomEndpointForm({
  current,
}: {
  current: { name: string; baseUrl: string; models: string[] } | null;
}) {
  const [state, action, pending] = useActionState(connectCustomEndpoint, {
    error: null,
    saved: false,
    values: null,
  });
  const values = state.values ?? {
    name: current?.name ?? '',
    baseUrl: current?.baseUrl ?? '',
    models: current?.models.join(', ') ?? '',
  };
  return (
    // Keyed by the last values so React re-applies them after it resets the form.
    <form key={JSON.stringify(values)} action={action} className="space-y-3">
      <label htmlFor="custom-name" className="block text-sm font-medium">
        Name
      </label>
      <input
        id="custom-name"
        name="name"
        required
        maxLength={40}
        defaultValue={values.name}
        placeholder="Company gateway"
        className={field}
      />
      <label htmlFor="custom-url" className="block text-sm font-medium">
        Base URL
      </label>
      <input
        id="custom-url"
        name="baseUrl"
        type="url"
        required
        maxLength={300}
        defaultValue={values.baseUrl}
        placeholder="https://gateway.example.com/v1 or http://localhost:1234/v1"
        className={field}
      />
      <label htmlFor="custom-models" className="block text-sm font-medium">
        Model ids (comma separated, up to 10)
      </label>
      <input
        id="custom-models"
        name="models"
        required
        maxLength={2000}
        defaultValue={values.models}
        placeholder="llama-3.1-8b-instruct"
        className={field}
      />
      <label htmlFor="custom-key" className="block text-sm font-medium">
        API key (leave empty if the server needs none)
      </label>
      <input
        id="custom-key"
        name="apiKey"
        type="password"
        autoComplete="off"
        spellCheck={false}
        maxLength={512}
        className={field}
      />
      {state.error && (
        <p role="alert" className="text-sm text-red-800">
          {state.error}
        </p>
      )}
      {state.saved && (
        <p role="status" className="text-sm text-teal-800">
          The endpoint answered and was saved.
        </p>
      )}
      <Button type="submit" disabled={pending}>
        {pending ? 'Testing…' : 'Test and save endpoint'}
      </Button>
    </form>
  );
}
