# Knowing what someone is listening to on iPhone

Research notes behind the native app's now-playing design (October 2026, iOS 26 and 27).

## The constraint

iOS has **no public API that reads another app's playback**. `MPNowPlayingInfoCenter`
only publishes your own app's audio; the Lock Screen's system-wide "Now Playing" comes
from the private MediaRemote framework, and using it gets an app rejected (App Review
2.5.1). iOS 27's new NowPlaying framework is also publish-only. So no app — Airbuds,
stats.fm, Discord, Last.fm — reads Spotify or YouTube Music off the device. They all
get it from somewhere else.

## How shipping apps do it

| App | Source of "now" |
| --- | --- |
| Airbuds, stats.fm | Server-side account links (Spotify Web API with extended quota; Apple Music recently-played) |
| Discord | Spotify account connection, server side |
| Last.fm scrobblers (QuietScrob, Marvis Pro) | The Music app on device (`systemMusicPlayer`) |
| Shazam | Audio recognition |
| Instagram / Snapchat music stickers | The music app pushes a share to them |

## What Resonote uses

| Source | Covers | Real time? | Friction | Notes |
| --- | --- | --- | --- | --- |
| Music app (`MPMusicPlayerController.systemMusicPlayer`) | Apple Music | Yes, while Resonote or one of its intents runs | One permission | Never sees Spotify or YouTube Music |
| Last.fm `user.getRecentTracks` (via the backend) | Spotify, and anything that scrobbles | Near real time (`nowplaying` attribute) | Link Spotify to Last.fm once, enter username | Needs `LASTFM_API_KEY` on the Worker; non-commercial terms |
| ListenBrainz `playing-now` (via the backend) | Spotify (ListenBrainz's importer), other scrobblers | Minutes of lag | Connect Spotify on listenbrainz.org, enter username | Keyless; may be stale for up to a track length |
| ShazamKit `SHManagedSession` | Anything audible, including (per WWDC23) what the iPhone plays to AirPods | One-shot, ~3–10 s | Microphone permission; ShazamKit App Service on the App ID | Verify headphone matching and playback interruption on a device |
| Share extension and paste row | Spotify, Apple Music, YouTube Music links | Instant | Two taps from the music app | Resolved on the Worker (Spotify oEmbed, YouTube oEmbed, iTunes lookup, MusicBrainz) |
| A user's Shortcut: Shazam → "Note a Song" | Headphone audio via Apple's Shazam | One-shot | Build the shortcut once | Resonote exposes the `NoteSongIntent` App Intent for this |

Dropped, with reasons:

- **Spotify Web API sign-in** — since February 2026, Development Mode apps need a
  Premium owner and allow 5 users; extended quota needs an organization with 250k+
  monthly users. Usable for the owner and a few testers only, so Spotify reaches
  Resonote through Last.fm and ListenBrainz instead.
- **Odesli / song.link API** — the keyless API was shut down (July 2026; returns 401).
- **Apple Music recently-played** — no timestamps, 30 items, incomplete; not "now."
- **Journaling Suggestions picker** — can show recent songs from any app, but the person
  picks from a mixed list and the entitlement must be enabled first. A reasonable later addition.
- **ReplayKit audio capture, silent-audio keep-alives, MediaRemote** — App Review risk.

## The surfaces

- **Action button / Control Center / Lock Screen**: two Controls (`ControlWidgetButton`
  with an `OpenIntent`): *Note Song* opens the capture sheet for what's playing,
  *Identify Song* opens it and listens. Assign in Settings → Action Button → Controls.
- **App Shortcuts**: "Note what's playing in Resonote", "Identify a song with Resonote",
  and *Note a Song* (title/artist parameters) for chaining from Shazam.
- **Widget**: Home Screen (small, medium) and Lock Screen (rectangular, circular,
  inline). It shows the last known song with suggested tags; tags are deep links into
  the capture sheet. Widgets can't watch playback (about 40–70 reloads a day), so the
  app refreshes them whenever it sees a new track, and a refresh button in the widget
  runs an intent that doesn't count against the budget.
- **In the app**: the Now tab and a now-playing bar above the tab bar ask "write about
  this?" with tag suggestions from the backend (`/api/music/resolve`). The song shown can
  be an old or paused one, so Identify ("Not this song?") and a copied link's Paste stay
  available beside it, in the capture sheet too.

## Later options

- Widget push updates (iOS 26 `WidgetPushHandler`) once the Worker polls Last.fm/ListenBrainz
  per user and can sign APNs requests.
- ListenBrainz's `connect-services` flow (needs MetaBrainz approval) so people can link
  Spotify without leaving Resonote.
- A `SnippetIntent` so the Action button can show the song and tag buttons without
  opening the app.
