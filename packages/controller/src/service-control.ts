import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { reachable } from './health';

const POLL_MS = 500;

async function waitUntil(url: string, seconds: number): Promise<boolean> {
  for (let i = 0; i < (seconds * 1000) / POLL_MS; i += 1) {
    if (await reachable(url)) return true;
    await new Promise((resolve) => setTimeout(resolve, POLL_MS));
  }
  return false;
}

/** Starts a long-running service that outlives this process, and reports a spawn failure. */
function launch(
  command: string,
  args: string[],
  options: { cwd?: string; env?: Record<string, string> } = {},
): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      detached: true,
      stdio: 'ignore',
    });
    child.once('error', reject);
    child.once('spawn', () => {
      child.unref();
      resolve();
    });
  });
}

/** Starts Ollama unless it is already answering. Waits a bounded time for it to come up. */
export async function startOllama(
  ollamaUrl: string,
  command = 'ollama',
): Promise<string> {
  if (await reachable(`${ollamaUrl}/api/version`))
    return 'Ollama is already running.';
  try {
    await launch(command, ['serve']);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT')
      throw new Error('Ollama is not installed. Run `npm run setup`.');
    throw error;
  }
  return (await waitUntil(`${ollamaUrl}/api/version`, 20))
    ? 'Ollama started.'
    : 'Ollama was launched but is not answering yet.';
}

/** Starts the security scanner from its virtual environment, if `npm run setup` created one. */
export async function startScanner(options: {
  root: string;
  url: string;
}): Promise<string> {
  if (await reachable(`${options.url}/health`))
    return 'The scanner is already running.';
  const python = join(options.root, 'scanner', '.venv', 'bin', 'python');
  if (!existsSync(python))
    throw new Error('The scanner is not installed. Run `npm run setup`.');
  await launch(python, ['scanner/server.py'], {
    cwd: options.root,
    env: { AGENTGATE_SCANNER_PORT: new URL(options.url).port },
  });
  // The first start downloads a model (about 700 MB), so a slow start is not a failure.
  return (await waitUntil(`${options.url}/health`, 30))
    ? 'The scanner started.'
    : 'The scanner was launched and is still loading its model; this can take minutes on the first start.';
}
