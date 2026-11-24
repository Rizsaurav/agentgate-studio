import { execFile } from 'node:child_process';
import {
  createWriteStream,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
} from 'node:fs';
import { homedir, platform, tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

const run = promisify(execFile);

export const OLLAMA_DOWNLOAD_URL =
  'https://ollama.com/download/Ollama-darwin.zip';
/** Apple developer team that signs Ollama's releases (Infra Technologies, Inc). */
export const OLLAMA_TEAM_ID = '3MU9H2V9Y9';
const DOWNLOAD_TIMEOUT_MS = 30 * 60_000;
const MAX_DOWNLOAD_BYTES = 1024 ** 3;
const MB = 1024 ** 2;
const CLI_INSIDE_APP = join('Contents', 'Resources', 'ollama');

function appLocations(): string[] {
  return [
    '/Applications/Ollama.app',
    join(homedir(), 'Applications', 'Ollama.app'),
  ];
}

/** The Ollama command to run: one on PATH, else the one inside an installed Ollama.app, else null. */
export async function findOllama(): Promise<string | null> {
  try {
    await run('ollama', ['--version'], { timeout: 5000 });
    return 'ollama';
  } catch {
    // Not on PATH; the desktop app keeps its own copy inside the bundle.
  }
  for (const app of appLocations()) {
    const cli = join(app, CLI_INSIDE_APP);
    if (existsSync(cli)) return cli;
  }
  return null;
}

/** Rejects anything not signed by Ollama's developer team and notarized by Apple. */
export async function verifyOllamaApp(
  app: string,
  teamId = OLLAMA_TEAM_ID,
): Promise<void> {
  try {
    await run('codesign', ['--verify', '--deep', '--strict', app]);
    const { stderr } = await run('codesign', ['-dv', app]);
    if (!stderr.includes(`TeamIdentifier=${teamId}`))
      throw new Error('signed by a different developer');
    await run('spctl', ['--assess', '--type', 'execute', app]);
  } catch (error) {
    throw new Error(
      `The Ollama download failed its signature check (${error instanceof Error ? error.message.split('\n')[0] : 'unknown'}) and was deleted.`,
    );
  }
}

/**
 * Downloads Ollama's official macOS release, checks its signature, and installs it to
 * ~/Applications (no administrator password). Returns the command to run.
 */
export async function installOllama(
  report: (message: string) => void,
  signal: AbortSignal,
  url = OLLAMA_DOWNLOAD_URL,
): Promise<string> {
  if (platform() !== 'darwin')
    throw new Error(
      'Ollama installs automatically on macOS only. Install it from https://ollama.com/download, then try again.',
    );
  const work = mkdtempSync(join(tmpdir(), 'agentgate-ollama-'));
  try {
    const response = await fetch(url, {
      signal: AbortSignal.any([
        signal,
        AbortSignal.timeout(DOWNLOAD_TIMEOUT_MS),
      ]),
    });
    if (!response.ok || !response.body)
      throw new Error(`The Ollama download failed (HTTP ${response.status}).`);
    const total = Number(response.headers.get('content-length')) || 0;
    if (total > MAX_DOWNLOAD_BYTES)
      throw new Error('The Ollama download is unexpectedly large.');
    const zip = join(work, 'Ollama.zip');
    const file = createWriteStream(zip);
    let received = 0;
    try {
      for await (const chunk of response.body) {
        received += (chunk as Uint8Array).byteLength;
        if (received > MAX_DOWNLOAD_BYTES)
          throw new Error('The Ollama download is unexpectedly large.');
        if (!file.write(chunk))
          await new Promise<void>((resolve) =>
            file.once('drain', () => resolve()),
          );
        report(
          `Installing Ollama (${Math.round(received / MB)}${total ? ` of ${Math.round(total / MB)}` : ''} MB)…`,
        );
      }
    } finally {
      await new Promise<void>((resolve) => file.end(() => resolve()));
    }
    report('Checking the Ollama signature…');
    await run('ditto', ['-x', '-k', zip, join(work, 'app')]);
    const downloaded = join(work, 'app', 'Ollama.app');
    await verifyOllamaApp(downloaded);
    const target = join(homedir(), 'Applications');
    mkdirSync(target, { recursive: true });
    await run('ditto', [downloaded, join(target, 'Ollama.app')]);
    return join(target, 'Ollama.app', CLI_INSIDE_APP);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}
