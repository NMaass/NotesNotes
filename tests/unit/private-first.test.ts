// Private first (docs/IOS_API.md): the real schema and queries, run against an
// in-memory SQLite database standing in for D1.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Collection, JournalEntry } from '@/lib/data/types';

const d1 = vi.hoisted(() => {
  const state: { db: import('node:sqlite').DatabaseSync | null } = { db: null };
  const statement = (text: string, values: unknown[]) => {
    const prepared = () => state.db!.prepare(text);
    return {
      first: async () => prepared().get(...(values as never[])) ?? null,
      all: async () => ({ results: prepared().all(...(values as never[])) }),
      run: async () => ({ success: true, meta: { changes: Number(prepared().run(...(values as never[])).changes) } }),
    };
  };
  const DB = {
    prepare: (text: string) => ({ bind: (...values: unknown[]) => statement(text, values) }),
    batch: async (statements: Array<ReturnType<typeof statement>>) => {
      state.db!.exec('begin');
      try {
        const results = [];
        for (const item of statements) results.push(await item.run());
        state.db!.exec('commit');
        return results;
      } catch (error) {
        state.db!.exec('rollback');
        throw error;
      }
    },
  };
  return { state, DB };
});

vi.mock('server-only', () => ({}));
vi.mock('@opennextjs/cloudflare', () => ({ getCloudflareContext: async () => ({ env: { DB: d1.DB } }) }));

const { loadOwnBundle, loadPublicBundleByHandle, saveCollection, saveEntry } = await import('@/lib/server/repo');
const { loadEntityDetail, loadFeed } = await import('@/lib/server/catalog');

const ROOT = path.resolve(__dirname, '../..');
const SONG = '40000000-0000-0000-0000-000000000001'; // Lithium, seeded
const OTHER_SONG = '40000000-0000-0000-0000-000000000002'; // When You Sleep, seeded
const OWNER = 'owner-profile';
const NOW = '2026-10-29T12:00:00.000Z';

function exec(sqlText: string, ...values: unknown[]) {
  d1.state.db!.prepare(sqlText).run(...(values as never[]));
}

function entry(id: string, extra: Record<string, unknown> = {}): JournalEntry {
  return {
    id, profileId: OWNER, entityId: SONG, entityKind: 'song', document: { type: 'doc', content: [] }, plainText: id,
    lenses: [], references: [], public: false, createdAt: NOW, updatedAt: NOW, ...extra,
  } as JournalEntry;
}

function collection(id: string, extra: Record<string, unknown> = {}): Collection {
  return { id, profileId: OWNER, name: id, slug: id, description: '', public: false, items: [], createdAt: NOW, updatedAt: NOW, ...extra } as Collection;
}

beforeEach(async () => {
  d1.state.db = new DatabaseSync(':memory:');
  d1.state.db.exec(readFileSync(path.join(ROOT, 'd1/schema.sql'), 'utf8'));
  exec("insert into users (id, email) values (?, 'owner@example.com')", OWNER);
  exec("insert into profiles (id, handle, display_name) values (?, 'owner', 'Owner')", OWNER);
  await saveEntry(OWNER, entry('published-entry', { published: true }));
  await saveEntry(OWNER, entry('private-entry', { published: false }));
  // An older build sent only `public: true` by default: that is not a choice to publish.
  await saveEntry(OWNER, entry('legacy-public-entry', { public: true }));
  await saveCollection(OWNER, collection('published-list', { published: true }));
  await saveCollection(OWNER, collection('private-list', { public: true }));
  exec("insert into likes (id, profile_id, entity_id, entity_kind) values ('like-1', ?, ?, 'song')", OWNER, OTHER_SONG);
  exec("insert into listen_logs (id, profile_id, song_id, listened_at) values ('listen-1', ?, ?, ?)", OWNER, OTHER_SONG, NOW);
  for (const [id, type, target] of [['pin-1', 'entry', 'published-entry'], ['pin-2', 'entry', 'private-entry'], ['pin-3', 'collection', 'private-list'], ['pin-4', 'entity', SONG]]) {
    exec('insert into profile_pins (id, profile_id, target_type, target_id) values (?, ?, ?, ?)', id, OWNER, type, target);
  }
});

describe('published flag on writes', () => {
  it('stores published === true only, ignoring the legacy public key', () => {
    const rows = d1.state.db!.prepare('select id, is_public from journal_entries order by id').all() as Array<{ id: string; is_public: number }>;
    expect(Object.fromEntries(rows.map((row) => [row.id, row.is_public]))).toEqual({ 'legacy-public-entry': 0, 'private-entry': 0, 'published-entry': 1 });
  });

  it('treats a non-boolean published as private', async () => {
    await saveEntry(OWNER, entry('stringly', { published: 'true' }));
    expect(d1.state.db!.prepare("select is_public from journal_entries where id = 'stringly'").get()).toMatchObject({ is_public: 0 });
  });

  it('unpublishes with an ordinary write', async () => {
    await saveEntry(OWNER, entry('published-entry', { published: false }));
    expect((await loadFeed(30, null)).entries).toEqual([]);
  });
});

describe('public surfaces carry published writing only', () => {
  it('feed', async () => {
    const feed = await loadFeed(30, null);
    expect(feed.entries.map((item) => item.id)).toEqual(['published-entry']);
    expect(feed.entries[0]).toMatchObject({ published: true, public: true });
  });

  it('entity page', async () => {
    const detail = await loadEntityDetail('song', SONG, OWNER);
    expect(detail?.entries.map((item) => item.id)).toEqual(['published-entry']);
  });

  it('public profile bundle, even for the owner: no likes, no listens, no private pins', async () => {
    const bundle = await loadPublicBundleByHandle('@Owner');
    expect(bundle.entries.map((item) => item.id)).toEqual(['published-entry']);
    expect(bundle.collections.map((item) => [item.id, item.published, item.public])).toEqual([['published-list', true, true]]);
    expect(bundle.likes).toEqual([]);
    expect(bundle.listens).toEqual([]);
    expect(bundle.pins.map((pin) => pin.id).sort()).toEqual(['pin-1', 'pin-4']);
    // The liked and listened song is referenced by nothing public, so it does not ship.
    expect(bundle.catalog.songs.map((song) => song.id)).not.toContain(OTHER_SONG);
  });
});

describe('owner bundle', () => {
  it('keeps everything, with both wire names for the flag', async () => {
    const bundle = await loadOwnBundle(OWNER);
    expect(bundle.entries.map((item) => [item.id, item.published, item.public]).sort()).toEqual([
      ['legacy-public-entry', false, false],
      ['private-entry', false, false],
      ['published-entry', true, true],
    ]);
    expect(bundle.collections.map((item) => [item.id, item.published]).sort()).toEqual([['private-list', false], ['published-list', true]]);
    expect(bundle.likes.map((like) => like.id)).toEqual(['like-1']);
    expect(bundle.listens.map((listen) => listen.id)).toEqual(['listen-1']);
    expect(bundle.pins).toHaveLength(4);
    expect(bundle.catalog.songs.map((song) => song.id)).toContain(OTHER_SONG);
  });
});

describe('migration 0005', () => {
  it('unpublishes existing rows once, and a re-run leaves later publishing alone', () => {
    const migration = readFileSync(path.join(ROOT, 'd1/migrations/0005_private_first.sql'), 'utf8');
    const db = new DatabaseSync(':memory:');
    db.exec(`create table profiles (id text primary key);
      create table journal_entries (id text primary key, is_public integer not null default 1);
      create table collections (id text primary key, is_public integer not null default 1);
      insert into journal_entries (id, is_public) values ('a', 1), ('b', 1);
      insert into collections (id, is_public) values ('c', 1);`);
    db.exec(migration);
    expect(db.prepare('select sum(is_public) as n from journal_entries').get()).toMatchObject({ n: 0 });
    expect(db.prepare('select sum(is_public) as n from collections').get()).toMatchObject({ n: 0 });
    db.exec("update journal_entries set is_public = 1 where id = 'a'");
    db.exec(migration);
    expect(db.prepare("select is_public from journal_entries where id = 'a'").get()).toMatchObject({ is_public: 1 });
    expect(db.prepare("select count(*) as n from sqlite_master where name = 'linked_accounts'").get()).toMatchObject({ n: 1 });
  });
});
