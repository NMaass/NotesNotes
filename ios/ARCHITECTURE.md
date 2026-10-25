# Resonote for iPhone — architecture

A native SwiftUI rebuild of the Resonote web app (rating-free music journal), on the
same Cloudflare Worker + D1 backend. Minimum iOS 26.0, Swift 6, default actor
isolation `MainActor` with Approachable Concurrency, iPhone only, dark appearance.

## Targets

| Target | Sources | Notes |
| --- | --- | --- |
| `Resonote` (app) | `Resonote/`, `Shared/`, `SharedIntents/` | SwiftUI app |
| `ResonoteWidgets` (WidgetKit extension) | `ResonoteWidgets/`, `Shared/`, `SharedIntents/` | Home/Lock Screen widgets + Controls (Action button) |
| `ResonoteShare` (share extension) | `ResonoteShare/`, `Shared/` | Capture from Spotify / Apple Music / YouTube Music share sheets |
| `ResonoteKit` (Swift package) | `Packages/ResonoteKit/` | Models, API client, outbox, drafts, rich text, snapshot. Nonisolated, `Sendable`. Tested with Swift Testing. |

All three targets share the App Group `group.dev.nmaass.resonote` (container files,
shared defaults) and use it as their keychain access group for the bearer token.

## How "now playing" works (and why)

iOS has no public API to read what Spotify or YouTube Music is playing (MediaRemote
is private and rejected by App Review). Resonote samples these sources on demand —
when the app becomes active, when an App Intent runs, when the widget reloads:

1. **Music app** — `MPMusicPlayerController.systemMusicPlayer` (real time, Apple Music only).
2. **Last.fm / ListenBrainz** — the backend's `GET /api/now-playing` reads the person's
   public scrobbling accounts. Spotify scrobbles to both, so this covers Spotify
   without Spotify's 5-user Development Mode cap.
3. **Shazam** — `SHManagedSession`, when the person taps Identify (it can also hear what
   the iPhone plays to AirPods).
4. **Links** — the share extension and a paste row accept Spotify, Apple Music, and
   YouTube Music links; the backend resolves them.

`NowPlayingService` (`Resonote/Services/`) owns this. Every source normalizes into
`NowPlayingTrack`; `POST /api/music/resolve` maps it to a catalog `Song` (importing from
MusicBrainz when needed) and returns `TagSuggestions` (genres, lenses, moods, prompt).

## Data flow

- `AppModel` (`Resonote/App/AppModel.swift`) holds the signed-in owner's `ProfileBundle`
  and the `CatalogIndex` of every entity seen. **All writes go through its methods**:
  optimistic local change → `SyncOutbox` (durable, per-object, latest intent wins).
  A server refresh never reverts an unconfirmed write: `refreshSession()` takes an outbox
  checkpoint before the read and keeps local state for anything unconfirmed or written
  since. Bundle and catalog files are read and written off the main actor, coalesced.
- The outbox keeps every write on disk until the server confirms it or refuses it for good
  with a 4xx (in-flight writes included). Network trouble, throttling, and server errors
  (5xx, a missing database, an unreadable reply) are retried with capped backoff for as
  long as it takes; returning to the foreground, the network coming back, and a successful
  session read send waiting writes at once (`retryNow`). It backs off per write so one
  failing object never blocks the rest, and tags each write with its owner. An expired
  session (`authenticated: false`, a 401) only pauses it: the bundle and queue stay, a
  banner offers sign-in, and the same person signing in sends what waited. Only a
  confirmed Sign out, account deletion, or a different person signing in (sign-in asks
  first when the previous person has unsynced changes) clears it. A refused write is
  undone locally; the words of a refused or cleared entry, and a listen's note, go back to
  their writer's drafts. A draft is deleted only after its published entry is queued.
  Deleting an entry or collection also queues an unpin when a pin for it is still waiting.
- Likes, pins, and genre tags decide their end state at tap time (`setLiked`, `setPinned`,
  `setGenre`), so an action resumed after sign-in can't undo what the account already has.
- `requireAuth { … }` runs the action now, or after sign-in once the sign-in sheet has
  finished leaving, so a resumed action can present its own sheet.
- `Router` (`Resonote/App/Router.swift`): `tab`, one `[Route]` path per tab, one
  `sheet: Sheet?`. `router.push(.entity(kind:id:))`, `router.present(.compose(...))`.
  Every modal goes through `Router.sheet` (no local `.sheet` on pushed screens), so a
  widget, control, or the Action button can always present. Capture, identify, and
  shared links share one sheet id: a new request updates the open capture sheet in
  place instead of replacing it and its unsaved words.
  Deep links (`DeepLink` in ResonoteKit, scheme `resonote://`) arrive via `router.open`.
  Tapping a music reference inside journal prose opens `resonote://entity/<kind>/<id>`,
  which the root `OpenURLAction` routes.
- Reads that span people (feed, entity pages, search) call `model.api` directly
  (`APIClient` in ResonoteKit) and feed results into `model.absorb(...)` so the
  catalog index can render references and subtitles later.
- Drafts live in `DraftStore` (one per entity for new entries, one per entry when
  editing) and are never overwritten by background data. They belong to the person who
  wrote them: read and write them through `model.drafts` (scoped to the signed-in profile),
  so the next person on the iPhone never sees them. Quick words from the capture and
  share sheets are added to a draft with `DraftStore.append`, never replacing it; the
  capture sheet also keeps its words in a draft whenever the app leaves the foreground.
- Block changes are kept for one owner and only ever sent with that owner's session.
- `catalog.json` keeps the rows the person's own journal references plus the 2,000 most
  recently seen; the in-memory index keeps everything for the session.
- `APIClient` decodes responses off the caller's actor (`@concurrent` transport), so
  views can call `model.api` directly without wrapping it.
- The widget reads `NowPlayingSnapshot` (App Group file) which the app updates through
  `WidgetBridge`.
- "Playing" has one rule everywhere (`NowPlayingTrack.claimsPlayback`): a live source
  vouches for 10 minutes after its sample; a Shazam match or a Shortcut's song for about
  one song (its length, else 4 minutes). The app reads `NowPlayingService.isConfirmedPlaying`.
  Songs older than 12 hours are history, never "now".
- Other people's writing can be reported and its writer blocked (`Features/Safety`);
  blocked people's writing is hidden everywhere. Settings deletes the account.

## Stable-interface rules (from the web app; non-negotiable)

1. Declare geometry before content arrives: fixed artwork frames (`ArtworkView`),
   reserved error rows (`ReservedErrorRow`), placeholder rows of final height.
2. Finite label swaps use `StableLabel` (Like/Liked, Pin/Pinned, Save note/Log listen,
   Saving…) so controls never change size.
3. Never blank content during refresh; keep the old value until the new one replaces it.
   Lists arrive as complete batches (no row-by-row insertion), never reorder under a finger.
4. Motion only for committed meaning: the vinyl spins only when a source confirms
   playback; respect `accessibilityReduceMotion`; haptics (`sensoryFeedback`) on
   committed results only.
5. One deliberate action changes one bounded region. Like changes one heart.
6. Drafts are the person's; publish is explicit. Sign-in returns to the same action.
7. The interface never claims something it can't confirm (e.g. "playing").

## Visual language

Dark paper (`RN.Palette.paper` #101113), ink text, one rust accent. Georgia for
display and journal prose (`RN.Typography`), SF for UI. Pill chips (`Chip`), cards
(`.cardSurface()`), eyebrows (`Eyebrow`). Liquid Glass only on the functional layer
(tab bar, the now-playing accessory, sheets, one `.glassProminent` primary action per
screen) — never on content cards. Calm, minimal, no ratings anywhere.

Shared building blocks (in `Resonote/DesignSystem/` and `Shared/Palette.swift`):
`RN` tokens, `Eyebrow`, `SectionHeader`, `StableLabel`, `Chip`, `FlowLayout`,
`ReservedErrorRow`, `EmptyStateView`, `.solid`/`.outline` button styles,
`.cardSurface()`, `.paperBackground()`, `ArtworkView`, `VinylView`, `RichDocumentView`,
`EntryCard`, `EntityRow`.

## Conventions

- Views read state with `@Environment(AppModel.self)`, `@Environment(Router.self)`,
  `@Environment(NowPlayingService.self)`.
- Load with `.task(id:)` so changing inputs cancels stale work. Keep view bodies cheap:
  no formatters or JSON work in `body`; precompute.
- Copy: keep the web app's microcopy where it exists (see docs/IOS_API.md and the web
  components). Sentence case. No exclamation marks.
- Accessibility: every icon-only button has a label; Dynamic Type works (Georgia uses
  `relativeTo:`); VoiceOver reads cards as one element with actions.
- Verify with `ios/scripts/typecheck.sh [kit|app|widgets|share|all]` (Mac Catalyst
  typecheck — no Xcode needed) and `ios/scripts/test-kit.sh`.

## Project generation

`ios/project.yml` (XcodeGen) generates `ios/Resonote.xcodeproj`. Run `xcodegen` in
`ios/` after adding files. Set your team in `ios/Config/Signing.xcconfig`; a team chosen in
Xcode's Signing & Capabilities tab is lost when the project is regenerated.
