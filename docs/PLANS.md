# Plans

What the docs describe that the code does not yet do, in the order it should land.
Each item names where the detail lives. Dated 2026-10-29.

## 1. Retire the web interface in code

The docs already call the Next.js interface retired; `src/` still ships it.

- Delete the web pages and components under `src/app` (everything except `src/app/api`, the privacy and terms pages, and whatever the API routes import from `src/components` or `src/lib`).
- Remove the browser-local demo mode (`NEXT_PUBLIC_DATA_MODE=demo`), the Zustand store, the Tiptap editor, the persistent player, and the Playwright e2e suite that drives them. Keep `src/lib` server-side music code and its Vitest tests.
- Keep the cookie session path only as long as removing it is risky; nothing uses it once the web client is gone (`docs/IOS_API.md`).
- Update `package.json` scripts and `.github/workflows/ci.yml` to the commands in `README.md`.

## 2. Private first: align the API with the docs

`docs/ARCHITECTURE.md` says likes and listens are owner-only and a feed is a secondary reading surface. The API still differs (`docs/IOS_API.md`).

- Drop likes from public profile bundles and from `GET /api/profiles/:handle`; keep them in the owner's bundle.
- Make entries private by default: a `published` flag on `entries`, honoured by the feed, entity pages, and public profiles. Collections likewise.
- Move the iOS Now tab off the cross-person feed: it opens on the person's own recent listening and notes. The feed becomes a route the person navigates to, not the home screen.
- No follow graph and no activity notifications are added. Report and block stay for published writing.

## 3. Listening history first (`docs/IOS_NOW_PLAYING.md`)

- Add the Journaling Suggestions capability and a "Recently played" row in the capture sheet backed by `JournalingSuggestionsPicker`; handle `GenericMedia` and `Song` items (iOS 18 types, app targets iOS 26).
- Fetch recent plays from Last.fm `user.getRecentTracks` and ListenBrainz `listens` alongside `playing-now`; `GET /api/now-playing` returns a short recent list, not just one track.
- Show recent plays newest first with the likeliest pre-selected; a live source only promotes one row.
- Write first, attach later: a note saved with no song keeps its time and attaches the listen that later covers that time; the person can change it. Builds on `DraftStore.attachUnmatched`.
- Offer Identify prominently when `AVAudioSession.isOtherAudioPlaying` is true and the Music app is silent; auto-start only behind a setting.
- Read the Music app through MusicKit's `SystemMusicPlayer` to get the ISRC, and add `MusicRecentlyPlayedRequest<Song>` plus library `lastPlayedDate` as Apple Music history.
- Sign in with Last.fm web auth instead of typing a username; deep-link the Spotify connection page.
- Ship the "Shazam → Note a Song" shortcut as a shared link and document the Action button and automation setups.

## 4. Later

- Worker cron polls linked accounts and stores a listening timeline per person; notes reconcile against it by time. Widget push (`WidgetPushHandler`) and a push-to-start Live Activity, one per listening session, once the Worker can sign APNs requests.
- Spotify client-credentials `GET /tracks/{id}` for ISRC on shared links, replacing the embed-page scrape, if Development Mode still allows it.
- Screenshot capture: Vision text recognition in the share extension, and an iOS 26 visual intelligence `IntentValueQuery`.
- A `SnippetIntent` for the Action button.

## 5. Verify on a device

The list in `docs/IOS_NOW_PLAYING.md` → "Verify on a device": ShazamKit with non-Apple headphones, Spotify pausing or AirPods dropping to the call profile while the mic is open, `MPMediaLibrary` authorization inside the widget extension, what the Journaling picker shows on a Spotify-only phone, Spotify client-credentials under 2026 rules.
