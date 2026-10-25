-- Native client support (docs/IOS_API.md). Additive and idempotent: safe to run
-- on a database that already has d1/schema.sql applied, and safe to run twice.

-- Genres that exist outside the seeded catalog in code, e.g. MusicBrainz
-- community genres suggested while resolving a now-playing track. Seeded genres
-- keep their ids and are never copied here.
create table if not exists genres (
  id text primary key,
  name text not null,
  slug text not null unique,
  musicbrainz_id text unique,
  description text,
  created_at text not null default (datetime('now'))
);

-- Remembers which catalog song a now-playing track resolved to, so the next
-- lookup is one read. key: 'mbid:<recording>' | 'isrc:<ISRC>' |
-- 'url:<canonical url>' | 'text:<folded artist>|<folded title>'.
create table if not exists track_resolutions (
  key text primary key,
  song_id text not null,
  confidence text not null check (confidence in ('exact','strong')),
  created_at text not null default (datetime('now'))
);
create index if not exists track_resolutions_song_idx on track_resolutions(song_id);

-- MusicBrainz community genres for a catalog entity, mapped onto genre ids and
-- fetched once. genres: JSON [{ "id": "<genre id>", "count": <votes> }].
-- An empty array records "MusicBrainz has none" so it is not asked again.
create table if not exists entity_musicbrainz_genres (
  entity_id text primary key,
  entity_kind text not null check (entity_kind in ('artist','album','song')),
  genres text not null default '[]',
  fetched_at text not null default (datetime('now'))
);

-- Feed (public entries newest first) and entity pages (public entries about one entity).
create index if not exists entries_public_updated_idx on journal_entries(is_public, updated_at);
create index if not exists entries_entity_public_idx on journal_entries(entity_id, is_public, updated_at);
-- Genre pages and tag counts look rows up by genre.
create index if not exists entity_genres_genre_idx on entity_genres(genre_id);
-- Prompts and mood suggestions read one person's listens of one song.
create index if not exists listens_profile_song_idx on listen_logs(profile_id, song_id);
-- Pins are cleaned up by target when an entry or collection is deleted.
create index if not exists profile_pins_target_idx on profile_pins(target_type, target_id);

-- One genre assertion per person, entity, and genre, so a resent assertion
-- never counts twice. Duplicates left by earlier retries are removed first
-- (the oldest row is kept).
delete from entity_genres
where source = 'user'
  and rowid not in (
    select min(rowid) from entity_genres where source = 'user' group by created_by, entity_id, genre_id
  );
create unique index if not exists entity_genres_user_uq on entity_genres(created_by, entity_id, genre_id) where source = 'user';

-- Catalog search reads names that start with the query through these indexes
-- (SQLite's LIKE 'prefix%' optimization needs NOCASE indexes), and only then
-- scans for names that contain it.
create index if not exists artists_name_nocase_idx on artists(name collate nocase);
create index if not exists albums_name_nocase_idx on albums(name collate nocase);
create index if not exists songs_name_nocase_idx on songs(name collate nocase);
create index if not exists genres_name_nocase_idx on genres(name collate nocase);

-- A `text:` resolution names no recording, so it is never more than 'strong'.
-- (Rows written by the first version of the resolver could say 'exact'.)
update track_resolutions set confidence = 'strong' where key like 'text:%' and confidence = 'exact';

-- Failed sign-in code attempts, per email. Five within ten minutes lock the
-- email's codes until the window passes (see consumeLoginCode in auth.ts).
create table if not exists login_failures (
  id text primary key,
  email text not null,
  created_at text not null
);
create index if not exists login_failures_email_idx on login_failures(email, created_at);
