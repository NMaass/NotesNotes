import { NextRequest, NextResponse } from 'next/server';
import { getDb } from '@/lib/server/db';
import { resolveCatalogPath } from '@/lib/server/repo';

export const runtime = 'nodejs';

/** Resolve an /music/{artist}/{album}/{song} slug path against D1-only imports. */
export async function GET(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, catalog: null });
  const path = request.nextUrl.searchParams.get('path')?.trim() ?? '';
  const segments = path.split('/').map((segment) => segment.trim()).filter(Boolean).slice(0, 3);
  if (!segments.length) return NextResponse.json({ ok: true, catalog: { artists: [], albums: [], songs: [] } });
  const catalog = await resolveCatalogPath(segments);
  return NextResponse.json({ ok: true, catalog });
}
