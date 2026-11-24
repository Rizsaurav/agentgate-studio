import { expect, test } from '@playwright/test';
import { closePanel, openPanel } from './panels';

const model = process.env.AGENTGATE_E2E_MODEL;

// Assembled at runtime so the repository itself never contains a key-shaped string.
const fakeKey = `sk-${'proj-'}${'Ab3x9Kq7'.repeat(5)}`;

test('documents uploaded from the app are screened: ordinary ones are used, one with a key is refused', async ({
  page,
}) => {
  await page.goto('/');
  await page.getByLabel('Project name').fill('Uploads');
  await page.getByRole('button', { name: /Create project/ }).click();

  const references = await openPanel(page, 'Reference documents');
  await references
    .getByLabel('Add your documents (.md or .txt, up to 200 KB each)')
    .setInputFiles([
      {
        name: 'lighthouse.md',
        mimeType: 'text/markdown',
        buffer: Buffer.from(
          '# Lighthouse Hours\n\nThe lighthouse museum opens at nine in the morning and closes at five. Tours leave every hour from the gift shop.\n',
        ),
      },
      {
        name: 'admin-notes.md',
        mimeType: 'text/markdown',
        buffer: Buffer.from(`# Admin Notes\n\nThe admin key is ${fakeKey}.\n`),
      },
    ]);
  await references.getByRole('button', { name: 'Add reference' }).click();

  await expect(references.getByText('Lighthouse Hours')).toBeVisible({
    timeout: 60_000,
  });
  await expect(
    references.getByText(
      /admin-notes\.md: Contains what looks like a credential/,
    ),
  ).toBeVisible();
  await expect(page.getByText('Admin Notes')).toHaveCount(0);
  // The key is never echoed back, not even in the refusal.
  await expect(page.getByText(fakeKey)).toHaveCount(0);
  await closePanel(page, 'Reference documents');

  // Retrieval needs a model; the screening above is checked either way.
  if (!model) return;
  await page
    .getByLabel('Model', { exact: true })
    .selectOption(`ollama/${model}`);
  await page.getByRole('button', { name: 'Start session' }).click();
  await page.getByLabel('Task').fill('When does the lighthouse museum open?');
  await page.getByRole('button', { name: 'Run task' }).click();
  await expect(page.getByText('Retrieved context:')).toContainText(
    'Lighthouse Hours',
    { timeout: 90_000 },
  );
});

test('the assistant panel opens from the title bar, explains what it sees, and asks for a key without showing one', async ({
  page,
}) => {
  await page.goto('/');
  const panel = await openPanel(page, 'Assistant');
  await expect(panel.getByRole('heading', { name: 'Right now' })).toBeVisible();
  // These tests never provide an OpenRouter key, so the assistant offers to be turned on.
  await expect(
    panel.getByRole('heading', { name: 'Turn on the assistant' }),
  ).toBeVisible();
  await expect(panel.getByText(/never sees\s+your documents/)).toBeVisible();
  await expect(panel.getByLabel('OpenRouter API key')).toHaveAttribute(
    'type',
    'password',
  );
  await closePanel(page, 'Assistant');

  // The data behind the panel never carries a key, whatever the configuration.
  const response = await page.request.get('/api/assistant');
  expect(response.ok()).toBe(true);
  const body = await response.text();
  expect(body).not.toMatch(/sk-[A-Za-z0-9_-]{16,}/);
  expect(JSON.parse(body)).toMatchObject({ configured: false });
});
