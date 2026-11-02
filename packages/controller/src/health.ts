import { existsSync } from 'node:fs';

const CHECK_TIMEOUT_MS = 2000;

export type ServiceCheck = {
  name: string;
  ok: boolean;
  detail: string;
  fix: string;
};

export async function reachable(url: string): Promise<boolean> {
  try {
    return (await fetch(url, { signal: AbortSignal.timeout(CHECK_TIMEOUT_MS) }))
      .ok;
  } catch {
    return false;
  }
}

/** Plain checks of what the app depends on, each with the step that fixes it. */
export async function checkServices(options: {
  ollamaUrl: string;
  scannerUrl: string;
  docsRoot: string | null;
}): Promise<ServiceCheck[]> {
  const [ollama, scanner] = await Promise.all([
    reachable(`${options.ollamaUrl}/api/version`),
    reachable(`${options.scannerUrl}/health`),
  ]);
  return [
    {
      name: 'Ollama (local models)',
      ok: ollama,
      detail: ollama ? 'Running.' : 'Not reachable.',
      fix: 'Start the app with `npm start`, which starts Ollama for you, or run `ollama serve`. Not installed? Run `npm run setup`.',
    },
    {
      name: 'Security scanner (LLM Guard)',
      ok: scanner,
      detail: scanner
        ? 'Running.'
        : 'Not reachable, so tasks and new documents are blocked until it is.',
      fix: 'Run `npm run setup` once, then start the app with `npm start`.',
    },
    {
      name: 'Reference folder',
      ok: options.docsRoot !== null && existsSync(options.docsRoot),
      detail: options.docsRoot === null ? 'Not set.' : options.docsRoot,
      fix: 'Start the app with `npm start`, or set AGENTGATE_DOCS_ROOT to a folder of .md or .txt files.',
    },
  ];
}
