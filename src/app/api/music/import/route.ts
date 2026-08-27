import { NextRequest, NextResponse } from 'next/server';
import { resolveImport, type ImportBundle } from '@/lib/music/musicbrainz';
import { getDb } from '@/lib/server/db';
import { upsertImportedCatalog } from '@/lib/server/repo';

export const runtime = 'nodejs';
export const maxDuration = 30;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function POST(request: NextRequest) {
  let payload: { kind?: string; mbid?: string };
  try {
    payload = await request.json() as { kind?: string; mbid?: string };
  } catch {
    return NextResponse.json({ ok: false, error: 'Invalid request body.' }, { status: 400 });
  }

  const kind = payload.kind === 'artist' || payload.kind === 'album' || payload.kind === 'song' ? payload.kind : null;
  const mbid = payload.mbid?.trim().toLowerCase() ?? '';
  if (!kind || !UUID.test(mbid)) {
    return NextResponse.json({ ok: false, error: 'A valid MusicBrainz kind and identifier are required.' }, { status: 400 });
  }

  try {
    const bundle = await resolveImport(kind, mbid);
    // When a D1 database is bound, the import becomes shared catalog for everyone.
    // Otherwise the client keeps it in this browser's local catalog.
    if (await getDb()) {
      await upsertImportedCatalog({ artists: bundle.artists, albums: bundle.albums, songs: bundle.songs });
      return NextResponse.json({ ok: true, bundle });
    }
    return NextResponse.json({
      ok: true,
      bundle,
      warning: 'No cloud database is bound here; this import stays on your device.',
    });
  } catch (error) {
    return NextResponse.json(
      { ok: false, error: error instanceof Error ? error.message : 'Import failed.' },
      { status: 502 },
    );
  }
}
