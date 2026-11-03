import { type ChildProcess, spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, test } from '@playwright/test';
import { addReference } from './panels';

const model = process.env.AGENTGATE_E2E_MODEL;
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const servers: ChildProcess[] = [];

/** Starts a separate production server so a test can restart it or point it at broken services. */
async function startServer(port: number, env: Record<string, string>) {
  const child = spawn(
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
      cwd: repoRoot,
      // Never the developer's keychain: tests must not read or change real keys.
      env: { ...process.env, AGENTGATE_SECRETS: 'env', ...env },
      stdio: 'ignore',
      detached: true,
    },
  );
  servers.push(child);
  let exited = false;
  child.once('exit', () => {
    exited = true;
  });
  const url = `http://127.0.0.1:${port}`;
  for (let attempt = 0; attempt < 60 && !exited; attempt += 1) {
    try {
      if ((await fetch(url)).ok) return { url, child };
    } catch {
      // Not listening yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(
    `The server on port ${port} did not start (is the port already in use?).`,
  );
}
/** SIGKILL, like a crash: nothing gets a chance to shut down cleanly. */
function stop(child: ChildProcess) {
  if (child.pid === undefined) return;
  try {
    process.kill(-child.pid, 'SIGKILL');
  } catch (error) {
    // The process group is already gone (stopped earlier in the test).
    if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error;
  }
}
test.afterEach(() => {
  for (const child of servers.splice(0)) stop(child);
});

test('a session and its conversation survive an application restart', async ({
  page,
}) => {
  test.skip(!model, 'Set AGENTGATE_E2E_MODEL.');
  const data = mkdtempSync(join(tmpdir(), 'agentgate-restart-'));
  const env = {
    AGENTGATE_DATA_DIR: data,
    // The scanner Playwright starts (playwright.config.ts); without it every task is blocked.
    AGENTGATE_SCANNER_URL: 'http://127.0.0.1:8766',
  };
  const first = await startServer(3201, env);
  await page.goto(first.url);
  await page.getByLabel('Project name').fill('Restart me');
  await page.getByRole('button', { name: /Create project/ }).click();
  await page
    .getByLabel('Model', { exact: true })
    .selectOption(`ollama/${model}`);
  await page.getByRole('button', { name: 'Start session' }).click();
  await page
    .getByLabel('Task')
    .fill('Reply with one short sentence about rivers.');
  await page.getByRole('button', { name: 'Run task' }).click();
  // These details exist only on a completed, saved answer; the in-progress panel has none.
  await page.getByText('Answer details').click({ timeout: 90_000 });
  await expect(
    page.getByRole('button', { name: 'Save as verified outcome' }),
  ).toBeVisible();
  const turns = page
    .getByRole('list', { name: 'Conversation' })
    .getByRole('listitem');
  await expect(turns).toHaveCount(2, { timeout: 90_000 });
  const sessionUrl = page.url().replace(first.url, '');
  const answer = await turns.nth(1).innerText();

  stop(first.child);
  await expect
    .poll(() =>
      fetch(first.url).then(
        () => 'up',
        () => 'down',
      ),
    )
    .toBe('down');
  const second = await startServer(3202, env);
  await page.goto(second.url + sessionUrl);
  await expect(turns).toHaveCount(2);
  await expect(turns.nth(0)).toContainText('rivers');
  await page.getByText('Answer details').click();
  expect(await turns.nth(1).innerText()).toBe(answer);
  await page.goto(second.url);
  await expect(page.getByRole('heading', { name: 'Restart me' })).toBeVisible();
});

test('scanner outage fails closed in the browser: ingestion and tasks are refused with a reason', async ({
  page,
}) => {
  test.skip(!model, 'Set AGENTGATE_E2E_MODEL.');
  const server = await startServer(3203, {
    AGENTGATE_DATA_DIR: mkdtempSync(join(tmpdir(), 'agentgate-outage-')),
    AGENTGATE_DOCS_ROOT: join(repoRoot, 'fixtures'),
    AGENTGATE_SCANNER_URL: 'http://127.0.0.1:9',
  });
  await page.goto(server.url);
  await page.getByLabel('Project name').fill('Scanner down');
  await page.getByRole('button', { name: /Create project/ }).click();
  const references = await addReference(page, 'rag');
  await expect(
    references.getByText(/security scanner is unavailable/i),
  ).toBeVisible();
  await expect(references.getByText('Returns Policy')).toHaveCount(0);
  await page.getByRole('button', { name: 'Close Reference documents' }).click();

  await page
    .getByLabel('Model', { exact: true })
    .selectOption(`ollama/${model}`);
  await page.getByRole('button', { name: 'Start session' }).click();
  await page
    .getByLabel('Task')
    .fill('How many days do I have to return a bicycle?');
  await page.getByRole('button', { name: 'Run task' }).click();
  await expect(
    page.getByText(/Blocked by security rule scanner-unavailable/),
  ).toBeVisible({ timeout: 60_000 });
});

test('main pages fit a 390px phone without horizontal scrolling', async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const server = await startServer(3204, {
    AGENTGATE_DATA_DIR: mkdtempSync(join(tmpdir(), 'agentgate-mobile-')),
    AGENTGATE_DOCS_ROOT: join(repoRoot, 'fixtures'),
  });
  await page.goto(server.url);
  await page
    .getByLabel('Project name')
    .fill(
      'A very long project name that must wrap instead of forcing the page to scroll sideways',
    );
  await page.getByRole('button', { name: /Create project/ }).click();
  const projectPath = page.url().replace(server.url, '');
  for (const path of [
    '/',
    projectPath,
    '/models',
    '/security',
    '/evaluations',
  ]) {
    await page.goto(server.url + path);
    const overflow = await page.evaluate(
      () =>
        document.documentElement.scrollWidth -
        document.documentElement.clientWidth,
    );
    expect(overflow, `${path} overflows horizontally`).toBeLessThanOrEqual(0);
  }
});
