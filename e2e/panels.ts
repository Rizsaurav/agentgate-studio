import { expect, type Locator, type Page } from '@playwright/test';

/** Project controls open in a dialog; the page behind it is inert until it is closed. */
export async function openPanel(page: Page, title: string): Promise<Locator> {
  const dialog = page.getByRole('dialog', { name: title });
  if (!(await dialog.isVisible()))
    await page.getByRole('button', { name: title, exact: true }).click();
  await expect(dialog).toBeVisible();
  return dialog;
}

export async function closePanel(page: Page, title: string): Promise<void> {
  await page.getByRole('button', { name: `Close ${title}` }).click();
  await expect(page.getByRole('dialog', { name: title })).toBeHidden();
}

/** References a file or folder already in the reference folder; leaves the dialog open. */
export async function addReference(page: Page, path: string): Promise<Locator> {
  const panel = await openPanel(page, 'Reference documents');
  const input = panel.getByLabel('File or folder in the reference folder');
  if (!(await input.isVisible()))
    await panel
      .getByText('Or use a file already in the reference folder')
      .click();
  await input.fill(path);
  await panel.getByRole('button', { name: 'Add reference' }).click();
  return panel;
}
