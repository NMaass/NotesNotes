# NotesNotes

**A public journal for close listening.** Write about what music evokes, how it is made, and what it reminds you of—without reducing it to a rating.

NotesNotes is a production-shaped music journaling MVP built with Next.js, React, TypeScript, Tiptap, Radix, Zustand, MusicBrainz, and an all-Cloudflare data plane (Workers + D1).

## Start with no accounts or API keys

```bash
npm install
cp .env.example .env.local
npm run dev
```

Open `http://localhost:3000`.

The default `NEXT_PUBLIC_DATA_MODE=demo` stores the catalog and anything you create in browser storage. When the app asks for a one-time code in demo mode, enter:

```text
000000
```

No email is sent in demo mode.

## What is implemented

- Mobile-first artist, album, song, genre, profile, journal, listening-log, and collection surfaces.
- Rating-free journal entries with freeform writing, optional reflections, lenses, and rerollable prompts.
- Explicit `\` music references in Tiptap. The writer resolves the exact artist, album, song, or genre; NotesNotes never silently autolinks prose.
- Per-reference relationship and lens chips such as “reminds me of” and “production,” stored as queryable data.
- Human-authored music connections derived from journal references rather than “users also liked” recommendation logic.
- Manual listen logging with moods and a private listening timeline.
- Freeform collections that can mix artists, albums, songs, and genres.
- Song credits, structural facts, source/confidence labels, and explainable collaborator observations.
- Persistent YouTube and Spotify iframe playback.
- Local-first search plus a throttled server-side MusicBrainz adapter.
- Passwordless email-OTP accounts with server-side sessions and Cloudflare D1 persistence.
- Unit, data-graph, geometry, focus, persistence, reference-insertion, player-lifecycle, and reduced-motion test coverage.

## Product model

NotesNotes treats music metadata and user-authored meaning as separate layers.

```text
MusicBrainz / playback providers
          ↓
normalized music catalog
          ↓
artists · albums · songs · genres
          ↓
user-authored layer
journals · references · listens · likes · collections · pins · assertions
```

MusicBrainz **release groups** are the product-level album identity. Exact pressings and editions sit below the primary journaling UI.

## Import boundary

Every item in the seeded catalog has a complete interactive page and can be liked, journaled, linked, logged, pinned, tagged, played, and collected.

Wider MusicBrainz results appear in search as discovery results. Import resolves the artist, release group, tracklist, and cover art together before creating product pages, avoiding orphan songs, duplicate editions, and journal entries tied to unstable temporary identifiers.

In demo mode, imports persist in the current browser. With Cloudflare D1 configured, imports are written to the shared catalog.

## Setup and architecture

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

## Stack

Next.js · React · TypeScript · Tiptap · Radix UI · Zustand · MusicBrainz · Cloudflare Workers · D1
