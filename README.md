# Resonote

**A public journal for close listening.** Write about what music evokes, how it is made, and what it reminds you of—without reducing it to a rating.

Resonote is a production-shaped MVP built with Next.js, React, TypeScript, Tiptap, Radix, Zustand, MusicBrainz, and an all-Cloudflare data plane (Workers + D1).

## Start with no accounts or API keys

```bash
npm install
cp .env.example .env.local
npm run dev
```

Open `http://localhost:3000`.

The default `NEXT_PUBLIC_DATA_MODE=demo` stores the catalog and anything you create in browser storage under `resonote-demo-v1`. When the app asks for a one-time code, enter:

```text
000000
```

No email is sent in demo mode.

## What is implemented

- Mobile-first home, artist, release-group album, recording, genre, profile, journal, listening-log, and collection surfaces.
- Artist, album, and song likes. Profile accordions preserve the distinction between liking an album and liking one track from it.
- Rating-free journal entries with a large freeform editor, optional “worked for me” and “did not work for me” reflections, lenses, and rerollable prompts.
- Explicit `\` music references in Tiptap. The writer resolves the exact artist, album, song, or genre; Resonote never silently autolinks prose.
- Per-reference relationship and lens chips such as “reminds me of” and “production.” These remain queryable data rather than decorative text.
- Desktop hover previews plus ordinary links that remain usable by touch and keyboard.
- Human-authored music connections derived from journal references, not “users also liked” recommendation logic.
- Manual listen logging with moods. A person’s listening timeline is private to that signed-in person.
- Freeform “spiritually similar” collections with mixed artists, albums, songs, and genres.
- Personal genre assertions. Catalog, community, and user sources remain distinct in storage.
- Song credits and structural facts behind deliberate disclosure, including source/confidence labels.
- Explainable collaborator observations. A pattern appears only when one collaborator occurs on at least two liked songs across at least two artists.
- Profile pins and a profile track.
- Persistent YouTube and Spotify iframe playback. Play/pause does not key-remount the active player.
- Local-first search plus a throttled, server-side MusicBrainz search adapter.
- Passwordless email-OTP accounts with server-side sessions, a Cloudflare D1 schema for accounts and imports, public-profile loading through API routes, and serialized client synchronization.
- Cloudflare Workers deployment through OpenNext.
- Unit, data-graph, geometry, focus, persistence, reference-insertion, player-lifecycle, and reduced-motion test coverage.

## Product URLs

```text
/music/nirvana
/music/nirvana/nevermind
/music/nirvana/nevermind/lithium
/genre/grunge
/@maya
/@maya/nirvana/nevermind/lithium
/@maya/genre/grunge
/@maya/collections/fluorescent-parking-lots-at-2am
```

Canonical `/music/...` pages show community context. `@handle/...` pages show one person’s relationship to the same music.

## Architecture at a glance

```text
Next.js App Router
├── demo mode: Zustand + localStorage
├── cloud mode: OTP sessions + Cloudflare D1 via /api routes
├── normalized local music catalog
├── server-side MusicBrainz search adapter
├── Cover Art Archive release-group images
├── YouTube iframe playback
└── Spotify iframe playback
```

MusicBrainz **release groups** are the product-level album identity. Exact pressings and editions sit below the primary journaling UI.

## Important MVP boundary

Every item in the seeded catalog has a complete, interactive page and can be liked, journaled, linked, logged, pinned, tagged, played, and collected.

Wider MusicBrainz results also appear in search. A remote result opens a discovery page with an **Import** action. The import worker resolves the artist, release group, full tracklist, and cover art together before creating any pages — no orphan songs, no duplicate album editions, no journal entries attached to unstable temporary identifiers.

In demo mode, imports persist in the importing browser's catalog (shelf, search, journaling). When a D1 database is bound (`wrangler d1`), imports are written into the shared catalog for everyone automatically; see `docs/API_KEYS.md`. Aliases and genre tags are not yet resolved during import.

## Setup

Use the ordered checklist:

- [`docs/SETUP_CHECKLIST.md`](docs/SETUP_CHECKLIST.md)
- [`docs/API_KEYS.md`](docs/API_KEYS.md)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`BUILD_REPORT.md`](BUILD_REPORT.md)

## Commands

```bash
npm run dev          # local Next.js development server
npm run typecheck    # TypeScript
npm run lint         # ESLint
npm test             # Vitest
npm run test:e2e     # Playwright
npm run validate:data
npm run build        # Next.js production build
npm run cf:preview   # Cloudflare local preview
npm run cf:deploy    # Cloudflare deploy
npm run check:env    # print data mode and missing optional variables
```

## Data ownership

Music providers supply catalog metadata and playback. Resonote owns the user-authored layer: journals, explicit references, listens, likes, collections, pins, genre assertions, and explainable observations.

## Working name

“Resonote” is a working product name. This repository does not claim that a matching domain or trademark is available.
