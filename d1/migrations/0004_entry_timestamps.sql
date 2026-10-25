-- Entry timestamps are what the feed, entity pages, profiles, and feed cursors order by.
-- The server now stores them as ISO-8601 UTC, never later than its own clock
-- (src/lib/server/timestamps.ts). This brings rows written before that into line: a
-- future or unreadable updated_at becomes now, created_at is no later than updated_at,
-- and every value takes the same ISO format so text order is time order.
-- Idempotent: safe to run twice, and a no-op on rows already in shape.
update journal_entries
  set updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  where julianday(updated_at) is null or julianday(updated_at) > julianday('now');
update journal_entries
  set created_at = updated_at
  where julianday(created_at) is null or julianday(created_at) > julianday(updated_at);
update journal_entries
  set updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', updated_at)
  where updated_at <> strftime('%Y-%m-%dT%H:%M:%fZ', updated_at);
update journal_entries
  set created_at = strftime('%Y-%m-%dT%H:%M:%fZ', created_at)
  where created_at <> strftime('%Y-%m-%dT%H:%M:%fZ', created_at);
