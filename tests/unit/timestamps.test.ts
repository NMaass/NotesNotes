import { describe, expect, it } from 'vitest';
import { decodeFeedCursor, encodeFeedCursor } from '@/lib/server/feed-cursor';
import { storedEntryTimes, storedTimestamp } from '@/lib/server/timestamps';

const now = new Date('2026-10-24T18:00:00.000Z');

describe('stored entry timestamps', () => {
  it('keeps a past ISO time, normalized to UTC milliseconds', () => {
    expect(storedTimestamp('2026-10-24T12:00:00.000Z', now)).toBe('2026-10-24T12:00:00.000Z');
    expect(storedTimestamp('2026-10-24T14:00:00+02:00', now)).toBe('2026-10-24T12:00:00.000Z');
    expect(storedTimestamp('2026-10-24T14:00:00.123456+0200', now)).toBe('2026-10-24T12:00:00.123Z');
    // SQLite's datetime('now') format has no zone and is UTC.
    expect(storedTimestamp('2026-10-24 12:00:00', now)).toBe('2026-10-24T12:00:00.000Z');
    expect(storedTimestamp('2026-10-24T12:00', now)).toBe('2026-10-24T12:00:00.000Z');
  });

  it('never stores a time later than the server clock, so nothing can be pinned to the top of the feed', () => {
    expect(storedTimestamp('9999-12-31T00:00:00.000Z', now)).toBe(now.toISOString());
    // A device clock a minute ahead.
    expect(storedTimestamp('2026-10-24T18:01:00.000Z', now)).toBe(now.toISOString());
  });

  it('replaces anything that does not read as a time with now', () => {
    for (const value of ['zzzz', '', '2026-13-45T99:99:99Z', '1729792800', 'tomorrow', null, undefined, 42, {}]) {
      expect(storedTimestamp(value, now)).toBe(now.toISOString());
    }
  });

  it('keeps created no later than updated', () => {
    expect(storedEntryTimes({ createdAt: '9999-01-01T00:00:00Z', updatedAt: '2026-10-24T12:00:00Z' }, now))
      .toEqual({ createdAt: '2026-10-24T12:00:00.000Z', updatedAt: '2026-10-24T12:00:00.000Z' });
    expect(storedEntryTimes({ createdAt: '2026-10-01T00:00:00Z', updatedAt: '2026-10-24T12:00:00Z' }, now))
      .toEqual({ createdAt: '2026-10-01T00:00:00.000Z', updatedAt: '2026-10-24T12:00:00.000Z' });
  });

  it('always yields a feed cursor the next page accepts', () => {
    for (const value of ['zzzz', '9999-12-31T00:00:00.000Z', '2026-10-24 12:00:00']) {
      const updatedAt = storedTimestamp(value, now);
      expect(decodeFeedCursor(encodeFeedCursor({ updatedAt, id: 'e1' }))).toEqual({ updatedAt, id: 'e1' });
    }
  });
});
