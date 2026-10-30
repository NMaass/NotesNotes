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
   work without it. The Journaling Suggestions entitlement
   (`com.apple.developer.journal.allow`) is already in `project.yml` and is
   self-service; automatic signing adds it.
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
sources whenever you open it, run a shortcut, or the widget refreshes, and ranks them into
one recent list: the playing song first (only one), then plays newest first. The capture
sheet attaches the likeliest one and shows the next few as chips, so you rarely name a song.

| Source | Covers | Setup |
| --- | --- | --- |
| Music app | Apple Music, in real time on the phone, with the song's ISRC | In Resonote's Settings, turn on Apple Music. iOS asks for Media & Apple Music access. |
| Apple Music history | Recently played on any of your devices, and library songs by last played date | The same Apple Music access. |
| Last.fm / ListenBrainz | Spotify, and anything else that scrobbles: what's playing and the last 10 plays | Settings → Sign in with Last.fm (falls back to typing a username when the server has no Last.fm keys); ListenBrainz takes a username. |
| Journal suggestions | Any app that shows on the Lock Screen's Now Playing (iOS 18 and later) | In the capture sheet's Recently played row, tap Journal suggestions and pick a song from the system sheet. No account, no microphone. |
| Identify | Anything audible | Tap Identify. Shazam listens for a few seconds. The first use asks for the microphone. |
| Links | Spotify, Apple Music, YouTube Music | Share a song to Resonote from the share sheet, or copy a link and open the app. |

- **Spotify:** connect Spotify to Last.fm (last.fm → Settings → Applications) or to
  ListenBrainz (listenbrainz.org → Settings → Connect services); Settings → Spotify links
  to both pages. Then sign in with Last.fm or add your ListenBrainz username in Resonote.
- **YouTube Music:** it doesn't scrobble, so use the share sheet, Identify, or Journal
  suggestions.
- **Identify prompt:** when something is playing that no source can name, the capture
  sheet offers Identify prominently. Settings → Identify → **Identify on its own** starts
  it without a tap. It is off by default, because it opens the microphone.
- **Write first, attach later:** with nothing playing, the capture sheet offers "Write
  first, add the song later". The note keeps its time and waits in Drafts; when a source
  reports the play that covered that time, the song attaches itself. Open the note from
  Drafts to change or remove the song, then save it.

Whatever the source, the backend matches the song to the catalog and suggests
genres, lenses, and moods for your note.

## Private by default

Everything you write starts private. In the composer, choose **Published** to let others
read an entry; on an entry or collection you own, the options menu offers **Publish** or
**Make private**. Other people see only published entries and collections on your profile,
entity pages, and the feed, never your likes or listens.

## Widget, Control Center, and the Action button

- **Home Screen / Lock Screen:** touch and hold → Edit → Add Widget → Resonote. The
  widget shows the current song and suggested tags. Tap it to write.
- **Action button** (iPhone 15 Pro and later): Settings → Action Button → Controls →
  Resonote **Note Song**. The same control works in Control Center and on the Lock
  Screen.
- **Shortcuts and Siri:** Resonote's App Shortcuts appear in the Shortcuts app. You
  can also assign one to the Action button with its Shortcut option.

### Shazam → Note a Song

Apple's Shazam recognizer hears what plays in any headphones, and it never asks Resonote
for the microphone. A shared shortcut link isn't published yet, so build it once:

1. In Shortcuts, create a shortcut and add **Recognize Music** (Shazam).
2. Add Resonote's **Note a Song**, and set its Title and Artist to the recognized song's
   title and artist.
3. Name it "Shazam → Note a Song".

Run it in any of these ways:

- **Action button:** Settings → Action Button → Shortcut → Shazam → Note a Song.
- **Personal automation:** in Shortcuts → Automation, create one for "App is opened"
  (Spotify) or "Bluetooth" (your AirPods connect) and set it to run the shortcut.

Resonote's Settings → Widgets & Action button shows the same steps.

## Backend requirements

Run these from the repository root. The API contract is in
[docs/IOS_API.md](../docs/IOS_API.md).

1. Deploy the API, which adds bearer-token auth, catalog search and entity reads, the
   feed, `/api/music/resolve`, `/api/now-playing`, and Last.fm sign-in:
   `npm run cf:deploy`
2. Apply every migration in `d1/migrations/` in order, for example:
   `npx wrangler d1 execute resonote --remote --file d1/migrations/0005_private_first.sql`.
   They are idempotent. `0005_private_first.sql` makes every existing entry and
   collection private, once, and adds the `linked_accounts` table for Last.fm sign-in;
   after it runs, the feed and public profiles are empty until people publish again.
3. Set the Last.fm key used by `/api/now-playing`. Create one at
   last.fm/api/account/create, then run `npx wrangler secret put LASTFM_API_KEY`.
4. For Sign in with Last.fm, also set the application's shared secret:
   `npx wrangler secret put LASTFM_SHARED_SECRET`. Without it, Settings falls back to
   typing a Last.fm username. ListenBrainz needs no key.
