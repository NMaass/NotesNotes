# Resonote MVP build report

## Delivered scope

The repository contains a mobile-first, production-shaped implementation of the rating-free music-journal concept:

- public home, music, genre, profile, profile-entry, write, collection, discovery, onboarding, health, and search routes;
- nested liked-music library;
- Tiptap journal editor with explicit `\` music references;
- reference relationship/lens metadata and hover previews;
- worked/did-not-work prompts without numeric ratings;
- manual listens and moods;
- freeform cross-entity collections;
- personal genre assertions;
- credits, sourced technical facts, and explainable collaborator patterns;
- pins and profile track;
- persistent Spotify/YouTube playback;
- demo-local and Cloudflare-D1 data modes;
- MusicBrainz discovery adapter and Cover Art Archive integration;
- Cloudflare/OpenNext deployment configuration;
- D1 schema, passwordless OTP sessions with server-side authorization, public-profile API routes, and serialized client synchronization;
- CI, unit, browser, static-data, and stability test scaffolding.

## Verification completed in the build environment

The following checks completed successfully against the delivered source:

- strict TypeScript/TSX syntax transpilation across the source tree;
- offline strict typecheck using a local TypeScript compiler and dependency shims;
- runtime selector/catalog smoke checks;
- UUID, relationship, slug, seed, migration, table, RLS, and source-provenance validation;
- Git whitespace/error check;
- stable-interface source audit for broad transitions, custom radios, unrequested scrolling, conditional badge insertion, effect-overwrite risks, and ad hoc geometry;
- static mobile and desktop layout rendering review using the delivered CSS;
- manual source review of authentication intent, draft persistence, player lifecycle, public/private bundle loading, serialized writes, and reference identity.

## Checks that require a normal networked development machine

The build container could not reach the npm registry, so dependencies could not be installed there. Consequently these repository commands still need to run after `npm install` on the owner’s machine or in GitHub Actions:

```bash
npm run typecheck
npm run lint
npm test
npm run test:e2e
npm run build
npm run cf:preview
```

The source includes these checks and CI configuration, but this report does not claim they ran in the offline container.

## Principal MVP boundaries

1. **Remote catalog import:** implemented as a resolve-first import worker (`POST /api/music/import`). Demo-mode imports persist per browser; when a D1 binding is present, imports join the shared catalog automatically. Import does not yet resolve aliases or genre tags.
2. **Streaming history import:** listen logging is manual. Spotify/Apple/YouTube Music history import is not implemented.
3. **Catalog breadth:** the seed intentionally contains a small coherent set for complete interaction and visual QA.
4. **Provider availability:** embedded Spotify/YouTube media may vary by region, rights, browser policy, or removed media.
5. **Name clearance:** “Resonote” is a working name; domain and trademark availability were not cleared.
6. **Publication:** the connected GitHub integration available in the build environment could read repositories but could not create a new repository or push local Git objects. A Git bundle and exact push instructions are supplied.
7. **Offline synchronization:** browser state is preserved and writes are serialized, but the cloud sync adapter is not a durable background queue or a database transaction spanning parent and child-row replacement. A failed sync is surfaced and the local copy remains available for a later save.

## Data safety notes

- No secret API values are committed.
- `.env.local`, build products, Playwright reports, and local audit files are ignored.
- The database is reachable only from server routes via the D1 binding; no database credentials exist in the browser bundle.
- User listen logs are private under RLS and are omitted from public profile bundles.
- Personal genre assertions retain `created_by` provenance and are writable only by their owner.
