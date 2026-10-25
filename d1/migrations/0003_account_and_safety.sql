-- Account deletion and user safety for the native client (docs/IOS_API.md, App Store
-- guidelines 1.2 and 5.1.1(v)). Additive and idempotent: safe to run twice, and on a
-- database that already has d1/schema.sql applied.

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
