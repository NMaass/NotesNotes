import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

let ts;
try {
  ({ default: ts } = await import('typescript'));
} catch {
  ({ default: ts } = await import('/opt/nvm/versions/node/v22.16.0/lib/node_modules/typescript/lib/typescript.js'));
}

const root = process.cwd();
const auditDir = path.join(root, '.audit', 'data-validation');
fs.rmSync(auditDir, { recursive: true, force: true });
fs.mkdirSync(auditDir, { recursive: true });

const source = fs.readFileSync(path.join(root, 'src/lib/data/catalog.ts'), 'utf8');
const output = ts.transpileModule(source, {
  compilerOptions: {
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.CommonJS,
    esModuleInterop: true,
  },
}).outputText;
const compiledPath = path.join(auditDir, 'catalog.cjs');
fs.writeFileSync(compiledPath, output);
const require = createRequire(import.meta.url);
const {
  albums,
  artists,
  collections: catalogCollections,
  entityGenres,
  genres,
  seedDemoData,
  songCredits,
  songFacts,
  songs,
} = require(compiledPath);

// catalogCollections is not exported today; keep this destructure harmless for future use.
void catalogCollections;

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const allEntities = [...artists, ...albums, ...songs, ...genres];
const entitiesById = new Map(allEntities.map((entity) => [entity.id, entity]));
const profilesById = new Map(seedDemoData.profiles.map((profile) => [profile.id, profile]));
const entriesById = new Map(seedDemoData.entries.map((entry) => [entry.id, entry]));
const collectionsById = new Map(seedDemoData.collections.map((collection) => [collection.id, collection]));

function assertUuid(value, label) {
  assert.match(value, uuidPattern, `${label} must be a UUID: ${value}`);
}

function assertUnique(values, label) {
  assert.equal(new Set(values).size, values.length, `${label} must be unique`);
}

for (const entity of allEntities) assertUuid(entity.id, `${entity.kind} id`);
for (const profile of seedDemoData.profiles) assertUuid(profile.id, 'profile id');
for (const row of [...seedDemoData.likes, ...seedDemoData.entries, ...seedDemoData.listens, ...seedDemoData.collections, ...seedDemoData.pins]) {
  assertUuid(row.id, 'user-data id');
}
for (const collection of seedDemoData.collections) {
  for (const item of collection.items) assertUuid(item.id, 'collection item id');
}
for (const entry of seedDemoData.entries) {
  for (const reference of entry.references) assertUuid(reference.id, 'music reference id');
}
for (const row of [...songCredits, ...songFacts]) assertUuid(row.id, 'catalog detail id');

assertUnique(allEntities.map((entity) => entity.id), 'catalog entity ids');
assertUnique(seedDemoData.profiles.map((profile) => profile.handle.toLowerCase()), 'profile handles');
assertUnique(artists.map((artist) => artist.slug), 'artist slugs');
assertUnique(genres.map((genre) => genre.slug), 'genre slugs');
assertUnique(albums.map((album) => `${album.artistId}:${album.slug}`), 'album slugs per artist');
assertUnique(songs.map((song) => `${song.artistId}:${song.albumId ?? 'single'}:${song.slug}`), 'song slugs per album');

for (const album of albums) {
  assert.ok(entitiesById.get(album.artistId)?.kind === 'artist', `album ${album.name} must reference an artist`);
}
for (const song of songs) {
  const artist = entitiesById.get(song.artistId);
  assert.equal(artist?.kind, 'artist', `song ${song.name} must reference an artist`);
  if (song.albumId) {
    const album = entitiesById.get(song.albumId);
    assert.equal(album?.kind, 'album', `song ${song.name} must reference an album`);
    assert.equal(album.artistId, song.artistId, `song ${song.name} artist must match album artist`);
  }
}
for (const assertion of entityGenres) {
  assert.ok(entitiesById.has(assertion.entityId), `genre assertion must reference an entity: ${assertion.entityId}`);
  assert.equal(entitiesById.get(assertion.genreId)?.kind, 'genre', `genre assertion must reference a genre: ${assertion.genreId}`);
}
for (const credit of songCredits) assert.equal(entitiesById.get(credit.songId)?.kind, 'song', `credit must reference a song: ${credit.id}`);
for (const fact of songFacts) assert.equal(entitiesById.get(fact.songId)?.kind, 'song', `fact must reference a song: ${fact.id}`);

for (const like of seedDemoData.likes) {
  assert.ok(profilesById.has(like.profileId), `like must reference a profile: ${like.id}`);
  assert.equal(entitiesById.get(like.entityId)?.kind, like.entityKind, `like kind must match entity: ${like.id}`);
}
for (const entry of seedDemoData.entries) {
  assert.ok(profilesById.has(entry.profileId), `entry must reference a profile: ${entry.id}`);
  assert.equal(entitiesById.get(entry.entityId)?.kind, entry.entityKind, `entry kind must match entity: ${entry.id}`);
  for (const reference of entry.references) {
    assert.equal(entitiesById.get(reference.entityId)?.kind, reference.entityKind, `reference kind must match entity: ${reference.id}`);
  }
}
for (const listen of seedDemoData.listens) {
  assert.ok(profilesById.has(listen.profileId), `listen must reference a profile: ${listen.id}`);
  assert.equal(entitiesById.get(listen.songId)?.kind, 'song', `listen must reference a song: ${listen.id}`);
}
for (const collection of seedDemoData.collections) {
  assert.ok(profilesById.has(collection.profileId), `collection must reference a profile: ${collection.id}`);
  const positions = [...collection.items].sort((a, b) => a.position - b.position).map((item) => item.position);
  assert.deepEqual(positions, positions.map((_, index) => index), `collection positions must be contiguous: ${collection.id}`);
  assertUnique(collection.items.map((item) => item.entityId), `collection entities in ${collection.name}`);
  for (const item of collection.items) {
    assert.equal(entitiesById.get(item.entityId)?.kind, item.entityKind, `collection item kind must match entity: ${item.id}`);
  }
}
for (const pin of seedDemoData.pins) {
  assert.ok(profilesById.has(pin.profileId), `pin must reference a profile: ${pin.id}`);
  const targetExists = pin.targetType === 'entity'
    ? entitiesById.has(pin.targetId)
    : pin.targetType === 'entry'
      ? entriesById.has(pin.targetId)
      : collectionsById.has(pin.targetId);
  assert.ok(targetExists, `pin target must exist: ${pin.id}`);
}
for (const assertion of seedDemoData.genreAssertions ?? []) {
  assertUuid(assertion.id, 'user genre assertion id');
  assert.ok(assertion.createdBy && profilesById.has(assertion.createdBy), `user genre assertion must reference a profile: ${assertion.id}`);
  assert.ok(entitiesById.has(assertion.entityId), `user genre assertion must reference an entity: ${assertion.id}`);
  assert.equal(entitiesById.get(assertion.genreId)?.kind, 'genre', `user genre assertion must reference a genre: ${assertion.id}`);
  assert.equal(assertion.source, 'user', `user genre assertion must retain source: ${assertion.id}`);
}
for (const profile of seedDemoData.profiles) {
  if (profile.profileSongId) assert.equal(entitiesById.get(profile.profileSongId)?.kind, 'song', `profile track must be a song: ${profile.handle}`);
  for (const genreId of profile.genreIds) assert.equal(entitiesById.get(genreId)?.kind, 'genre', `profile preference must be a genre: ${profile.handle}`);
}

const d1SchemaSql = fs.readFileSync(path.join(root, 'd1/schema.sql'), 'utf8');
for (const table of [
  'users', 'otp_codes', 'sessions', 'profiles', 'artists', 'albums', 'songs', 'entity_genres',
  'likes', 'journal_entries', 'entry_references', 'listen_logs',
  'collections', 'collection_items', 'profile_pins',
]) {
  assert.match(d1SchemaSql, new RegExp(`create table if not exists ${table}\\s*\\(`), `D1 schema must create ${table}`);
}
assert.match(d1SchemaSql, /unique \(profile_id, entity_id\)/, 'likes must be unique per profile and entity');
assert.match(d1SchemaSql, /unique \(profile_id, target_type, target_id\)/, 'pins must be unique per profile and target');
assert.match(d1SchemaSql, /musicbrainz_release_group_id text unique/, 'albums must key imported release groups');

console.log(`Validated ${allEntities.length} catalog entities, ${seedDemoData.entries.length} journal entries, ${seedDemoData.collections.length} collection, and the Cloudflare D1 schema graph.`);
