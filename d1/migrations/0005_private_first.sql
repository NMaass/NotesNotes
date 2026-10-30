-- Private first and linked accounts (docs/IOS_API.md, "Private first" and "Linked
-- accounts"). Additive and idempotent: safe to run twice, and on a database that
-- already has d1/schema.sql applied.

-- One-shot data changes record themselves here so a re-run skips them.
create table if not exists migration_markers (
  name text primary key,
  applied_at text not null default (datetime('now'))
);

-- Every entry and collection written before the published flag is unpublished once.
-- They were written while the app's visibility toggle defaulted to public, and under
-- private first a default is not a choice to publish. The owner's bundle keeps every
-- row; publishing again is one tap. The marker keeps a re-run from unpublishing
-- anything published afterwards.
update journal_entries set is_public = 0 where not exists (select 1 from migration_markers where name = '0005_private_first');
update collections set is_public = 0 where not exists (select 1 from migration_markers where name = '0005_private_first');
insert or ignore into migration_markers (name) values ('0005_private_first');

-- Scrobbling accounts linked through the service's own sign-in (Last.fm web auth).
-- The session key never leaves the server.
create table if not exists linked_accounts (
  profile_id text not null references profiles(id) on delete cascade,
  service text not null check (service in ('lastfm')),
  username text not null,
  session_key text not null,
  linked_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  primary key (profile_id, service)
);
