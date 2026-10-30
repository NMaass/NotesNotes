# Native client API contract

The iOS app is the backend's only client (the web interface is retired; its cookie
session path remains in the routes but nothing uses it). This document is the contract between `src/app/api/**` and
`ios/Packages/ResonoteKit/Sources/ResonoteKit/Networking/` — change both together.

All bodies are JSON. Errors keep the existing shape `{ ok: false, error: string }`
with a meaningful status (400 malformed, 401 signed out, 403 someone else's row,
404 missing, 409 conflicts with saved data, 429 throttled, 500 server, 502 upstream,
503 no D1 binding). Only 5xx and 429 are worth retrying; every other 4xx means the
request will never succeed as sent. Successful responses may carry extra keys
(`ok`, `services`); clients ignore keys they do not know.

## Authentication

Native clients authenticate with a bearer token instead of the `resonote_session`
cookie. Tokens are ordinary rows in `sessions` (stored as a SHA-256 hash), so
expiry (30 days) and sign-out behave identically for both clients.

| Request | Behavior |
| --- | --- |
| `POST /api/auth/request-code` `{ email }` | Unchanged. Without a mail provider (local dev) the response carries `devCode`. |
| `POST /api/auth/verify` `{ email, code, client: "ios" }` | When `client` is `"ios"`, responds `{ ok, bundle, token, expiresAt }` with `Cache-Control: no-store` and **does not** set the cookie. The token is shown once. Web requests (no `client`) are unchanged: `{ ok, bundle }` plus `Set-Cookie`. A wrong code is 401. Five wrong codes for one email within 10 minutes spend every outstanding code for it and answer 429 until the window passes (requesting a new code does not reset the count; a correct code does). |
| Any route that calls `currentUser()` | Reads `Authorization: Bearer <token>` (via `headers()`), else the cookie. A request that presents a bearer header is judged on that token alone: an invalid or expired token is signed out even if a cookie is also present. |
| `POST /api/auth/signout` | Deletes the bearer session when the header is present (no `Set-Cookie`), otherwise the cookie session (and clears the cookie). |
| `GET /api/auth/session` | Works with either credential; returns `{ authenticated, bundle }`. `{ authenticated: false }` means only "no valid session": a missing database answers 503 and a bundle that can't be read answers 500, so the iOS app never mistakes a server hiccup for being signed out (it keeps its journal and queued writes until the same person signs in again). |

## Private first: bundles and the published flag

Entries, collections, listens, and likes belong to their owner (`docs/ARCHITECTURE.md`).
Other people see only what the owner published.

**`published`** (boolean) on `JournalEntry` and `Collection`. `false` means private:
only the owner's bundle carries the row. On writes (`entry`, `collection` sync ops) the
server stores `published === true` and treats a missing or non-boolean `published` as
`false`; the legacy `public` key is **ignored on writes**, so a build that predates the
flag (which sent `public: true` by default) can no longer publish by accident. It is
stored in the existing `is_public` column. Every response that carries an entry or a
collection sends both `published` and the legacy `public` with the same value, so
builds that only read `public` keep showing the right state. Clients read `published`,
else `public`, else `false`.

| Response | Entries and collections | `likes` | `listens` |
| --- | --- | --- | --- |
| Owner bundle (`GET /api/auth/session`, `POST /api/auth/verify`) | all of the owner's, published or not | the owner's | the owner's |
| Public bundle (`GET /api/profiles/:handle`, any caller, the owner included) | published only | `[]` | `[]` |
| `GET /api/feed` | published entries only | — | — |
| `GET /api/catalog/entity` `entries`, `/api/music/resolve` `entriesCount` and lens suggestions | published entries only | — | — |

- A public bundle still carries the profile, pins (only pins on entities and on
  published entries and collections), and the owner's genre assertions (attributed tags
  are public by design). `likes` and `listens` are present as empty arrays so older
  builds decode; its `catalog` references nothing that only a like or a listen needed.
- Publishing and unpublishing are ordinary `entry` / `collection` writes with the whole
  object and the new `published` value. Unpublishing removes the row from every public
  surface at once; pins on it stay in the owner's bundle and reappear if it is published
  again.
- The owner's own unpublished entries never come back from `/api/feed` or
  `/api/catalog/entity`; the app shows them from its bundle (an entity page merges the
  owner's entries about the entity in locally).
- No follow graph and no activity notifications exist. Report and block apply to
  published writing (nothing else of another person's is ever visible).

**Existing rows** (`d1/migrations/0005_private_first.sql`): every entry and collection
written before this contract is **unpublished once** (`is_public = 0`). They were written
when the app's visibility toggle defaulted to public, so most were never a choice to
publish; under private first, a default is not consent. Nothing is lost: the owner's
bundle still has every row, marked private, and publishing again is one tap. The
migration records itself in `migration_markers` (`name = '0005_private_first'`) and only
unpublishes while that marker is absent, so re-running it never unpublishes something
published afterwards. New tables default `is_public` to `0` (`d1/schema.sql`).

### Catalog slices

Every `catalog: CatalogSlice` in a response (`session`, `verify`,
`GET /api/profiles/:handle`, `/api/feed`, `/api/catalog/entity`) carries **every**
catalog row the payload references, seeded (code, `src/lib/data/catalog.ts`) and
D1 alike, because the app keeps no copy of the seed catalog. `genres` is always
present. Referenced means:

- likes (own bundle only: public bundles carry no likes); entries, their subjects, and
  their inline references; collection items; the profile song and the profile's `genreIds`;
- listens' song ids (own bundle only: public bundles carry no listens);
- pinned entities (`targetType: "entity"`; the kind is looked up);
- genre assertions: their entities and their genres.

Each song brings its album and artist; each album brings its artist. The web
registers only the non-seed rows (it has the seed catalog in code).

## Writes: `POST /api/sync`

Ops: `like`, `genre-assertion`, `entry`, `delete-entry`, `listen`, `collection`,
`delete-collection`, `pin`, `profile`. `entry` and `collection` replace their child
rows in one D1 batch (atomic).

**Every op is safe to resend.** The outbox retries after timeouts and lost
responses, so a write that already landed must succeed again without changing
anything, and a write the server will never accept must answer 4xx (not 5xx,
which the outbox retries forever).

| op | Payload | Resent / conflict behavior |
| --- | --- | --- |
| `like` | `{ id, entityId, entityKind, clientVersion, liked }` | Upsert per (person, entity); unliking something not liked is a no-op. |
| `genre-assertion` | `{ entityId, entityKind, genreId, asserted }` | One row per (person, entity, genre), enforced by the `entity_genres_user_uq` index: a resent assertion never adds a vote. Retracting one that is gone is a no-op. Accepts any genre id the API hands out, including D1 genres (`mb-genre-<mbid>`) from resolve suggestions. |
| `entry` | `{ entry }` | Upsert by id; `entry.published` (boolean, missing = `false`) sets visibility, `entry.public` is ignored. 400 without an `entry.id`. 403 `That entry belongs to another account.` when the id is someone else's. `createdAt` and `updatedAt` are stored as ISO-8601 UTC and never later than the server's clock (a future time is clamped to now, an unreadable one becomes now, and `createdAt` is never after `updatedAt`), because the feed, entity pages, and feed cursors order by them. |
| `delete-entry` | `{ id }` | Deletes the caller's entry, its `entry_references`, and every pin targeting it, in one batch. An id that does not exist (already deleted, or never synced) is `{ ok: true }`. 404 `Entry not found.` only when the entry exists and is someone else's (its existence is not revealed). 400 without an id. |
| `listen` | `{ listen }` | Upsert by id: a resent listen is a no-op success (an edited one updates its moods, note, song, and time). 400 without `songId`/`listenedAt`. 403 when the id is someone else's listen. |
| `collection` | `{ collection }` | Upsert by id; `collection.published` as for entries. 400 without an id. 403 `That collection belongs to another account.` 409 `You already have a collection with that name.` when another of the caller's collections has the same slug. |
| `delete-collection` | `{ id }` | As `delete-entry`: gone is `{ ok: true }`; 404 `Collection not found.` only for someone else's. |
| `pin` | `{ targetType, targetId, position, pinned }` | Upsert per (person, target); unpinning something not pinned is a no-op. |
| `profile` | `{ profile }` | Overwrites the caller's profile fields. |

Any other constraint failure is 409 `That change conflicts with something already saved.`

## Reads

### `GET /api/catalog/search?q=&limit=20`

Searches the code-seeded catalog (`src/lib/data/catalog.ts`, with the web's aliases
such as "mbv") **and** every D1 artist/album/song/genre. Ranking matches the web's
local search on NFKD-normalized text: exact 100 > prefix 70 > contains 40, then name.
D1 is read in up to two passes: names starting with the query, through the
`*_name_nocase_idx` indexes; then, only when fewer than `limit` results score
"prefix" or better, a scan for names containing it. Every LIKE pattern stays within
D1's 50-byte limit (long queries keep their leading words and are re-checked in
JS), so a query of any length (the route caps it at 200 characters) answers 200.
A D1 row with the same MusicBrainz id (and kind) as a seeded row is dropped in favor
of the seeded row; so is a D1 song or album with the same title by the same artist
(seeded songs carry no recording id, so a re-imported "Lithium" is recognized by
artist MusicBrainz id + title). Subtitles match the web: `country · Artist`, `artist · year`,
`artist · album`, `Genre`. `limit` defaults to 20 (max 50); an empty `q` returns
`[]`. Response: `{ results: SearchResult[] }` with `source: "local"`, one complete batch.

### `GET /api/catalog/entity?kind=&id=`

Everything one entity screen needs, in one round trip. Works for seeded ids and D1 ids
(`mb-artist-*`, `mb-album-*`, `mb-song-*`, `mb-genre-*`). 400 for an unknown `kind`;
404 `{ ok: false, error: 'Not found.' }` when the id does not exist.

```ts
{
  ok: true,
  entity: CatalogEntity,
  artist?: Artist,            // the album's/song's artist
  album?: Album,              // the song's album
  albums: Album[],            // artist: their albums · album: the artist's other albums · genre: albums tagged with it
  tracks: Song[],             // album: tracklist by track number · song: its album's tracklist · artist: their songs · genre: tagged songs
  genres: Array<{ genre: Genre, source: 'catalog'|'community'|'user', votes: number, mine?: boolean }>,
  credits: SongCredit[],      // seed catalog only, today
  facts: SongFact[],
  entries: JournalEntry[],    // published entries about this entity, newest first (max 50)
  authors: Profile[],         // profiles for `entries`
  connections: Array<{ entity: CatalogEntity, count: number, lenses: MusicLens[], relations: RelationKind[] }>,
  catalog: CatalogSlice,      // seeded and D1 rows referenced by `entries` and `connections`
  tagCount?: number           // genre entities only (see below)
}
```

- `genres` mirrors the web's `getGenresForEntity`: seeded catalog/community rows bring
  their votes, every listener (`user`) tag counts one, and the source shown is
  community > user > catalog. Not set for genre entities.
- `mine` is present (true/false) only when the request is authenticated.
- A seeded artist or album that was also imported from MusicBrainz
  (`mb-artist-<mbid>` / `mb-album-<mbid>`) shows the imported albums/tracks too,
  seeded rows first, duplicates (same MusicBrainz id or title) removed.
- `connections` come only from references writers placed in these entries, most-referenced first.
- `tagCount` (genre entities only) is how many times anyone tagged the genre, counted
  as the web's genre page does (`getGenreTagCount`): every listener tag counts one,
  a seeded catalog/community row counts its votes (one when it has none).

### `GET /api/catalog/genres`

`{ genres: Genre[] }` — seeded genres (in catalog order) plus genres stored in D1, by name.

### `GET /api/feed?limit=30&before=<nextCursor>`

Recent published entries across everyone, newest first by `updated_at` (validated and
clamped by the server on every write, so no client can place an entry ahead of the
present), then `id`.
`{ ok, entries: JournalEntry[], profiles: Profile[], catalog: CatalogSlice, nextCursor?: string }`.
`nextCursor` is present when a full page was returned; it is opaque (base64url of
the last entry's `updated_at` and `id`), so entries sharing a timestamp are never
skipped or repeated across pages. Pass it back unchanged as `before`. A bare
`updatedAt` timestamp is still accepted (pages by time only); anything else is a
400. `limit` defaults to 30 (max 50). Seeded demo profiles' entries are demo-only
and never appear.

### `POST /api/music/resolve` (requires auth; 401 otherwise)

Maps whatever someone is listening to onto a permanent catalog song, importing it
from MusicBrainz when the match is certain, and returns writing suggestions.

Request — one of (when both are sent, `track` wins):

```ts
{ track: NowPlayingTrack }   // from Apple Music, Spotify, Last.fm, ListenBrainz, Shazam
{ url: string }              // a shared Spotify / Apple Music / YouTube Music / YouTube / song.link URL
```

```ts
type NowPlayingTrack = {
  title: string; artist: string; album?: string; durationMs?: number; artworkURL?: string;
  isrc?: string; mbid?: string; spotifyId?: string; appleMusicId?: string; youtubeId?: string;
  url?: string;
  source: 'apple-music'|'spotify'|'lastfm'|'listenbrainz'|'shazam'|'link'|'manual';
  isPlaying: boolean; observedAt: string;
};
```

A track needs `title` and `artist`, unless it carries an `mbid` or `isrc` (then both
may be empty strings and are filled from the match). Malformed optional fields (a bad
ISRC, mbid, provider id, or non-http URL) are dropped rather than rejected.

**Links.** Recognized: `open.spotify.com/track/<id>` (also `/intl-xx/`, `/embed/`,
`spotify:track:<id>`), `music.apple.com/.../song/.../<id>` and `/album/...?i=<id>`,
`music.youtube.com/watch?v=`, `youtube.com/watch?v=` / `shorts` / `embed`,
`youtu.be/<id>`, and `song.link` (short forms `/s/`, `/i/`, `/y/`, an embedded
provider URL, or any other page). Album, playlist, artist, and `album.link` links are
400. The canonical URL is the cache key; YouTube and YouTube Music share one.
Odesli's public API now returns `401 PUBLIC_API_ACCESS_DEPRECATED` (verified
2026-10-24), so it is used only when `ODESLI_API_KEY` is set. By default a link is
read from the provider: Spotify's embed page data (title, all artists, duration,
artwork; oEmbed as a title-only fallback), the iTunes lookup API for Apple Music,
YouTube oEmbed ("Artist - Title (Official Video)" and "Artist - Topic" channels are
split), and song.link's page data. A link no provider can read is a 502. A link that
resolved before needs no provider round trip.

**Resolution order** (identifiers before text, local before MusicBrainz):

1. `track_resolutions` rows for the track's identifier keys (`mbid:` › `isrc:` › `url:`).
   A row is reused only if it is plausible for what the source reported: an id-only
   track always is; otherwise the title or the artist must agree with the cached song
   (titles may extend one another, any credited artist may match).
2. A D1 song with the track's MusicBrainz recording id → `exact`.
3. The `text:` row, if the cached song's length is within 15 s of the track's (when both are known) → `strong`.
4. Normalized artist + title (the same folding as `TrackText.swift`; durations within
   15 s when both are known) against the seed catalog, then D1. Seed rows win → `strong`.
   A D1 error here is logged and resolution continues on MusicBrainz.
5. MusicBrainz recording id: a seeded song by the recording's credited artist or on one
   of its release groups (seed songs carry no recording ids), a same-titled track on an
   album already in D1, or an import → `exact`.
6. ISRC, through the recording search (`isrc:<ISRC>`, which carries releases; the
   `/ws/2/isrc` lookup's JSON omits them and is only the fallback). With a title, the
   recording that best fits title/artist/duration; without one, the canonical recording:
   most releases, then a studio-album release over a compilation, then earliest → as 5, `exact`.
7. Fielded recording search `recording:"…" AND artist:"…" AND status:official AND NOT secondarytype:live`.
   With a duration, `AND dur:[d-5000 TO d+5000]` is tried first (popular titles have
   dozens of same-scored compilation and DJ-mix recordings; "One More Time" by Daft
   Punk has 74 and the Discovery recording is not in the first 25). Without a strong
   hit there, the open query reads up to 100 recordings. Candidates are scored by
   normalized title/artist equality, duration (±5 s strong, ±15 s ok), version
   markers in the disambiguation, release count, and the best release's type.
   `NOT secondarytype:compilation` is deliberately not used: the recording index
   matches *any* release, so it hides every studio recording that was ever
   anthologized (verified live with "Lithium"). When the search finds nothing, a
   second query tries every credited artist with a recording of about the same length
   (Spotify often lists the composer first). A strong best match is imported →
   `strong`; otherwise `weak` with candidates.

**What is cached.** Only keys the server verified, each at its own confidence:

- `mbid:<recording>` (`exact`) when MusicBrainz resolved that recording id to the song
  (paths 2, 5, 6, and 7's chosen recording);
- `isrc:<ISRC>` (`exact`) when MusicBrainz listed the recording under that ISRC (path 6);
- `url:<link>` only from `{ url }` requests, where the server read the provider's own
  metadata, at the match's confidence;
- `text:<artist>|<title>` (at most `strong`, never `exact`) when the track's own title
  and artist name the matched song.

Ids a client sends in `{ track }` (`spotifyId`, `youtubeId`, `appleMusicId`, an `mbid`
or `isrc` that played no part in the match) are never cached. A weaker row never
overwrites an `exact` one. A cache hit writes nothing new, except the `url:` key of
a `{ url }` request whose metadata matched a cached row.

**Provider ids on songs.** An imported (non-seed) song stores a Spotify / YouTube id
only from a `{ url }` request, only for an id the server read itself (the link's own
Spotify id, ids from song.link page data, or a YouTube id whose oEmbed author is an
auto-generated "Artist - Topic" channel), only when the match is `exact` or `strong`
with lengths within 5 s, and never over an id already set. A client-sent track
never changes a shared song row.

**Imports** reuse `resolveImport` / `upsertImportedCatalog` (the `/api/music/import`
path), written in one D1 batch with slugs chosen against the stored rows. A song
import costs two MusicBrainz requests: the recording (with release groups and genres)
and one release that contains it (the most canonical: official studio album over
single, compilation, or live). Each track is credited to its own artist; the
requested recording always to the recording's artist, never a release's "Various
Artists". From an anthology (a compilation, DJ mix, or Various Artists release) only
the requested track is imported, not its neighbours. In `bundle.songs` the requested
song comes first, and `bundle.focusId` names it (it can be a same-titled track of
another pressing when that album is already stored).

MusicBrainz work is bounded: ~17 s of budget per request, served
earliest-deadline-first across concurrent requests, so the response arrives within
~20 s. When the budget runs out the response is `weak` with the recordings seen so far,
or `none`.

Response:

```ts
{
  ok: true,
  track?: NowPlayingTrack,           // echoed; gaps filled from the match (title/artist for id-only
                                     // tracks, album, artworkURL = album cover when the source had none)
  song?: Song, album?: Album, artist?: Artist,   // present for exact/strong
  confidence: 'exact'|'strong'|'weak'|'none',
  candidates: SearchResult[],        // weak/none only, max 5, ids `mb-song-<mbid>`,
                                     // subtitle 'Artist · Album · MusicBrainz'; import the chosen one
  suggestions: {
    genres: Array<{ id: string, name: string, source: 'catalog'|'community'|'user'|'musicbrainz' }>,  // ≤ 4, assertable ids
    lenses: MusicLens[],             // 4
    moods: string[],                 // 8
    prompt: string
  },
  entriesCount: number               // published entries about the song
}
```

Suggestions never expose another person's private data:

- **genres**: tags on the song, then its album, then its artist (seeded + D1, by votes),
  then MusicBrainz community genres (recording, then release group, then artist),
  mapped onto a seeded genre with the same name, a D1 genre with the same MusicBrainz id,
  or a new D1 genre. MusicBrainz is asked once per entity; the mapped ids are
  remembered in `entity_musicbrainz_genres`. An entity without a remembered row (an
  earlier attempt ran out of time or hit a MusicBrainz error) is asked again on a
  later resolution; on a cached resolution that lookup gets at most 4 s.
- **lenses**: most frequent on published entries about the song/album/artist, padded with
  `feeling, production, lyrics, context`.
- **moods**: the caller's own listen moods only (this song's listens count three times),
  padded with the standard eight.
- **prompt**: "What did you notice this time?" if the caller has written about the song,
  "What does this take you back to?" if they have logged a listen but not written,
  otherwise a stable pick (hash of the song id) from the web editor's prompts after the first two.

### `GET /api/now-playing?lastfm=&listenbrainz=&resolve=1&before=` (requires auth)

What the caller is playing and recently played, across their scrobbling accounts.

**Accounts.** Last.fm: the account linked through web auth (see Linked accounts) when
there is one, else the `lastfm` parameter. ListenBrainz: the `listenbrainz` parameter.
Neither → 400 `Link a Last.fm or ListenBrainz username first.` Last.fm names must start
with a letter (`[A-Za-z0-9_-]`, ≤ 64). ListenBrainz (MusicBrainz) names may contain any
printable character, including `@` and spaces, except `/`; control and format
characters, surrounding whitespace, and the names `.` and `..` are refused (≤ 64). The
name is percent-encoded into the API path. Both services are asked concurrently with a
4 s timeout each.

- Last.fm `user.getRecentTracks` (`limit=10`) with the server-held `LASTFM_API_KEY`;
  skipped (status `not-configured`) when the key is unset. For a linked account the
  request is signed with its session key, so a profile that hides recent tracks still
  answers. When Last.fm refuses that key (error 9: the person revoked Resonote at
  last.fm), the public profile is read unsigned instead and the stale link is deleted,
  so `GET /api/account/lastfm` reports it unlinked and the app offers to sign in again.
- ListenBrainz `playing-now` and `listens?count=10`.

**`before`** (optional, ISO-8601): history instead of now. `recent` holds up to 10 plays
that started before that moment, newest first (Last.fm `to=`, ListenBrainz
`listens?max_ts=`, no playing rows), and `track` is `null`. Write first, attach later
uses it for a waiting note older than the newest 10 plays reach. An unreadable value →
400 `before must be an ISO-8601 time.`

**`track`** (unchanged): the actively playing track, else the freshest play that finished
within the last 10 minutes (`isPlaying: false`), else `null`.

**`recent`**: up to 10 plays, newest first, merged across both services and **not**
limited to 10 minutes. Each is a `NowPlayingTrack` whose `observedAt` is when it was
played (Last.fm `date.uts`, ListenBrainz `listened_at`) or, for the playing row, when the
service was sampled.

- At most one row has `isPlaying: true`, and it is first: a live source promotes one row.
  When both services report something playing, the one sampled most recently wins and the
  other is dropped if it is the same song, else kept as an ordinary row.
- Two rows from different services are the same play when their `TrackText` keys
  (normalized artist + title, `src/lib/music/text.ts`) or ISRCs match and they are both
  playing or less than 10 minutes apart. One service never reports a play twice, so
  repeat listens of a song from one service stay separate rows. The kept row is the playing one, else the newer; it takes identifiers
  (`mbid`, `isrc`, provider ids, `artworkURL`, `album`, `durationMs`) only the other had.
- A service that answers with nothing contributes nothing; `recent` is `[]` when nothing
  answered.

With `resolve=1` the response also carries the `/api/music/resolve` result for `track`
(only), and arrives only once that finishes (a song Resonote hasn't seen can take 5–15 s).
The widget and its refresh button work within 5–8 s, so they ask without `resolve` (well
under a second), adopt the track, and resolve it separately with the time left.

```ts
{ ok: true, track: NowPlayingTrack | null, recent: NowPlayingTrack[], resolution?: ResolveResponse,
  services: Array<{ service: 'lastfm'|'listenbrainz', status: 'ok'|'unavailable'|'not-configured' }> }
```

```json
{
  "ok": true,
  "track": { "title": "Weird Fishes/Arpeggi", "artist": "Radiohead", "album": "In Rainbows",
             "source": "lastfm", "isPlaying": true, "observedAt": "2026-10-29T12:00:04.120Z" },
  "recent": [
    { "title": "Weird Fishes/Arpeggi", "artist": "Radiohead", "album": "In Rainbows",
      "source": "lastfm", "isPlaying": true, "observedAt": "2026-10-29T12:00:04.120Z" },
    { "title": "Nude", "artist": "Radiohead", "album": "In Rainbows", "durationMs": 255000,
      "mbid": "…", "isrc": "GBSTK0700002", "source": "listenbrainz", "isPlaying": false,
      "observedAt": "2026-10-29T11:55:41.000Z" }
  ],
  "services": [ { "service": "lastfm", "status": "ok" }, { "service": "listenbrainz", "status": "ok" } ]
}
```

On the phone, `RemoteNowPlayingResponse.recentPlays` maps `recent` (or `track`, from a
server without the list) to `RecentPlay`, and `RecentPlayList.rank` merges them with the
device's own sources (Journaling Suggestions, Apple Music recently played, library
`lastPlayedDate`, the Music app, Shazam, links) and picks the one to pre-select.

## Linked accounts: Last.fm web auth (requires auth)

The person approves Resonote on last.fm instead of typing a username. The server holds
`LASTFM_API_KEY` and `LASTFM_SHARED_SECRET`, signs `auth.getSession`, and stores the
username and session key in `linked_accounts`. **The session key never leaves the
server.** Each route answers 401 when signed out and 503 without D1.

| Request | Behavior |
| --- | --- |
| `GET /api/account/lastfm` | `{ ok: true, configured: boolean, account: { username, linkedAt } \| null }`. `configured` is false when either Last.fm secret is unset. |
| `GET /api/account/lastfm/auth-url` | `{ ok: true, url, callbackScheme: "resonote" }` where `url` is `https://www.last.fm/api/auth/?api_key=<key>&cb=resonote%3A%2F%2Flastfm-auth`. 501 `Last.fm sign-in is not set up on this server.` when not configured. |
| `POST /api/account/lastfm/session` `{ token }` | `token` is 32 ASCII letters and digits, else 400 `That is not a Last.fm sign-in.` Calls `auth.getSession` (`api_sig` = MD5 of `api_key<key>methodauth.getSessiontoken<token><secret>`), then upserts `(profile_id, 'lastfm') → username, session_key, linked_at` (relinking replaces it). `{ ok: true, account: { username, linkedAt } }`. Last.fm refusing the token (errors 4, 14, 15: invalid, unapproved, expired) → 400 `Last.fm did not accept that sign-in. Try again.`; Last.fm unreachable or any other Last.fm error → 502. 501 when not configured. A token works once, so a resent request is a 400, never a duplicate link. |
| `DELETE /api/account/lastfm` | Deletes the caller's Last.fm link. `{ ok: true }`; idempotent. |

The app opens `url` in `ASWebAuthenticationSession` with `callbackScheme`; Last.fm
redirects to `resonote://lastfm-auth?token=<token>` (`LastfmAuth.token(fromCallback:)`).
`DELETE /api/account` also deletes `linked_accounts` rows. `GET /api/now-playing`
uses the link as described above.

## Genres

Genre ids used to exist only in code. To make MusicBrainz community genres
assertable, D1 has a `genres` table. Seeded genres keep their ids and are never
copied. A MusicBrainz genre is inserted once, keyed by `musicbrainz_id`, with id
`mb-genre-<mbid>`, a sentence-case name ("Baroque pop"), and a unique slug.
Bundles include referenced D1 genres in `catalog.genres`; the web registers them so
genre chips, tag counts, and `/genre/<slug>` render for genres tagged from the phone.

## Schema additions

See `d1/migrations/0002_native_client.sql` (mirrored in `d1/schema.sql`). Additive and
idempotent: `genres`, `track_resolutions`, `entity_musicbrainz_genres`,
`login_failures`; indexes for the feed, entity entry lookups, genre lookups, per-song
listens, pin cleanup, and NOCASE name indexes for search; and the unique
`entity_genres_user_uq` index (one assertion per person, entity, and genre; earlier
duplicates are deleted first, keeping the oldest). It also caps any `text:` cache row
at `strong`. Rows the first resolver version cached from unverified client ids cannot
be told apart afterwards; `track_resolutions` is a cache, so an environment that ran
that version can simply be emptied (`delete from track_resolutions`).

### Private first and linked accounts

`d1/migrations/0005_private_first.sql` (mirrored in `d1/schema.sql`):

```sql
create table if not exists migration_markers (name text primary key, applied_at text not null default (datetime('now')));
update journal_entries set is_public = 0 where not exists (select 1 from migration_markers where name = '0005_private_first');
update collections set is_public = 0 where not exists (select 1 from migration_markers where name = '0005_private_first');
insert or ignore into migration_markers (name) values ('0005_private_first');
create table if not exists linked_accounts (
  profile_id text not null references profiles(id) on delete cascade,
  service text not null check (service in ('lastfm')),
  username text not null,
  session_key text not null,
  linked_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  primary key (profile_id, service)
);
```

In `d1/schema.sql`, `journal_entries.is_public` and `collections.is_public` default to `0`.

### Entry timestamps

`d1/migrations/0004_entry_timestamps.sql` (mirrored in `d1/schema.sql`) brings rows written
before the server validated entry timestamps into line: a future or unreadable `updated_at`
becomes now, `created_at` is never after `updated_at`, and both take one ISO-8601 UTC format
so that text order is time order. Idempotent.

## Account and safety

App Store guidelines 5.1.1(v) (in-app account deletion) and 1.2 (user-generated
content: report, block, terms, contact). Tables: `d1/migrations/0003_account_and_safety.sql`
(`content_reports`, `profile_blocks`; mirror them in `d1/schema.sql`). Each route answers 401
when signed out and 503 without D1.

| Request | Behavior |
| --- | --- |
| `DELETE /api/account` | Deletes the caller's entries (and their references), listens, likes, collections (and items), pins (and other people's pins of their entries and collections), genre assertions, reports and blocks, linked accounts, profile, every session, sign-in codes, and user row, in one D1 batch. `{ ok: true }`; also clears a web session cookie. |
| `POST /api/moderation/reports` `{ targetType: 'entry'\|'profile', targetId, reason: 'spam'\|'harassment'\|'hate'\|'sexual'\|'other' }` | Stores a report for review; reporting the same target again keeps one row (the newest reason). 400 for anything else. |
| `GET /api/moderation/blocks` | `{ ok: true, profiles: Profile[] }`, the people the caller blocked. Clients hide their writing in the feed, on entity pages, on their profile, and on entry pages. |
| `POST /api/moderation/blocks` `{ profileId }` | Blocks; idempotent. 400 for yourself. |
| `DELETE /api/moderation/blocks?profileId=` | Unblocks; idempotent. |

The site serves `/privacy` and `/terms`, which the app links from sign-in and Settings.
Set `RESONOTE_CONTACT_EMAIL` so both pages show a contact address.
