import { NextRequest, NextResponse } from 'next/server';
import { getDb } from '@/lib/server/db';
import { searchCatalog } from '@/lib/server/catalog';

export const runtime = 'nodejs';

/** Seeded catalog plus every D1 artist/album/song/genre, as one ranked batch. */
export async function GET(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const query = request.nextUrl.searchParams.get('q')?.trim().slice(0, 200) ?? '';
  const requested = Number(request.nextUrl.searchParams.get('limit') ?? 20);
  const limit = Number.isFinite(requested) ? Math.min(50, Math.max(1, Math.round(requested))) : 20;
  if (!query) return NextResponse.json({ results: [] });
  try {
    const results = await searchCatalog(query, limit);
    return NextResponse.json({ results });
  } catch (error) {
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : 'Search failed.' }, { status: 500 });
  }
}
