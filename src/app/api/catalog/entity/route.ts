import { NextRequest, NextResponse } from 'next/server';
import { currentUser } from '@/lib/server/auth';
import { ENTITY_KINDS, loadEntityDetail } from '@/lib/server/catalog';
import { getDb } from '@/lib/server/db';
import type { EntityKind } from '@/lib/data/types';

export const runtime = 'nodejs';

/** Everything one entity screen needs in one round trip (docs/IOS_API.md). */
export async function GET(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const kind = request.nextUrl.searchParams.get('kind') as EntityKind | null;
  const id = request.nextUrl.searchParams.get('id')?.trim() ?? '';
  if (!kind || !ENTITY_KINDS.includes(kind) || !id || id.length > 200) {
    return NextResponse.json({ ok: false, error: 'A kind (artist, album, song, genre) and an id are required.' }, { status: 400 });
  }
  try {
    const viewer = await currentUser();
    const detail = await loadEntityDetail(kind, id, viewer);
    if (!detail) return NextResponse.json({ ok: false, error: 'Not found.' }, { status: 404 });
    return NextResponse.json(detail);
  } catch (error) {
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : 'Could not load that page.' }, { status: 500 });
  }
}
