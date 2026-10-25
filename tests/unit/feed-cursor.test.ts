import { describe, expect, it } from 'vitest';
import { decodeFeedCursor, encodeFeedCursor } from '@/lib/server/feed-cursor';

describe('feed cursors', () => {
  it('round-trips updatedAt and id, so entries sharing a timestamp page correctly', () => {
    const cursor = { updatedAt: '2026-10-24T17:30:00.000Z', id: 'c460eb5e-0000-4000-8000-000000000000' };
    const encoded = encodeFeedCursor(cursor);
    expect(encoded).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(decodeFeedCursor(encoded)).toEqual(cursor);
    // SQLite datetime('now') defaults are timestamps too.
    expect(decodeFeedCursor(encodeFeedCursor({ updatedAt: '2026-10-24 17:30:00', id: 'x' }))).toEqual({ updatedAt: '2026-10-24 17:30:00', id: 'x' });
  });

  it('accepts a bare timestamp from the first version and rejects anything else', () => {
    expect(decodeFeedCursor('2026-10-24T17:30:00.000Z')).toEqual({ updatedAt: '2026-10-24T17:30:00.000Z' });
    expect(decodeFeedCursor('garbage!')).toBeNull();
    expect(decodeFeedCursor('Z2FyYmFnZQ')).toBeNull();
  });
});
