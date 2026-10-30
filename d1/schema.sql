-- Resonote on Cloudflare D1 (SQLite).
-- Catalog entities imported by workers live here alongside user-authored data.
-- The seeded demo catalog itself stays in application code.

create table if not exists users (
  id text primary key,
  email text not null unique,
  created_at text not null default (datetime('now'))
);

create table if not exists otp_codes (
  id text primary key,
  email text not null,
  code_hash text not null,
  expires_at text not null,
  consumed integer not null default 0,
  created_at text not null default (datetime('now'))
);
create index if not exists otp_codes_email_idx on otp_codes(email);

create table if not exists sessions (
  id text primary key,            -- sha256 of the cookie token
  user_id text not null references users(id) on delete cascade,
  expires_at text not null,
  created_at text not null default (datetime('now'))
);
create index if not exists sessions_user_idx on sessions(user_id);

create table if not exists profiles (
  id text primary key references users(id) on delete cascade,
  handle text not null unique,
  display_name text not null,
  bio text not null default '',
  avatar_url text,
  profile_song_id text,
  genre_ids text not null default '[]',
  created_at text not null default (datetime('now'))
);

create table if not exists artists (
  id text primary key,
  name text not null,
  slug text not null unique,
  sort_name text,
  country text,
  image_url text,
  musicbrainz_id text unique,
  summary text,
  created_at text not null default (datetime('now'))
);
create index if not exists artists_slug_idx on artists(slug);

create table if not exists albums (
  id text primary key,
  artist_id text not null references artists(id) on delete cascade,
  name text not null,
  slug text not null,
  release_year integer check (release_year is null or release_year between 1800 and 2200),
  release_group_type text,
  image_url text,
  musicbrainz_release_group_id text unique,
  summary text,
  created_at text not null default (datetime('now')),
  unique (artist_id, slug)
);
create index if not exists albums_artist_idx on albums(artist_id);
create index if not exists albums_slug_idx on albums(slug);

create table if not exists songs (
  id text primary key,
  artist_id text not null references artists(id) on delete cascade,
  album_id text references albums(id) on delete set null,
  name text not null,
  slug text not null,
  track_number integer,
  duration_ms integer check (duration_ms is null or duration_ms > 0),
  is_bonus_track integer not null default 0,
  image_url text,
  musicbrainz_recording_id text unique,
  spotify_id text,
  youtube_id text,
  summary text,
  created_at text not null default (datetime('now')),
  unique (artist_id, album_id, slug)
);
create index if not exists songs_artist_idx on songs(artist_id);
create index if not exists songs_album_idx on songs(album_id);
create index if not exists songs_slug_idx on songs(slug);

create table if not exists entity_genres (
  id text primary key,
  entity_id text not null,
  entity_kind text not null check (entity_kind in ('artist','album','song','genre')),
  genre_id text not null,
  source text not null check (source in ('catalog','community','user')),
  created_by text references profiles(id) on delete cascade,
  votes integer default 1,
  created_at text not null default (datetime('now'))
);
create index if not exists entity_genres_entity_idx on entity_genres(entity_id);

create table if not exists likes (
  id text primary key,
  profile_id text not null references profiles(id) on delete cascade,
  entity_id text not null,
  entity_kind text not null,
  client_version integer not null default 1,
  created_at text not null default (datetime('now')),
  unique (profile_id, entity_id)
);
create index if not exists likes_profile_idx on likes(profile_id);

create table if not exists journal_entries (
  id text primary key,
  profile_id text not null references profiles(id) on delete cascade,
  entity_id text not null,
  entity_kind text not null,
  title text,
  document text not null,        -- Tiptap JSON
  plain_text text not null default '',
  worked text,
  didnt_work text,
  lenses text not null default '[]',
  is_public integer not null default 0,  -- published; private first
  created_at text not null default (datetime('now')),
  updated_at text not null default (datetime('now'))
);
create index if not exists entries_profile_idx on journal_entries(profile_id);
create index if not exists entries_entity_idx on journal_entries(entity_id);

create table if not exists entry_references (
  id text primary key,
  entry_id text not null references journal_entries(id) on delete cascade,
  reference_id text not null,
  entity_id text not null,
  entity_kind text not null,
  label text not null,
  relation text not null,
  lenses text not null default '[]'
);
create index if not exists entry_references_entry_idx on entry_references(entry_id);
create index if not exists entry_references_entity_idx on entry_references(entity_id);

create table if not exists listen_logs (
  id text primary key,
  profile_id text not null references profiles(id) on delete cascade,
  song_id text not null,
  moods text not null default '[]',
  note text,
  listened_at text not null
);
create index if not exists listens_profile_idx on listen_logs(profile_id);

create table if not exists collections (
  id text primary key,
  profile_id text not null references profiles(id) on delete cascade,
  name text not null,
  slug text not null,
  description text not null default '',
  is_public integer not null default 0,  -- published; private first
  created_at text not null default (datetime('now')),
  updated_at text not null default (datetime('now')),
  unique (profile_id, slug)
);

create table if not exists collection_items (
  id text primary key,
  collection_id text not null references collections(id) on delete cascade,
  entity_id text not null,
  entity_kind text not null,
  note text,
  position integer not null default 0
);
create index if not exists collection_items_collection_idx on collection_items(collection_id);

create table if not exists profile_pins (
  id text primary key,
  profile_id text not null references profiles(id) on delete cascade,
  target_type text not null check (target_type in ('entity','entry','collection')),
  target_id text not null,
  position integer not null default 0,
  unique (profile_id, target_type, target_id)
);

-- --- Native client additions (mirrors d1/migrations/0002_native_client.sql) ---
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

-- Account deletion and user safety (d1/migrations/0003_account_and_safety.sql).

-- Reports of objectionable writing or profiles, kept for the people who run Resonote
-- to review. target_type: 'entry' | 'profile'.
create table if not exists content_reports (
  id text primary key,
  reporter_id text not null references profiles(id) on delete cascade,
  target_type text not null check (target_type in ('entry','profile')),
  target_id text not null,
  reason text not null check (reason in ('spam','harassment','hate','sexual','other')),
  created_at text not null default (datetime('now')),
  unique (reporter_id, target_type, target_id)
);
create index if not exists content_reports_target_idx on content_reports(target_type, target_id);

-- People someone chose not to see. Their writing is hidden from the blocker everywhere.
create table if not exists profile_blocks (
  blocker_id text not null references profiles(id) on delete cascade,
  blocked_id text not null references profiles(id) on delete cascade,
  created_at text not null default (datetime('now')),
  primary key (blocker_id, blocked_id)
);
create index if not exists profile_blocks_blocked_idx on profile_blocks(blocked_id);

-- Entry timestamps (d1/migrations/0004_entry_timestamps.sql). The server stores them as
-- ISO-8601 UTC, never later than its own clock, because public surfaces and feed cursors
-- order by them. Rows written before that are brought into line (a no-op on a new database).
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

-- Private first and linked accounts (d1/migrations/0005_private_first.sql). Rows written
-- before the published flag are unpublished once (a no-op on a new database); the marker
-- keeps a re-run from unpublishing anything published afterwards.
create table if not exists migration_markers (
  name text primary key,
  applied_at text not null default (datetime('now'))
);
update journal_entries set is_public = 0 where not exists (select 1 from migration_markers where name = '0005_private_first');
update collections set is_public = 0 where not exists (select 1 from migration_markers where name = '0005_private_first');
insert or ignore into migration_markers (name) values ('0005_private_first');

-- Scrobbling accounts linked through the service's own sign-in. The session key never leaves the server.
create table if not exists linked_accounts (
  profile_id text not null references profiles(id) on delete cascade,
  service text not null check (service in ('lastfm')),
  username text not null,
  session_key text not null,
  linked_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  primary key (profile_id, service)
);
