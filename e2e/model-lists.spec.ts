import { expect, test } from '@playwright/test';
import { chooseModel } from './models';

const model = process.env.AGENTGATE_E2E_MODEL;

// #48: no list on the Models page or the project page shows more than four items until the user
// expands it, and a model can be found by typing part of its name.

test('the Models page shows four providers until "More providers" is opened', async ({
  page,
}) => {
  await page.goto('/models');
  const rows = page.locator('.provider-list details.provider-section');
  await expect(rows.filter({ visible: true })).toHaveCount(4);
  const more = page.getByRole('button', { name: /^More providers/ });
  await expect(more).toHaveAttribute('aria-expanded', 'false');
  await more.click();
  await expect(more).toHaveAttribute('aria-expanded', 'true');
  expect(await rows.filter({ visible: true }).count()).toBeGreaterThan(4);
  const recommended = page.getByRole('list', { name: 'Recommended models' });
  if (await recommended.isVisible())
    expect(
      await recommended.getByRole('listitem').filter({ visible: true }).count(),
    ).toBeLessThanOrEqual(4);
});

test('the conversation picker suggests at most four models and finds one by search', async ({
  page,
}) => {
  test.skip(!model, 'Needs AGENTGATE_E2E_MODEL installed in Ollama.');
  await page.goto('/');
  await page.getByLabel('Project name').fill('Model picker');
  await page.getByRole('button', { name: /Create project/ }).click();
  const picker = page.getByRole('group', { name: 'Model' });
  await expect(picker).toBeVisible();
  expect(
    await picker
      .getByRole('list', { name: 'Suggested models' })
      .getByRole('radio')
      .count(),
  ).toBeLessThanOrEqual(4);

  await chooseModel(page, `ollama/${model}`);
  // The choice survives a refresh: it is in the URL once the picker has written it there.
  await expect(page).toHaveURL(/[?&]model=/);
  await page.reload();
  await expect(page.getByText(`Selected: ollama/${model}`)).toBeVisible();
});
