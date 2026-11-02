#!/usr/bin/env node
// Starts everything the app needs, waits until it is ready, and opens the Models page.
// Ctrl+C stops what this script started. Flags: --rebuild, --no-open.
import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const port = Number(process.env.PORT ?? 3000);
const ollamaUrl = (
  process.env.AGENTGATE_OLLAMA_URL ?? 'http://127.0.0.1:11434'
).replace(/\/$/, '');
const scannerPort = Number(process.env.AGENTGATE_SCANNER_PORT ?? 8765);
const scannerUrl =
  process.env.AGENTGATE_SCANNER_URL ?? `http://127.0.0.1:${scannerPort}`;
const started = [];

const say = (message) => console.log(`[agentgate] ${message}`);
async function up(url) {
  try {
    return (await fetch(url, { signal: AbortSignal.timeout(1500) })).ok;
  } catch {
    return false;
  }
}
async function waitFor(url, seconds) {
  for (let i = 0; i < seconds; i += 1) {
    if (await up(url)) return true;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  return false;
}
function launch(name, command, args, env = {}) {
  const child = spawn(command, args, {
    cwd: root,
    env: { ...process.env, ...env },
    stdio: ['ignore', 'ignore', 'inherit'],
  });
  child.on('exit', (code, signal) => {
    if (!shuttingDown)
      say(`${name} stopped unexpectedly (${signal ?? `exit ${code}`}).`);
  });
  started.push(child);
  return child;
}
let shuttingDown = false;
function shutdown() {
  shuttingDown = true;
  for (const child of started) child.kill('SIGTERM');
  setTimeout(() => process.exit(0), 500);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

// 1. Local models.
if (await up(`${ollamaUrl}/api/version`)) {
  say('Ollama is already running.');
} else if (
  spawnSync('ollama', ['--version'], { stdio: 'ignore' }).status === 0
) {
  say('Starting Ollama…');
  launch('Ollama', 'ollama', ['serve'], {
    OLLAMA_KEEP_ALIVE: process.env.OLLAMA_KEEP_ALIVE ?? '30m',
  });
  if (!(await waitFor(`${ollamaUrl}/api/version`, 30)))
    say('Ollama did not start; local models will be unavailable.');
} else {
  say(
    'Ollama is not installed. Run `npm run setup` to install it. Cloud models still work.',
  );
}

// 2. Security scanner. Without it every task and new document is blocked on purpose.
const python = join(root, 'scanner', '.venv', 'bin', 'python');
let scannerReady = null;
if (await up(`${scannerUrl}/health`)) {
  say('The security scanner is already running.');
} else if (existsSync(python)) {
  say(
    'Starting the security scanner (the first start downloads its model, about 700 MB)…',
  );
  launch('Scanner', python, ['scanner/server.py'], {
    AGENTGATE_SCANNER_PORT: String(scannerPort),
  });
  scannerReady = waitFor(`${scannerUrl}/health`, 600);
} else {
  say(
    'The security scanner is not installed, so tasks and documents will be blocked. Run `npm run setup`.',
  );
}

// 3. The app.
const build = join(root, 'apps', 'web', '.next', 'BUILD_ID');
if (!existsSync(build) || process.argv.includes('--rebuild')) {
  say('Building the app (one time)…');
  const built = spawnSync('npm', ['run', 'build'], {
    cwd: root,
    stdio: 'inherit',
  });
  if (built.status !== 0) {
    say('The build failed.');
    shutdown();
  }
}
launch(
  'App',
  'npm',
  [
    'run',
    'start',
    '--workspace',
    '@agentgate/web',
    '--',
    '--port',
    String(port),
  ],
  {
    AGENTGATE_SCANNER_URL: scannerUrl,
  },
);
const appUrl = `http://127.0.0.1:${port}`;
if (!(await waitFor(appUrl, 60))) {
  say(
    `The app did not start on port ${port}. Is something else using it? Set PORT to use another.`,
  );
  shutdown();
} else {
  if (scannerReady && !(await scannerReady))
    say('The scanner is still not ready; tasks stay blocked until it is.');
  say(`Ready: ${appUrl}/models   (Ctrl+C to stop)`);
  if (!process.argv.includes('--no-open')) {
    const opener =
      process.platform === 'darwin'
        ? 'open'
        : process.platform === 'linux'
          ? 'xdg-open'
          : null;
    if (opener)
      spawn(opener, [`${appUrl}/models`], { stdio: 'ignore', detached: true })
        .on('error', () => {})
        .unref();
  }
}
