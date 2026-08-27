import { expect, type Locator } from '@playwright/test';
export async function expectStableGeometry(locator: Locator, action: () => Promise<void>, tolerance = 1) {
  const before = await locator.boundingBox();
  expect(before).not.toBeNull();
  await action();
  await expect(locator).toBeVisible();
  const after = await locator.boundingBox();
  expect(after).not.toBeNull();
  expect(Math.abs(after!.x - before!.x)).toBeLessThanOrEqual(tolerance);
  expect(Math.abs(after!.y - before!.y)).toBeLessThanOrEqual(tolerance);
  expect(Math.abs(after!.width - before!.width)).toBeLessThanOrEqual(tolerance);
  expect(Math.abs(after!.height - before!.height)).toBeLessThanOrEqual(tolerance);
}
