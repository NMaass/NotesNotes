# Resonote architecture

> Resonote is an iPhone app on a Cloudflare Worker + D1 backend. This document covers the data model and the backend. The client-side sections that remain (journal document format, stable-interface contracts) describe behaviour the iOS app carries forward; where a passage names the retired web interface (Tiptap, Zustand, localStorage, iframe players), read it as the origin of a format or rule, not as a running surface. The app itself is described in `ios/ARCHITECTURE.md`.

## Product boundary

A catalog provider can establish that a recording exists. It cannot establish what that recording meant to a listener.

The application separates:

1. **Catalog entities** — artist, release-group album, recording/song, genre, aliases, credits, and sourced technical facts.
2. **User meaning** — journal entries, explicit references, listens, likes, collections, pins, profile tracks, and personal genre assertions.
3. **Derived observations** — explainable patterns computed from the user’s own actions, such as one producer appearing across liked songs by different artists.

No star-rating column exists.

## Entity identity

- Artist: MusicBrainz artist when available.
- Album: MusicBrainz release group. Exact pressings are not primary journal objects.
- Song: MusicBrainz recording when available.
- Work/composition: not a first-class public route in the MVP. It can be added later for covers, composition credits, and work-level structure.
- Genre: a descriptive entity. Every catalog, community, and user assertion retains its source.

The demo catalog uses stable UUID-shaped identifiers. External MusicBrainz IDs are separate fields, not primary keys; D1 stores imported catalog rows under their own stable identifiers.

## Journal document and music references

Prose is stored as Tiptap-compatible JSON (the iOS app's `ResonoteKit` rich-text codec reads and writes the same document). A music reference is a structured inline node:

```json
{
  "type": "musicReference",
  "attrs": {
    "referenceId": "c0000000-0000-0000-0000-000000000001",
    "id": "40000000-0000-0000-0000-000000000002",
    "label": "When You Sleep",
    "entityKind": "song",
    "relation": "reminds-me-of",
    "lenses": ["production", "feeling"]
  }
}
```

`referenceId` identifies this particular mention. Two references to the same song can therefore describe different relationships without overwriting each other.

The editor opens entity search only after `\`. Post-writing title suggestions are presented as non-destructive chips. The normalized `entry_references` table makes music-to-music relationships queryable without reparsing document JSON.

## Stable-interface contracts

- Main pages use window scrolling. Dialogs own their own bounded overflow.
- Artwork declares its aspect ratio before any network image arrives.
- Finite labels use stable swap geometry or a fixed-width action contract.
- Prompt alternatives share one grid cell sized for the complete prompt set.
- Dirty editor state is mirrored to localStorage and is never replaced by background data.
- Authentication preserves the initiating intent instead of resetting the page.
- Like, pin, collection, entry, listen, profile, and genre writes are queued per object. Later intent cannot be reversed by an earlier slow response.
- The persisted player always rehydrates paused; the interface never claims remote audio resumed when it did not.
- Player state sits above routes. YouTube receives iframe commands and Spotify uses an embed controller rather than being remounted for every pause/play action.
- Accordions preserve expanded state across refresh/back navigation where the user owns that state.
- Motion represents committed meaning: a record spins only while playing. `prefers-reduced-motion` disables it.

## Search and catalog ingestion

1. Search the normalized local catalog immediately.
2. Debounce an optional server request for wider discovery.
3. Abort obsolete browser requests when the query changes.
4. Queue MusicBrainz requests server-side and supply an identifiable User-Agent.
5. Return each response as a complete result batch so rows do not reorder as individual lookups finish.
6. Prefetch local routes on result focus/hover.

Remote results are not inserted automatically. A future transactional import worker should resolve the artist, release group, recording, aliases, track relationships, and cover art together before exposing a permanent journal target.

## Authentication and privacy

Sign-in is a six-digit email OTP. The iOS app receives a bearer token (rows in `sessions`, 30-day expiry); see `docs/IOS_API.md`. The cookie session exists only for the retired web client. `requireAuth(intent)` preserves the exact user action. A person who starts writing about a song returns to that draft rather than being diverted into onboarding.

Private first. Entries, collections, listens, and likes belong to their owner and are loaded only for the signed-in owner. A profile page shows only what that person chose to publish: published entries and collections, pins, and attributed genre assertions. There is no follow graph and no notification of other people's activity; a cross-person feed, where it exists, is a reading surface of published entries, not the home screen. Private editor drafts never leave the device until publication. Entries and collections carry a `published` flag, private by default; the contract is in `docs/IOS_API.md`.

## User genre assertions

A user genre tag is an `entity_genres` row with:

- `source='user'`;
- `created_by=<profile id>`;
- the exact entity kind and genre ID.

RLS permits a user to create, update, or delete only their own user assertions. Catalog and community assertions remain readable but are not writable through this policy. The UI may combine totals for a light reading surface, but source/provenance remains intact in storage.

## Explainable observations, not recommendations

Collaborator observations are deterministic and evidence-backed. The current rule requires the same collaborator on at least two liked songs by at least two different artists. The UI shows the exact songs supporting the observation.

Journal connection panels are derived only from explicit references that writers placed in their own entries. Resonote does not infer “people who liked this also liked” relationships.

## Data-source confidence

Song facts include source and confidence:

- `catalog` — structured catalog fact;
- `estimated` — audio-analysis output such as archived AcousticBrainz BPM/key;
- `community` — listener annotation or cited editorial source.

The UI does not present an estimated key, tempo, or meter as unquestioned ground truth.

## Data mode

The backend runs in cloud mode only (`NEXT_PUBLIC_DATA_MODE=cloud`): accounts, sessions, and imports live in Cloudflare D1, and private and public bundles load through `/api` routes that authorize against a bearer token (the session cookie path remains for the retired web client). On the phone, optimistic writes update the interface immediately and a durable per-object outbox serializes synchronization; see `ios/ARCHITECTURE.md`. The browser-local demo mode of the web MVP no longer exists.

## Deployment

OpenNext builds the API routes for Cloudflare Workers with `nodejs_compat`. D1 is the managed datastore; authorization lives in the route handlers rather than SQL policies. MusicBrainz, Last.fm, ListenBrainz, and link providers are called only from route handlers, never from the phone.
