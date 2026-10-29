# NotesNotes

**A private journal for close listening, as an iPhone app.** Write about what music evokes, how it is made, and what it reminds you of—without reducing it to a rating. Entries are yours by default; publish one only when you want it read. There is no feed to keep up with and no follower count.

NotesNotes (code name Resonote) is a native SwiftUI app for iOS 26 backed by a Cloudflare Worker and D1 database in this repository. The earlier Next.js web interface is retired; `src/` now exists for the API routes and server-side music code the app calls.

## Repository layout

| Path | What it is |
| --- | --- |
| `ios/` | The iPhone app, its widgets, Controls, share extension, and the `ResonoteKit` package. Start with [`ios/README.md`](ios/README.md). |
| `src/app/api/` | The backend: auth, sync, catalog, feed, now-playing, resolve, moderation. Contract in [`docs/IOS_API.md`](docs/IOS_API.md). |
| `src/lib/` | Server-side music code: MusicBrainz adapter, link resolution, scrobble mapping, D1 access. |
| `d1/` | Schema and migrations. |
| `docs/` | Setup, credentials, architecture, API contract, now-playing research. |

## What the app does

- Opens on your own recent listening (Apple Music, scrobbled Spotify through Last.fm or ListenBrainz, the Journaling Suggestions picker, Shazam, shared links) and asks whether you want to write about a song. Nobody types a song name. See [`docs/IOS_NOW_PLAYING.md`](docs/IOS_NOW_PLAYING.md).
- Rating-free journal entries with freeform writing, optional reflections, lenses, and rerollable prompts.
- Explicit `\` music references in prose. The writer picks the exact artist, album, song, or genre; prose is never silently autolinked.
- Per-reference relationship and lens chips such as “reminds me of” and “production,” stored as queryable data.
- Human-authored music connections derived from your own references, never “users also liked” logic.
- A private listening log with moods, and freeform collections that mix artists, albums, songs, and genres.
- Song credits, structural facts, source/confidence labels, and explainable collaborator observations.
- A profile page that shows only what you chose to publish; report and block for anything public; account deletion.
- Home Screen and Lock Screen widgets, Action button Controls, App Shortcuts, and a share extension.
- Durable offline sync: every write is queued on the phone until the server confirms it.

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

MusicBrainz **release groups** are the product-level album identity. Exact pressings and editions sit below the journaling UI.

## Running it

The app needs the backend. Deploy it once (see [`docs/SETUP_CHECKLIST.md`](docs/SETUP_CHECKLIST.md)), then open `ios/Resonote.xcodeproj` and run on an iPhone; the simulator has no Music app and no useful microphone.

```bash
npm install
npm run typecheck      # backend TypeScript
npm run lint
npm test               # Vitest (server-side music code)
npm run validate:data
npm run cf:preview     # Cloudflare local preview of the Worker
npm run cf:deploy      # deploy the Worker
npm run check:env      # print missing optional variables
ios/scripts/typecheck.sh all   # iOS targets, no Xcode needed
ios/scripts/test-kit.sh        # ResonoteKit tests
```

## Setup and architecture

- [`docs/SETUP_CHECKLIST.md`](docs/SETUP_CHECKLIST.md) — backend and iOS first run
- [`docs/API_KEYS.md`](docs/API_KEYS.md) — credentials the backend needs
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — data model and backend
- [`docs/IOS_API.md`](docs/IOS_API.md) — native client API contract
- [`docs/IOS_NOW_PLAYING.md`](docs/IOS_NOW_PLAYING.md) — how the app knows what you listened to
- [`ios/ARCHITECTURE.md`](ios/ARCHITECTURE.md) — the app itself
- [`BUILD_REPORT.md`](BUILD_REPORT.md) — historical report on the retired web MVP
- [`docs/PLANS.md`](docs/PLANS.md) — what the docs promise that the code does not do yet, in order

## Stack

SwiftUI · Swift 6 · WidgetKit · App Intents · ShazamKit · MusicKit · Cloudflare Workers · D1 · MusicBrainz
