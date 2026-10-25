// Feed pagination cursors (GET /api/feed). Pure, so it is unit-tested directly.

/** Where the previous page ended: the last entry's updated_at and id (ties on updated_at are common). */
export interface FeedCursor { updatedAt: string; id?: string }

/** Opaque to clients: base64url of `<updatedAt>\n<id>`. */
export function encodeFeedCursor(cursor: Required<FeedCursor>): string {
  return Buffer.from(`${cursor.updatedAt}\n${cursor.id}`, 'utf8').toString('base64url');
}

/**
 * Reads a cursor from a previous page. Also accepts a bare updatedAt timestamp
 * (the first version of this API), which pages by time alone. Null when malformed.
 */
export function decodeFeedCursor(value: string): FeedCursor | null {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return Number.isNaN(Date.parse(value)) ? null : { updatedAt: value };
  const [updatedAt, id, ...rest] = Buffer.from(value, 'base64url').toString('utf8').split('\n');
  if (rest.length || !updatedAt || !id || Number.isNaN(Date.parse(updatedAt.replace(' ', 'T')))) return null;
  return { updatedAt, id };
}
