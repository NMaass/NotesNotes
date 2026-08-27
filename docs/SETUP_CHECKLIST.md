# Resonote setup checklist

Do these checkpoints in order. Stop after **Checkpoint A** to review the product without configuring a database or deployment account.

## Checkpoint A — run the product locally

- [ ] Install Node.js 22 or newer.
- [ ] Open a terminal in the `resonote` folder.
- [ ] Run exactly:

```bash
npm install
cp .env.example .env.local
npm run dev
```

- [ ] Open `http://localhost:3000`.
- [ ] Click **Join**, **Like**, **Write**, **Collect**, or **Tag genre**.
- [ ] Enter any email-shaped address, such as `demo@example.com`.
- [ ] Enter demo code `000000`.
- [ ] Confirm these exact flows:
  - [ ] Search `Lithium`.
  - [ ] Open the song page.
  - [ ] Press **Play**; pause it and confirm the player stays in place.
  - [ ] Press **Write**.
  - [ ] Type `\When You Sleep` and select the song from the popup.
  - [ ] Open **Describe the connection** and choose relationship/lens chips.
  - [ ] Publish the thought.
  - [ ] Open `@maya#library` and expand Nirvana.
  - [ ] Open `@maya#listens`; this tab is visible only to the signed-in owner.
  - [ ] Open **fluorescent parking lots at 2am** under Collections.
  - [ ] Open **Tag genre** on a song and toggle a personal genre assertion.

At this checkpoint, the complete seeded-catalog experience works in browser-local demo mode. Nothing below is required for product or visual review.

---

## Checkpoint B — put the repository on GitHub

The Git-ready bundle supplied with the build contains the complete commit history.

### 1. Create the empty repository

- [ ] Open `https://github.com/new`.
- [ ] Owner: `NMaass`.
- [ ] Repository name: `resonote`.
- [ ] Choose **Private** during credential and deployment setup.
- [ ] Do **not** add a README, `.gitignore`, or license.
- [ ] Click **Create repository**.

### 2. Clone the supplied bundle

Put `resonote.bundle` in the folder where you keep projects, then run:

```bash
git clone resonote.bundle resonote
cd resonote
git remote add origin https://github.com/NMaass/resonote.git
git push -u origin main
```

If Git says that `origin` already exists, run this instead of `git remote add`:

```bash
git remote set-url origin https://github.com/NMaass/resonote.git
git push -u origin main
```

- [ ] Refresh `https://github.com/NMaass/resonote`.
- [ ] Confirm the latest commit and the `.github/workflows/ci.yml` file are visible.

The source-only ZIP does **not** contain `.git` history. Use the bundle for the GitHub step.

---

## Checkpoint C — cloud accounts on Cloudflare D1

### 1. Provision the database

- [ ] Run `npx wrangler login` once.
- [ ] Run `npx wrangler d1 create resonote` (already done for this repo; the binding lives in `wrangler.jsonc`).
- [ ] Apply the schema remotely: `npx wrangler d1 execute resonote --remote --file=d1/schema.sql`.
- [ ] Apply it locally too so `npm run dev` has the same tables: `npx wrangler d1 execute resonote --local --file=d1/schema.sql`.

### 2. Turn on cloud mode locally

- [ ] Open `.env.local` and set:

```dotenv
NEXT_PUBLIC_DATA_MODE=cloud
NEXT_PUBLIC_SITE_URL=http://localhost:3000
MUSICBRAINZ_CONTACT_EMAIL=YOUR_REAL_MONITORED_EMAIL
NEXT_PUBLIC_ENABLE_REMOTE_SEARCH=true
```

- [ ] Restart the development server with Ctrl+C, then `npm run dev`.
- [ ] Run `npm run check:env` — cloud mode needs no client-side credentials.

### 3. Sign in

- [ ] Click **Join**, enter any email-shaped address, request a code.
- [ ] No mail provider is wired yet, so the code prints to the dev-server log as `[Resonote dev-mode] sign-in code for …`. Enter it.
- [ ] Confirm the header now shows your profile. Your likes, journal entries, listens, collections, pins, and imports now sync through D1 for this account.

Before inviting real users: verify a sending domain in Resend, then set `RESEND_API_KEY` + `AUTH_EMAIL_FROM`. Delivery then replaces dev-mode automatically — the code path checks configuration on every request.

---

## Checkpoint D — verify MusicBrainz search

MusicBrainz does not use an API key for this integration. It requires an identifiable User-Agent with a contact address.

- [ ] Confirm `.env.local` contains:

```dotenv
MUSICBRAINZ_CONTACT_EMAIL=you@example.com
NEXT_PUBLIC_ENABLE_REMOTE_SEARCH=true
```

- [ ] Restart the app.
- [ ] Search for an album that is not in the seed catalog (for example, "In Rainbows").
- [ ] Switch to the Albums tab, confirm a MusicBrainz result appears after local results, and open it.
- [ ] Press **Import this album** and wait for resolution (a few seconds; MusicBrainz is politely rate-limited).
- [ ] Confirm you land on a permanent album page with cover art and the full tracklist.
- [ ] Reload the page and confirm it still resolves from your device's imported catalog.
- [ ] Return to the home shelf and confirm the new record sits in the crate.

In demo mode (or without a D1 binding) the import stays in this browser. With cloud mode it is written into D1 and becomes part of everyone's catalog.

---

## Checkpoint E — Spotify and YouTube playback

No developer API key is required for the playback implemented here.

- Spotify uses a stored public track ID with Spotify’s iframe API.
- YouTube uses a stored public video ID with `youtube-nocookie.com` and JavaScript iframe control.

To add playback to another seeded song:

- [ ] Find the song row in `src/lib/data/catalog.ts`.
- [ ] Add `spotifyId`, `youtubeId`, or both.
- [ ] Prefer an official artist/label YouTube upload.
- [ ] Test play, pause, collapse, expand, close, and internal navigation.
- [ ] Confirm playback availability in markets you intend to support.

Do not create Spotify OAuth credentials until account linking or recently-played import becomes an explicit project.

---

## Checkpoint F — deploy to Cloudflare

- [ ] Create a Cloudflare account at `https://dash.cloudflare.com/sign-up` if needed.
- [ ] In the project terminal, run:

```bash
npx wrangler login
```

- [ ] Run the environment check:

```bash
npm run check:env
```

- [ ] Build and open a local Cloudflare preview:

```bash
npm run cf:preview
```

- [ ] Deploy:

```bash
npm run cf:deploy
```

- [ ] Copy the resulting `workers.dev` URL.
- [ ] In Cloudflare, set these production variables:
  - [ ] `NEXT_PUBLIC_DATA_MODE=cloud`
  - [ ] `NEXT_PUBLIC_SITE_URL=YOUR_HTTPS_CLOUDFLARE_URL`
  - [ ] `MUSICBRAINZ_CONTACT_EMAIL`
  - [ ] `NEXT_PUBLIC_ENABLE_REMOTE_SEARCH=true`
- The D1 binding travels with the Worker from `wrangler.jsonc`; no database secrets are configured in the dashboard.
- Deploy again after the variables are saved.

---

## Checkpoint G — run quality gates

Before sharing the site, run:

```bash
npm run validate:data
npm run typecheck
npm run lint
npm test
npm run test:e2e
npm run build
```

Then manually verify at approximately `390 × 844` and at desktop width:

- [ ] Opening one accordion does not move its trigger or the site header.
- [ ] `Like` becoming `Liked` does not move adjacent controls.
- [ ] Album art reserves space before loading.
- [ ] Prompt reroll does not move the editor surface.
- [ ] Closing and reopening a page does not erase an unpublished journal draft.
- [ ] A `\` reference inserts the selected entity rather than only its typed text.
- [ ] Reduced-motion mode stops record rotation.
- [ ] Pause/play does not replace the active iframe.
- [ ] The player close button is reachable on a phone.
- [ ] A visitor cannot see another profile’s listen log.
