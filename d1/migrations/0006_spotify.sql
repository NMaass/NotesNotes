-- Spotify sign-in, history and playback (docs/IOS_API.md, "Linked accounts: Spotify").
-- Additive and idempotent: safe to run twice, and on a database that already has
-- d1/schema.sql applied.

-- One linked Spotify account per profile (Authorization Code + PKCE, exchanged on the
-- Worker with the client secret). The tokens never leave the server.
create table if not exists spotify_accounts (
  profile_id text primary key references profiles(id) on delete cascade,
  spotify_user_id text not null,
  display_name text,
  product text,                 -- 'premium' | 'free' | ... from GET /v1/me
  scope text not null,
  refresh_token text not null,
  access_token text,
  access_expires_at text,       -- ISO-8601
  linked_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
