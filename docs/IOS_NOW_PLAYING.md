# Knowing what someone is listening to on iPhone

Research notes behind the native app's now-playing design (October 2026, iOS 26 and 27).
Revised 2026-10-29 after checking every platform claim against primary sources; see
References at the end. The design goal throughout: nobody types a song name. Listening
history is the primary source; knowing the exact song playing this second is a bonus
when a source happens to offer it.

## The constraint

iOS has **no public API that reads another app's playback**. `MPNowPlayingInfoCenter`
only publishes your own app's audio; the Lock Screen's system-wide "Now Playing" comes
from the private MediaRemote framework, and using it gets an app rejected (App Review
2.5.1). iOS 27's NowPlaying framework is also publish-only: an app describes its own media
session, and its "remote sessions" describe speakers the app itself controls through its
own server. So no app, not Airbuds, stats.fm, Discord or Last.fm, reads Spotify or YouTube
Music off the device. They all get it from somewhere else.

There is one sanctioned exception, and it is a *history*, not a live feed: Journaling
Suggestions. Every app that publishes Now Playing info feeds it unless the app opts out
with `MPNowPlayingInfoPropertyExcludeFromSuggestions`; Spotify and YouTube Music have not.

## Two different questions

- **Now**: what is playing this second. On the device only the Music app, Shazam, and a
  shared link can answer; Last.fm and ListenBrainz answer from the server for Spotify.
- **Recently**: what played in the last minutes or hours. Easier and more reliable to get,
  and for a journal it is usually what the person wants to write about anyway. History is
  the primary source. "Now" is a bonus: the current song is the one thing history cannot
  contain yet (a scrobble lands when the song ends), so when a live source answers, its
  song goes to the top of the same recent list rather than replacing it.

So the capture flow is: show recent plays newest first, pre-select the likeliest one, and
let a note be written before its song is settled.

## How shipping apps do it

| App | Source of "now" |
| --- | --- |
| Airbuds, stats.fm | Server-side account links (Spotify Web API with extended quota; Apple Music recently-played) |
| Discord | Spotify account connection, server side |
| Last.fm scrobblers (QuietScrob, Marvis Pro) | The Music app on device (`systemMusicPlayer`) |
| Shazam | Audio recognition |
| Instagram / Snapchat music stickers | The music app pushes a share to them |
| Day One | Journaling Suggestions picker (Spotify and Pocket Casts items since iOS 18) |

## Sources for "now"

| Source | Covers | Real time? | Friction | Notes |
| --- | --- | --- | --- | --- |
| Music app (`MPMusicPlayerController.systemMusicPlayer`) | Apple Music | Yes, while Resonote or one of its intents runs | One permission (Media & Apple Music) | Never sees Spotify or YouTube Music. MusicKit's `SystemMusicPlayer.shared.queue.currentEntry` gives the same item as a catalog `Song` with an ISRC, which the resolver treats as an exact match; prefer it to `MPMediaItem` text matching. |
| Last.fm `user.getRecentTracks` (via the backend) | Spotify, and anything that scrobbles | Near real time (`nowplaying` attribute) | Link Spotify to Last.fm once (server to server, so it covers every device); sign in with Last.fm web auth (`auth.getSession`) instead of typing a username | Needs `LASTFM_API_KEY` on the Worker; non-commercial terms. Web auth also validates the account and reads hidden recent tracks. |
| ListenBrainz `playing-now` (via the backend) | Spotify (ListenBrainz's importer), other scrobblers | Prompt: the importer polls Spotify's currently-playing endpoint | Connect Spotify on listenbrainz.org, enter username | Keyless. Only `playing-now` is fresh; finished listens arrive minutes to hours later. |
| ShazamKit `SHManagedSession` | Anything audible, and what the iPhone plays to AirPods (WWDC23: "recognize audio coming from the microphone or an AirPod") | One-shot, ~3–10 s | Microphone permission (required even for AirPods matching); ShazamKit App Service on the App ID | Apple documents AirPods only. The Shazam app's wired and third-party Bluetooth support (v17.3, January 2024) is an app feature, not a ShazamKit one. See "Verify on a device". |
| Share extension and paste row | Spotify, Apple Music, YouTube Music links | Instant | Two taps from the music app; the paste row shows only when a URL pattern is on the clipboard, detected without reading it, so no paste banner | Resolved on the Worker: iTunes lookup, YouTube oEmbed, song.link page data, MusicBrainz. Spotify is an embed-page scrape with oEmbed fallback (no artist field); a client-credentials `GET /tracks/{id}` would return the ISRC with no user involved. Verify dev-mode apps still have that endpoint. |
| A user's Shortcut: Shazam → "Note a Song" | Device audio through any headphones, via Apple's Shazam | One-shot | Install the shortcut once | Uses `NoteSongIntent`. Can also run from the Action button or a personal automation (when Spotify opens, when AirPods connect) and never asks Resonote for the microphone. Ship it as a shared shortcut link. |

## Sources for "recently"

| Source | Covers | Timestamps | Friction | Notes |
| --- | --- | --- | --- | --- |
| Journaling Suggestions picker (`JournalingSuggestion.GenericMedia`, iOS 18) | Every app that publishes Now Playing: Spotify, YouTube Music, SoundCloud, podcasts | Yes (`date`) | The capability only; the person picks from a system sheet mixed with photos and workouts | The one sanctioned on-device view of third-party plays, no account, no microphone. Returns title, artist, album, date, and the playing app's icon, so Resonote also learns which service to suggest linking. `JournalingSuggestion.Song` (iOS 17.2) covers library songs. The entitlement is self-service in Xcode. The picker renders in a system process and the app receives only the chosen item. |
| Last.fm `user.getRecentTracks` | Scrobblers | Yes (`date.uts`) | Same link as above | Paged with `from`/`to`. A scrobble needs half the track or 4 minutes, so skipped songs are missing and the current song appears only after it ends. |
| ListenBrainz `listens` | Scrobblers | Yes (`listened_at`) | Same link as above | `min_ts`/`max_ts` paging; same half-or-4-minutes rule; Spotify imports lag minutes to hours. |
| MusicKit `MusicRecentlyPlayedRequest<Song>` | Apple Music on every device (HomePod, Mac) | No | Same permission as the Music app | At most 30, in order, no dates: a "recent" list, not a timeline. The only view of plays that happened on another device. |
| Library `lastPlayedDate` (MusicKit `Song`, `MPMediaItem`) | Songs in the library played in Music | Yes | Same permission | Library songs only. |
| Spotify Web API `recently-played` | Spotify | Yes (`played_at`), up to 50 | Spotify sign-in | Dropped: Development Mode now means a Premium owner and five allowlisted users (announced 2026-02-06, in force since March 2026); extended quota needs an organisation with 250k monthly users. |

## Using recent plays so nobody types

- On open, fetch "recently" and sample "now" together, but the recent list is the
  surface; a live answer only promotes one row. Pre-select one song: playing beats
  recent, newer beats older. Show it as "Weird Fishes/Arpeggi · Radiohead · recently
  played · automatically attached", with the next few recent songs as chips ("2 min ago").
- When other audio is audible (`AVAudioSession.isOtherAudioPlaying`), the Music app is
  silent, and no live source vouches for a song, offer Identify prominently; start it
  without a tap only behind a setting, because it opens the microphone and the person
  should know why the orange dot appears. Without it, history still carries the flow.
- Write first, attach later. A note can be saved against its time with no song. The
  composer already keeps words for an unmatched track (`DraftStore.attachUnmatched`);
  extend it so a listen that arrives afterwards, the scrobble of whatever was playing at
  the note's time, attaches itself, and the person can change it.
- Ambiguity goes to the person, not to a text field: two or three candidates with
  artwork, never a search box first.
- The Journaling picker is one tap to open and one to pick. It is the fallback for anyone
  who has linked nothing, and the first-run hint for what to link.

## Dropped, with reasons

- **Spotify Web API sign-in**, and the iOS SDK's **App Remote** for the same reason. App
  Remote reads the Spotify app's player state locally and in real time while Resonote is
  in the foreground, but it authenticates through the same client, so the five-user
  allowlist applies. Fine behind a flag for the owner's phone; not a public source.
- **Odesli / song.link API**: the public API was retired on 2026-07-31 (announced
  2026-05-21) and answers 401 `PUBLIC_API_ACCESS_DEPRECATED`. song.link *pages* still
  work and are still read for song.link links.
- **Apple Music recently-played as "now"**: no timestamps, 30 items. Kept as a recent list
  (above), not as now.
- **ReplayKit audio capture, silent-audio keep-alives, MediaRemote**: App Review risk. A
  broadcast upload extension does receive other apps' audio, but only during a screen
  broadcast the person starts, so it buys nothing over Shazam.
- **Background microphone listening** with the audio background mode: allowed, but the
  orange indicator, the battery cost, and AirPods dropping to the call profile make it the
  wrong product. `BGContinuedProcessingTask` (iOS 26) is for finite, user-started work.
- **Shazam's "My Shazam Tracks" playlist** read through the media library: needs the
  Shazam app, its Apple Music sync, and Sync Library, which means an Apple Music
  subscriber. Not the people this is for.

## The surfaces

- **Action button / Control Center / Lock Screen**: two Controls (`ControlWidgetButton`
  with an `OpenIntent`): *Note Song* opens the capture sheet for what's playing,
  *Identify Song* opens it and listens. Assign in Settings → Action Button → Controls. A
  person can instead point the Action button at the Shazam → Note a Song shortcut, which
  hears any headphones through Apple's recognizer.
- **App Shortcuts**: "Note what's playing in Resonote", "Identify a song with Resonote",
  and *Note a Song* (title/artist parameters) for chaining from Shazam and automations.
- **Widget**: Home Screen (small, medium) and Lock Screen (rectangular, circular,
  inline). It shows the last known song with suggested tags; tags are deep links into
  the capture sheet. Widgets can't watch playback (about 40–70 reloads a day), so the
  app refreshes them whenever it sees a new track; reloads while the app is in the
  foreground and reloads caused by the widget's own refresh button don't count against
  the budget.
- **In the app**: the Now tab and a now-playing bar above the tab bar ask "write about
  this?" with tag suggestions from the backend (`/api/music/resolve`). The song shown can
  be an old or paused one, so Identify ("Not this song?"), a copied link's Paste, and a
  *Recently played* row (Journaling picker, scrobble history, newest first) stay
  available beside it, in the capture sheet too.

## Later options

- Widget push updates (iOS 26 `WidgetPushHandler`) and a Live Activity started by push
  (push-to-start, iOS 17.2) once the Worker polls Last.fm/ListenBrainz per user and can
  sign APNs requests: "Write about this" on the Lock Screen while the song plays. One per
  listening session, not per track; priority-5 pushes don't count against the budget.
- A listening timeline on the Worker: a cron poll of linked accounts stores listens with
  their timestamps, so history accumulates in Resonote and notes reconcile against it by
  time (write first, attach later, even days later). Tell people the server does this.
- ListenBrainz `POST /connect/spotify/` (needs the MetaBrainz-approved
  `listenbrainz:connect-services` scope). It still sends the person through a
  listenbrainz.org confirmation page and accounts.spotify.com in a browser, and the
  callback doesn't say who connected, so the username is still asked for.
- Screenshots: the share extension accepts an image, Vision reads the player, the Worker
  resolves. On iOS 26 a visual intelligence `IntentValueQuery` can offer "Note in
  Resonote" from the screenshot UI itself. The instant path for YouTube Music that needs
  no audio.
- A `SnippetIntent` so the Action button can show the song and tag buttons without
  opening the app.

## Verify on a device

- ShazamKit with wired and non-Apple Bluetooth headphones; whether Spotify pauses when
  the microphone opens; whether AirPods drop to the HFP call profile while listening.
- `MPMediaLibrary.authorizationStatus()` inside the widget extension: the refresh intent
  samples the Music app from the extension's own bundle, and the grant may not carry over.
- What the Journaling picker shows on a Spotify-only phone, and how soon after a play.
- Spotify client-credentials `GET /tracks/{id}` under 2026 Development Mode.

## References

- Spotify Development Mode changes: https://techcrunch.com/2026/02/06/spotify-changes-developer-mode-api-to-require-premium-accounts-limits-test-users/ and https://developer.spotify.com/documentation/web-api/concepts/quota-modes
- Odesli API retirement: https://github.com/eeegoloauq/music-bot/issues/7
- NowPlaying framework (WWDC26 312): https://developer.apple.com/videos/play/wwdc2026/312/
- ShazamKit managed session and AirPods (WWDC23 10051): https://developer.apple.com/videos/play/wwdc2023/10051/
- Shazam app 17.3 headphone support: https://9to5mac.com/2024/01/25/shazam-songs-apps-headphones/
- Music Recognition hears device audio with headphones: https://support.apple.com/HT210331
- Journaling Suggestions: https://developer.apple.com/documentation/journalingsuggestions/journalingsuggestion/genericmedia , https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.journal.allow , https://developer.apple.com/documentation/journalingsuggestions/presenting-the-suggestions-picker-and-processing-a-selection
- Day One on iOS 18 suggestions (Spotify, Pocket Casts): https://dayoneapp.com/?p=70006
- Widget reload budget and exemptions: https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
- Live Activity push-to-start and budget: https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications
- Visual intelligence integration: https://developer.apple.com/documentation/visualintelligence
- ListenBrainz connect flow: https://listenbrainz.readthedocs.io/en/latest/users/connect-music-services.html
- ListenBrainz Spotify import timing: https://listenbrainz.readthedocs.io/en/latest/general/data-update-intervals.html
