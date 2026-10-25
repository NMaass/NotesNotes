import { NextRequest, NextResponse } from 'next/server';
import { loadFeed } from '@/lib/server/catalog';
import { decodeFeedCursor } from '@/lib/server/feed-cursor';
import { getDb } from '@/lib/server/db';

export const runtime = 'nodejs';

/** Recent public entries across everyone, newest first by updated_at (then id). */
export async function GET(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const requested = Number(request.nextUrl.searchParams.get('limit') ?? 30);
  const limit = Number.isFinite(requested) ? Math.min(50, Math.max(1, Math.round(requested))) : 30;
  const raw = request.nextUrl.searchParams.get('before')?.trim() || null;
  const before = raw ? decodeFeedCursor(raw) : null;
  if (raw && !before) {
    return NextResponse.json({ ok: false, error: 'before must be the nextCursor of a previous page.' }, { status: 400 });
  }
  try {
    return NextResponse.json(await loadFeed(limit, before));
  } catch (error) {
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : 'Could not load the feed.' }, { status: 500 });
  }
}
