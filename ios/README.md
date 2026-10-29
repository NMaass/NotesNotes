# Resonote for iPhone

Resonote, the rating-free music journal, as a native SwiftUI app on the Cloudflare
Worker and D1 backend in this repository. It is a private journal first: the Now
tab opens on your own recent listening and your own notes, not on other people's. It
knows what you've been listening to and asks whether you want to write about a song,
from the app, a Home Screen widget, or the Action button. For targets, data flow, and
interface rules, see [ARCHITECTURE.md](ARCHITECTURE.md). For how listening history and
now-playing are sourced, see [docs/IOS_NOW_PLAYING.md](../docs/IOS_NOW_PLAYING.md).

## Requirements

- Xcode 26 or newer (iOS 26 SDK). The app runs on iPhone with iOS 26.0 or later.
- An Apple Developer account, for the App Group and ShazamKit.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46 or newer, only for
  regenerating the project: `brew install xcodegen`.

## First run

1. Open `ios/Resonote.xcodeproj`.
2. Put your team ID in `Config/Signing.xcconfig` (`DEVELOPMENT_TEAM = ABCDE12345`).
   You can also pick the team under Signing & Capabilities, but regenerating the
   project discards that choice.
3. Automatic signing registers the three App IDs (`dev.nmaass.resonote`, `.widgets`,
   `.share`) and creates the App Group `group.dev.nmaass.resonote`.
4. In the developer portal, open Certificates, Identifiers & Profiles → Identifiers →
   `dev.nmaass.resonote` → App Services and turn on **ShazamKit**. Identify doesn't
   work without it.
5. Run the **Resonote** scheme on an iPhone. The simulator has no Music app and no
   useful microphone, so test now-playing on a device.

To build under a different account, set your own `RESONOTE_BUNDLE_ID` and
`RESONOTE_APP_GROUP` in `Config/Signing.xcconfig`. `RESONOTE_API_BASE_URL` (default
`https://resonote.nmaass.dev`) points a build at another backend.

## Regenerating the project

`project.yml` is the source of truth. It generates `Resonote.xcodeproj`, each target's
`Info.plist`, and the `.entitlements` files, so change those in `project.yml` rather
than in Xcode. Targets pick up every file in their folders. After you add, move, or
delete files, run:

```sh
cd ios && xcodegen
```

## Checks without Xcode

```sh
ios/scripts/typecheck.sh all     # or kit | app | widgets | share
ios/scripts/test-kit.sh          # ResonoteKit's Swift Testing suite
swift ios/scripts/make-icon.swift  # re-render the app icon from the logo geometry
```

`typecheck.sh` builds against the Mac Catalyst copies of the iOS frameworks that ship
in the macOS SDK. It catches almost everything an iOS build would. In Xcode,
Product → Test runs the same ResonoteKit suite.

## How now-playing works

iOS doesn't let one app read what another app is playing, so Resonote leads with your
recent listening history and treats the exact current song as a bonus. It checks several
sources whenever you open it, run a shortcut, or the widget refreshes:

| Source | Covers | Setup |
| --- | --- | --- |
| Music app | Apple Music, in real time on the phone | In Resonote's Settings, turn on Apple Music. iOS asks for Media & Apple Music access. |
| Last.fm / ListenBrainz | Spotify, and anything else that scrobbles | In Resonote's Settings, enter your username. The backend reads your public now-playing. |
| Identify | Anything audible | Tap Identify. Shazam listens for a few seconds. The first use asks for the microphone. |
| Links | Spotify, Apple Music, YouTube Music | Share a song to Resonote from the share sheet, or copy a link and open the app. |
| Recently played | Any app that shows on the Lock Screen's Now Playing (iOS 18 and later) | Tap Recently played in the capture sheet; the system Journaling Suggestions picker lists recent songs and you pick one. No account, no microphone. |

- **Spotify:** connect Spotify to Last.fm (last.fm → Settings → Applications) or to
  ListenBrainz (listenbrainz.org → Settings → Connect services). Then add that
  username in Resonote.
- **YouTube Music:** it doesn't scrobble, so use the share sheet or Identify.

Whatever the source, the backend matches the song to the catalog and suggests
genres, lenses, and moods for your note.

## Widget, Control Center, and the Action button

- **Home Screen / Lock Screen:** touch and hold → Edit → Add Widget → Resonote. The
  widget shows the current song and suggested tags. Tap it to write.
- **Action button** (iPhone 15 Pro and later): Settings → Action Button → Controls →
  Resonote **Note Song**. The same control works in Control Center and on the Lock
  Screen.
- **Shortcuts and Siri:** Resonote's App Shortcuts appear in the Shortcuts app. You
  can also assign one to the Action button with its Shortcut option.

## Backend requirements

Run these from the repository root. The API contract is in
[docs/IOS_API.md](../docs/IOS_API.md).

1. Deploy the API, which adds bearer-token auth, catalog search and entity reads, the
   feed, `/api/music/resolve`, and `/api/now-playing`:
   `npm run cf:deploy`
2. Apply the additive, idempotent schema migration:
   `npx wrangler d1 execute resonote --remote --file d1/migrations/0002_native_client.sql`
3. Set the Last.fm key used by `/api/now-playing`. Create one at
   last.fm/api/account/create, then run `npx wrangler secret put LASTFM_API_KEY`.
   ListenBrainz needs no key.
