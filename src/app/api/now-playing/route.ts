import { NextRequest, NextResponse } from 'next/server';
import { lookupNowPlaying } from '@/lib/music/now-playing';
import { resolveTrack } from '@/lib/music/resolve';
import { isValidLastfmUser, isValidListenBrainzUser } from '@/lib/music/scrobbles';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';

export const runtime = 'nodejs';
export const maxDuration = 30;

/**
 * The freshest track across the caller's linked Last.fm / ListenBrainz
 * accounts. With `resolve=1` the /api/music/resolve result rides along, so a
 * widget needs one request.
 */
export async function GET(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to see what you are playing.' }, { status: 401 });

  const params = request.nextUrl.searchParams;
  const lastfm = params.get('lastfm')?.trim() || undefined;
  const listenbrainz = params.get('listenbrainz')?.trim() || undefined;
  if (!lastfm && !listenbrainz) {
    return NextResponse.json({ ok: false, error: 'Link a Last.fm or ListenBrainz username first.' }, { status: 400 });
  }
  if (lastfm && !isValidLastfmUser(lastfm)) return NextResponse.json({ ok: false, error: 'That is not a Last.fm username.' }, { status: 400 });
  if (listenbrainz && !isValidListenBrainzUser(listenbrainz)) return NextResponse.json({ ok: false, error: 'That is not a ListenBrainz username.' }, { status: 400 });

  try {
    const { track, services } = await lookupNowPlaying({ lastfm, listenbrainz });
    const resolution = track && params.get('resolve') === '1' ? await resolveTrack(track, userId) : undefined;
    return NextResponse.json(
      { ok: true, track, ...(resolution ? { resolution } : {}), services },
      { headers: { 'Cache-Control': 'no-store' } },
    );
  } catch (error) {
    console.error('Resonote now-playing failed', error);
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : 'Could not read what is playing.' }, { status: 502 });
  }
}
