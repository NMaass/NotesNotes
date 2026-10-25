// Timestamps clients send with public writing. Pure, so it is unit-tested directly.

/** `YYYY-MM-DD[T ]HH:MM[:SS[.fff…]][Z|±HH[:]MM]`: ISO-8601, or SQLite's `datetime('now')`. */
const TIMESTAMP = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$/i;

/**
 * A client-sent timestamp as stored: ISO-8601 in UTC (`toISOString()`), never later
 * than `now`. Anything that doesn't read as a time becomes `now`.
 *
 * Public surfaces (the feed, entity pages, profiles) order entries by these, and feed
 * cursors carry them, so a client must not be able to pin its writing to the top by
 * claiming a future time (or a device clock that runs ahead), nor break paging for
 * everyone with a value that doesn't sort as a time.
 */
export function storedTimestamp(value: unknown, now: Date = new Date()): string {
  const fallback = now.toISOString();
  if (typeof value !== 'string') return fallback;
  const match = TIMESTAMP.exec(value.trim());
  if (!match) return fallback;
  const [, year, month, day, hour, minute, second = '00', fraction = '', zone = 'Z'] = match;
  // No zone (SQLite's own format) means UTC.
  const offset = zone.toUpperCase() === 'Z' ? 'Z' : `${zone.slice(0, 3)}:${zone.slice(-2)}`;
  const parsed = Date.parse(`${year}-${month}-${day}T${hour}:${minute}:${second}${fraction.slice(0, 4)}${offset}`);
  if (Number.isNaN(parsed)) return fallback;
  return new Date(Math.min(parsed, now.getTime())).toISOString();
}

/** An entry's stored `createdAt` and `updatedAt`: both as `storedTimestamp`, created no later than updated. */
export function storedEntryTimes(entry: { createdAt?: unknown; updatedAt?: unknown }, now: Date = new Date()): { createdAt: string; updatedAt: string } {
  const updatedAt = storedTimestamp(entry.updatedAt, now);
  const createdAt = storedTimestamp(entry.createdAt, now);
  return { createdAt: createdAt > updatedAt ? updatedAt : createdAt, updatedAt };
}
