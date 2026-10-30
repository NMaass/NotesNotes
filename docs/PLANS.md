# Plans

What the docs describe that the code does not yet do, in the order it should land.
Each item names where the detail lives. Dated 2026-10-29. Items 2 and 3 have landed; each lists what remains.

## 1. Retire the web interface in code

The docs already call the Next.js interface retired; `src/` still ships it.

- Delete the web pages and components under `src/app` (everything except `src/app/api`, the privacy and terms pages, and whatever the API routes import from `src/components` or `src/lib`).
- Remove the browser-local demo mode (`NEXT_PUBLIC_DATA_MODE=demo`), the Zustand store, the Tiptap editor, the persistent player, and the Playwright e2e suite that drives them. Keep `src/lib` server-side music code and its Vitest tests.
- Keep the cookie session path only as long as removing it is risky; nothing uses it once the web client is gone (`docs/IOS_API.md`).
- Update `package.json` scripts and `.github/workflows/ci.yml` to the commands in `README.md`.

## 2. Private first: align the API with the docs — done

Landed 2026-10-29; the contract is in `docs/IOS_API.md`.

- Entries and collections carry `published` (stored in `is_public`), private by default. The server publishes only on `published: true` and ignores the legacy `public` key on writes. The feed, entity pages, resolve counts, and public profiles show published rows only.
- Public profile bundles (`GET /api/profiles/:handle`) ship `likes` and `listens` as `[]`, even to the owner; the owner's bundle keeps them.
- `d1/migrations/0005_private_first.sql` unpublishes every existing entry and collection once. After it runs, the feed, entity pages, and public profiles stay empty until people publish again.
- The Now tab opens on the person's own listening, recent notes, and drafts. The feed is a pushed screen ("Published by others"). The composer, capture sheet, share extension, and new collections start private, with Publish / Make private on entries and collections.

What remains:

- The retired web editor (`src/components/journal/journal-editor.tsx`, `src/lib/data/store.ts`) still sends only `public: true`, so entries written on the web are now saved private. Item 1 removes it.

## 3. Listening history first (`docs/IOS_NOW_PLAYING.md`) — done in code, needs a device

Landed 2026-10-29.

- `GET /api/now-playing` returns `recent`: up to 10 plays, newest first, merged from Last.fm `user.getRecentTracks` and ListenBrainz `playing-now` plus `listens`, with at most one playing row. `track` keeps its old meaning.
- The app ranks every source into one list (`RecentPlayList.rank` in ResonoteKit): the Music app (read through MusicKit's `SystemMusicPlayer` for the ISRC), Apple Music recently played and library `lastPlayedDate`, the server's recent list, and Journaling Suggestions picks (`GenericMedia` and `Song`). The capture sheet pre-selects the likeliest play and shows the next few as chips.
- The app has the Journaling Suggestions entitlement (`project.yml`), and the capture sheet's Recently played row opens the picker.
- Write first, attach later: a note saved with no song keeps its time and attaches the recent play covering it. The person can change or remove the song before saving it from Drafts.
- Identify is offered prominently when other audio is playing and no source names it; Settings → Identify on its own starts it without a tap (off by default).
- Last.fm web auth (`/api/account/lastfm/*`, `LASTFM_SHARED_SECRET`) replaces the typed username when the server is configured. Settings links to the Spotify connection pages of Last.fm and ListenBrainz.
- Settings explains how to build the Shazam → Note a Song shortcut and put it on the Action button or a personal automation.

What remains:

- Publish the Shazam → Note a Song shortcut from a device and put its iCloud link in `ShazamShortcut.link` (`SettingsView.swift`); until then Settings shows build steps instead of a link.
- Only the 10 most recent plays are checked, so a note written earlier than that waits for the server-side listening timeline (item 4).
- A written-first note stays a draft until the person saves it from Drafts.
- The Journaling Suggestions code is not compiled by `ios/scripts/typecheck.sh` (the framework is missing from Mac Catalyst); build it in Xcode. The device checks are in item 5.

## 4. Later

- Worker cron polls linked accounts and stores a listening timeline per person; notes reconcile against it by time. Widget push (`WidgetPushHandler`) and a push-to-start Live Activity, one per listening session, once the Worker can sign APNs requests.
- Spotify client-credentials `GET /tracks/{id}` for ISRC on shared links, replacing the embed-page scrape, if Development Mode still allows it.
- Screenshot capture: Vision text recognition in the share extension, and an iOS 26 visual intelligence `IntentValueQuery`.
- A `SnippetIntent` for the Action button.

## 5. Verify on a device

The list in `docs/IOS_NOW_PLAYING.md` → "Verify on a device": ShazamKit with non-Apple headphones, Spotify pausing or AirPods dropping to the call profile while the mic is open, `MPMediaLibrary` authorization inside the widget extension, what the Journaling picker shows on a Spotify-only phone, Spotify client-credentials under 2026 rules.

Items 2 and 3 add:

- The Journaling Suggestions picker builds under Xcode and its completion closure is correctly isolated under Swift 6.
- `SystemMusicPlayer.shared.queue.currentEntry` returns a song with an ISRC for Music app playback.
- `MusicRecentlyPlayedRequest` and `MusicLibraryRequest` return results with the current permission (recently played may need the MusicKit service on the App ID).
- `AVAudioSession.isOtherAudioPlaying` with Spotify and YouTube Music playing.
- The full Last.fm sign-in flow and the `resonote://lastfm-auth` callback in the web auth session.
- The `shazam.logo` symbol renders.
