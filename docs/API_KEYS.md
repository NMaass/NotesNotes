# Integrations and credentials

The backend is a Cloudflare Worker with a D1 database. The iPhone app is its only client, authenticating with bearer tokens (see `docs/IOS_API.md`). There are no client-side database credentials: the app talks only to `/api/*` routes, and every route authorizes against the session.

## Cloudflare D1 — accounts, sessions, catalog

```dotenv
NEXT_PUBLIC_DATA_MODE=cloud
```

Provisioning (one time):

```bash
npx wrangler login
npx wrangler d1 create resonote          # then put the binding in wrangler.jsonc
npx wrangler d1 execute resonote --remote --file=d1/schema.sql
```

Local development uses the same binding through miniflare; `npm run dev` applies nothing automatically, so also run:

```bash
npx wrangler d1 execute resonote --local --file=d1/schema.sql
```

Apply `d1/migrations/*.sql` in order after the schema; they are additive and idempotent.

## Sign-in email — Resend

Sign-in codes are six-digit OTPs delivered by Resend once both variables exist:

```dotenv
RESEND_API_KEY=re_xxxxxxxx
AUTH_EMAIL_FROM="Resonote <sign-in@your-verified-domain>"
```

Resend requires a verified domain for arbitrary recipients (`onboarding@resend.dev` can only reach your own account email while testing). Without these variables the backend stays in dev mode: every code is returned in the API response (`devCode`). Never ship dev mode to production.

## MusicBrainz — no API key

Set a real contact address for the server-side User-Agent:

```dotenv
MUSICBRAINZ_CONTACT_EMAIL=you@example.com
NEXT_PUBLIC_ENABLE_REMOTE_SEARCH=true
```

The route-handler adapter queues remote calls, leaves at least 1.05 seconds between them in one worker instance, caches successful responses, and keeps clients from calling MusicBrainz directly.

Search runs through this adapter, and so do imports: `POST /api/music/import` and the resolver (`POST /api/music/resolve`), which imports a now-playing song only when the match is certain. Requests from overlapping resolves are served earliest-deadline-first so each finishes within its ~20 s budget.

## Catalog import worker

The import route (`POST /api/music/import`) resolves an artist, release group, or recording from MusicBrainz into a complete bundle — artist, release group, tracklist, and cover art — before creating any pages. Imports land in the shared D1 catalog for everyone; no extra secrets beyond the Workers binding.

## Cover Art Archive — no API key

Album images use MusicBrainz release-group IDs. The app declares a square artwork slot before the image loads, so a missing or slow cover does not move surrounding controls.

## Last.fm — recent listening and now-playing

`GET /api/now-playing?lastfm=<username>` reads a person's current scrobble and recent tracks with Last.fm's `user.getRecentTracks`. That method needs an API key (no user authorization — it reads public listening data):

```dotenv
LASTFM_API_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Create one at https://www.last.fm/api/account/create. In production set it as a Worker secret (`npx wrangler secret put LASTFM_API_KEY`); locally put it in `.env.local`. Without it, the Last.fm lookup is skipped (`services: [{ service: 'lastfm', status: 'not-configured' }]`) and ListenBrainz still works. ListenBrainz needs no key. Last.fm's API terms are non-commercial.

## Spotify — no key

Spotify reaches the app through Last.fm and ListenBrainz scrobbling and through shared links, not through a Spotify developer application: Development Mode is limited to a Premium owner and five allowlisted users (see `docs/IOS_NOW_PLAYING.md`). A client-credentials app for `GET /tracks/{id}` (ISRC lookup on shared links) is a possible later addition.

## Odesli / song.link — optional

Shared song links (`POST /api/music/resolve { url }`) are read from each provider without credentials: Spotify's embed page and oEmbed, the iTunes lookup API, YouTube oEmbed, and song.link page data. Odesli's public API was retired in July 2026 and answers `401 PUBLIC_API_ACCESS_DEPRECATED`; if you obtain a key it is used first:

```dotenv
ODESLI_API_KEY=
```

## Apple — on the device, not the server

ShazamKit (Identify), Media & Apple Music access (the Music app), and the Journaling Suggestions capability (Recently played) are App ID services and entitlements configured in Xcode and the developer portal; see `ios/README.md`. The backend holds no Apple credentials.

## Cloudflare

Wrangler stores its own authentication outside the repository after:

```bash
npx wrangler login
```

Set production environment variables in Cloudflare instead of committing `.env.local`.

Required for the shared deployment:

```dotenv
NEXT_PUBLIC_DATA_MODE=cloud
NEXT_PUBLIC_SITE_URL=https://YOUR-WORKER-OR-DOMAIN
MUSICBRAINZ_CONTACT_EMAIL=
NEXT_PUBLIC_ENABLE_REMOTE_SEARCH=true
```

The D1 binding is declared in `wrangler.jsonc` and deploys with the Worker.
