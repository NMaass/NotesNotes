#!/usr/bin/env node
// Grows the shared Resonote catalog from the public ListenBrainz feeds:
//   fresh releases  -> imported as full albums (artist + release group + tracks)
//   trending songs  -> imported as recordings (artist + album context)
// Each target goes through the production import route, so resolution,
// throttling, D1 writes, and slug handling stay identical to manual imports.

const BASE = process.argv.find((arg) => arg.startsWith('--base='))?.slice(7) ?? 'https://resonote.nmaass.dev';
const FRESH = Number(process.argv.find((arg) => arg.startsWith('--fresh='))?.slice(8) ?? 12);
const TRENDING = Number(process.argv.find((arg) => arg.startsWith('--trending='))?.slice(11) ?? 10);
const DELAY_MS = Number(process.argv.find((arg) => arg.startsWith('--delay='))?.slice(8) ?? 4200);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function json(url) {
  const response = await fetch(url, { headers: { Accept: 'application/json' } });
  if (!response.ok) throw new Error(`${url} -> ${response.status}`);
  return response.json();
}

async function importOne(kind, mbid) {
  const response = await fetch(`${BASE}/api/music/import`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ kind, mbid }),
  });
  const body = await response.json().catch(() => ({}) );
  if (!response.ok || !body.ok) throw new Error(body.error ?? `status ${response.status}`);
  return body.bundle;
}

function describe(bundle) {
  const album = bundle.albums[0];
  const artist = bundle.artists[0]?.name ?? '?';
  return album ? `${artist} — ${album.name} (${bundle.songs.length} tracks)` : `${artist} — ${bundle.songs[0]?.name ?? ''}`;
}

const imported = new Set();
let ok = 0;
let failed = 0;

async function runBatch(kind, targets) {
  for (const target of targets) {
    const mbid = String(target.mbid ?? '').toLowerCase();
    if (!/^[0-9a-f-]{36}$/.test(mbid) || imported.has(mbid)) continue;
    imported.add(mbid);
    try {
      const bundle = await importOne(kind, mbid);
      ok += 1;
      console.log(`  + ${describe(bundle)}`);
    } catch (error) {
      failed += 1;
      console.log(`  - skipped ${target.label ?? mbid}: ${error.message}`);
    }
    await sleep(DELAY_MS);
  }
}

console.log(`Seeding ${BASE} — fresh:${FRESH} trending:${TRENDING}`);
const fresh = await json('https://api.listenbrainz.org/1/explore/fresh-releases');
const freshTargets = (fresh.payload?.releases ?? [])
  .filter((release) => release.release_group_mbid && release.release_group_primary_type !== 'Single')
  .slice(0, FRESH)
  .map((release) => ({ mbid: release.release_group_mbid, label: `${release.artist_credit_name} — ${release.release_name}` }));
console.log(`Fresh releases this week: ${freshTargets.length}`);
await runBatch('album', freshTargets);

const trending = await json('https://api.listenbrainz.org/1/stats/sitewide/recordings?count=40&range=week');
const seenRecordings = new Set();
const trendingTargets = (trending.payload?.recordings ?? [])
  .filter((recording) => recording.recording_mbid && !seenRecordings.has(recording.recording_mbid) && seenRecordings.add(recording.recording_mbid))
  .slice(0, TRENDING)
  .map((recording) => ({ mbid: recording.recording_mbid, label: `${recording.artist_name} — ${recording.track_name}` }));
console.log(`Trending this week: ${trendingTargets.length}`);
await runBatch('song', trendingTargets);

console.log(`Done. imported: ${ok}, skipped: ${failed}`);
