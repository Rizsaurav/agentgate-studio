import { expect, type Page } from '@playwright/test';

/**
 * Chooses a model in the new-conversation picker (#48): one of the suggested models when it is
 * there, otherwise through "All models" and its search, as a user would.
 */
export async function chooseModel(page: Page, value: string): Promise<void> {
  const picker = page.getByRole('group', { name: 'Model' });
  const suggested = picker
    .getByRole('list', { name: 'Suggested models' })
    .locator(`input[value="${value}"]`);
  if ((await suggested.count()) > 0) {
    await suggested.check();
  } else {
    // "All models (n)" when closed, "Hide all models" when open.
    const all = picker.getByRole('button', { name: /all models/i });
    if ((await all.getAttribute('aria-expanded')) !== 'true') await all.click();
    await picker
      .getByLabel('Search all models')
      .fill(value.split('/').at(-1) ?? value);
    await picker.locator(`input[value="${value}"]`).first().check();
  }
  await expect(page.getByText(`Selected: ${value}`)).toBeVisible();
}
