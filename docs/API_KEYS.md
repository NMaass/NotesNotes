# Integrations and credentials

## Demo mode — nothing required

```dotenv
NEXT_PUBLIC_DATA_MODE=demo
NEXT_PUBLIC_SITE_URL=http://localhost:3000
```

Use OTP `000000`. No email is sent, and writes stay in the current browser.

## Cloud mode — real accounts on Cloudflare D1

```dotenv
NEXT_PUBLIC_DATA_MODE=cloud
```

Accounts, sessions, and imported catalog rows live in Cloudflare D1. There are no client-side database credentials: the browser talks only to this app's `/api/*` routes, and every route authorizes against the session cookie.

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

Sign-in codes are six-digit OTPs delivered by Resend once both variables exist:

```dotenv
RESEND_API_KEY=re_xxxxxxxx
AUTH_EMAIL_FROM="Resonote <sign-in@your-verified-domain>"
```

Resend requires a verified domain for arbitrary recipients (`onboarding@resend.dev` can only reach your own account email while testing). Without these variables the app stays in dev mode: every code is returned in the API response and shown as a toast. Never ship dev mode to production.

## MusicBrainz — no API key

Set a real contact address for the server-side User-Agent:

```dotenv
MUSICBRAINZ_CONTACT_EMAIL=you@example.com
NEXT_PUBLIC_ENABLE_REMOTE_SEARCH=true
```

The route-handler adapter queues remote calls, leaves at least 1.05 seconds between them in one worker instance, caches successful responses through Next.js, and prevents browsers from calling MusicBrainz directly.

This is search/discovery only. Automatic catalog import is not included in the MVP.

## Catalog import worker

The import route (`POST /api/music/import`) resolves an artist, release group, or recording from MusicBrainz into a complete bundle — artist, release group, tracklist, and cover art — before creating any pages.

- **Demo mode / no D1 binding:** imports persist in this browser's local catalog immediately. Nothing to configure.
- **Cloud mode:** when the D1 binding is present the import lands in the shared catalog for everyone automatically — no extra secrets beyond your Workers binding.

## Cover Art Archive — no API key

Album images use MusicBrainz release-group IDs. The UI declares a square artwork slot before the image loads, so a missing or slow cover does not move surrounding controls.

## Spotify — no key for the current scope

The MVP uses stored public Spotify track IDs and Spotify’s iframe API. It does not request account data.

Create a Spotify developer application only when adding a separately scoped feature such as:

- account connection;
- recently played import;
- personal library access;
- OAuth-backed playback behavior.

Spotify is a playback provider, not Resonote’s canonical music database.

## YouTube — no key for the current scope

The MVP uses known public video IDs with the YouTube iframe API. A YouTube Data API key is needed only if the application starts searching YouTube programmatically.

When that is added, resolve a video on demand, let a person verify the match, cache the result, and do not spend search quota on every keystroke.

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
