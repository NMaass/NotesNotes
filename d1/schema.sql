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
  is_public integer not null default 1,
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
  is_public integer not null default 1,
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
