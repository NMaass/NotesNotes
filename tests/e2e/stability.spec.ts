import { expect, test } from '@playwright/test';
import { expectStableGeometry } from './helpers/expect-stable-geometry';

test('prompt reroll does not move the editor surface', async ({ page }) => {
  await page.goto('/write/song/40000000-0000-0000-0000-000000000001');
  const editor = page.locator('.editor-surface');
  await expectStableGeometry(editor, async () => { await page.getByRole('button', { name: 'Another prompt' }).click(); });
});

test('like label replacement keeps the action geometry stable', async ({ page }) => {
  await page.goto('/music/nirvana/nevermind/lithium');
  const like = page.getByRole('button', { name: /^Like$/ });
  const before = await like.boundingBox();
  await like.click();
  await page.getByLabel('Email').fill('demo@example.com');
  await page.getByRole('button', { name: 'Send code' }).click();
  await page.getByLabel('One-time code').fill('000000');
  await page.getByRole('button', { name: 'Continue' }).click();
  await expect(page.getByRole('button', { name: 'Liked' })).toBeVisible();
  const after = await page.getByRole('button', { name: 'Liked' }).boundingBox();
  expect(before).not.toBeNull(); expect(after).not.toBeNull();
  expect(Math.abs(after!.width - before!.width)).toBeLessThanOrEqual(1);
  expect(Math.abs(after!.height - before!.height)).toBeLessThanOrEqual(1);
});

test('library accordion preserves the trigger and focus', async ({ page }) => {
  await page.goto('/@maya');
  await page.getByRole('tab', { name: /Library/ }).click();
  const trigger = page.getByRole('button', { name: /Nirvana/ });
  await trigger.focus();
  const before = await trigger.boundingBox();
  await trigger.press('Enter');
  await expect(trigger).toBeFocused();
  const after = await trigger.boundingBox();
  expect(before).not.toBeNull(); expect(after).not.toBeNull();
  expect(Math.abs(after!.x - before!.x)).toBeLessThanOrEqual(1);
  expect(Math.abs(after!.width - before!.width)).toBeLessThanOrEqual(1);
});

test('record motion respects reduced motion', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/music/nirvana/nevermind/lithium');
  await page.getByRole('button', { name: 'Play' }).first().click();
  const animationName = await page.locator('.vinyl').first().evaluate((element) => getComputedStyle(element).animationName);
  expect(animationName).toBe('none');
});


test('profile hash selects the matching stable tab', async ({ page }) => {
  await page.goto('/@maya#library');
  await expect(page.getByRole('tab', { name: /Library/ })).toHaveAttribute('data-state', 'active');
  await expect(page.getByRole('heading', { name: 'Liked music' })).toBeVisible();
});

test('backslash inserts an explicit linked music entity', async ({ page }) => {
  await page.goto('/write/song/40000000-0000-0000-0000-000000000001');
  const editor = page.locator('.journal-prosemirror');
  await editor.click();
  await page.keyboard.type('The vocal production reminds me of \When You Sleep');
  const option = page.getByRole('option').filter({ hasText: 'When You Sleep' }).first();
  await expect(option).toBeVisible();
  await option.click();
  await expect(editor.locator('[data-music-reference][data-label="When You Sleep"]')).toBeVisible();
});

test('pausing keeps the active player iframe mounted', async ({ page }) => {
  await page.goto('/music/nirvana/nevermind/lithium');
  await page.getByRole('button', { name: 'Play' }).first().click();
  const frame = page.locator('.persistent-player iframe');
  await expect(frame).toBeAttached();
  await frame.evaluate((element) => { element.setAttribute('data-stability-sentinel', 'kept'); });
  await page.locator('.persistent-player').getByRole('button', { name: 'Pause' }).click();
  await expect(frame).toHaveAttribute('data-stability-sentinel', 'kept');
});
