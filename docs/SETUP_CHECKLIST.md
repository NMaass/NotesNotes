# Resonote setup checklist

Do these in order. The iPhone app needs the backend, so the backend comes first.

## Checkpoint A — the backend on Cloudflare

- [ ] Install Node.js 22 or newer and run `npm install` in the repository root.
- [ ] Run `npx wrangler login` once.
- [ ] Create the database if this is a fresh account: `npx wrangler d1 create resonote`, then put the binding in `wrangler.jsonc` (already done for this repository).
- [ ] Apply the schema remotely: `npx wrangler d1 execute resonote --remote --file=d1/schema.sql`.
- [ ] Apply every file in `d1/migrations/` in order the same way (they are additive and idempotent).
- [ ] Set production variables in Cloudflare: `NEXT_PUBLIC_SITE_URL` (the Worker's https URL), `MUSICBRAINZ_CONTACT_EMAIL`, `NEXT_PUBLIC_ENABLE_REMOTE_SEARCH=true`, `NEXT_PUBLIC_DATA_MODE=cloud`.
- [ ] Set secrets: `npx wrangler secret put LASTFM_API_KEY` (see `docs/API_KEYS.md`); `RESEND_API_KEY` and `AUTH_EMAIL_FROM` before inviting anyone, otherwise sign-in codes are returned in the API response.
- [ ] Deploy: `npm run cf:deploy`. Note the Worker URL.
- [ ] Check it: `curl https://YOUR-WORKER/api/auth/session` answers `{"authenticated":false}`.

## Checkpoint B — local backend (optional)

- [ ] `cp .env.example .env.local`, set `NEXT_PUBLIC_DATA_MODE=cloud`, `MUSICBRAINZ_CONTACT_EMAIL`, `NEXT_PUBLIC_ENABLE_REMOTE_SEARCH=true`.
- [ ] `npx wrangler d1 execute resonote --local --file=d1/schema.sql`, then the migrations.
- [ ] `npm run dev` serves the API routes at `http://localhost:3000`; sign-in codes print to the dev-server log.
- [ ] Point a debug build of the app at it with `RESONOTE_API_BASE_URL` in `ios/Config/Signing.xcconfig` (an iPhone on the same network needs your Mac's address, not `localhost`).

## Checkpoint C — the iPhone app

- [ ] Xcode 26 or newer; an Apple Developer account.
- [ ] Put your team ID in `ios/Config/Signing.xcconfig`.
- [ ] In the developer portal, turn on **ShazamKit** for the app's App ID (Identify needs it) and add the **Journaling Suggestions** capability in Xcode (the Recently played picker needs it).
- [ ] Run the **Resonote** scheme on a real iPhone.
- [ ] Sign in with an email; enter the code from your inbox (or from the dev-server log when running locally).
- [ ] Play something in the Music app, open Resonote, and confirm the Now tab names it.
- [ ] In Settings, add a Last.fm or ListenBrainz username; play something on Spotify and confirm it appears.
- [ ] Tap Identify with music playing nearby; confirm the microphone prompt and a match.
- [ ] Share a Spotify or YouTube Music link to Resonote from the share sheet.
- [ ] Add the widget, assign the **Note Song** Control to the Action button, and check both open the capture sheet.
- [ ] Work through `docs/IOS_NOW_PLAYING.md` → "Verify on a device".

## Checkpoint D — quality gates

```bash
npm run validate:data
npm run typecheck
npm run lint
npm test
ios/scripts/typecheck.sh all
ios/scripts/test-kit.sh
```

Then on the phone:

- [ ] Opening a section does not move its header; `Like` becoming `Liked` does not move neighbours.
- [ ] Artwork reserves its space before loading.
- [ ] Leaving the capture sheet mid-sentence and coming back keeps the words.
- [ ] A `\` reference inserts the selected entity, not just its text.
- [ ] Reduce Motion stops the record spinning.
- [ ] Airplane mode: a saved entry shows as queued and sends when the network returns.
- [ ] A visitor cannot see another person's listen log.
