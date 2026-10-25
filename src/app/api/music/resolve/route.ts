import { NextRequest, NextResponse } from 'next/server';
import { UnsupportedLinkError } from '@/lib/music/links';
import { LinkUnreadableError, resolveLink, resolveTrack } from '@/lib/music/resolve';
import { sanitizeTrack } from '@/lib/music/scrobbles';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';

export const runtime = 'nodejs';
export const maxDuration = 30;

/**
 * Maps a now-playing track (or a shared song link) onto a catalog song,
 * importing it from MusicBrainz when the match is certain, and returns
 * writing suggestions. Body: `{ track }` or `{ url }` (docs/IOS_API.md).
 */
export async function POST(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to match what you are listening to.' }, { status: 401 });

  const body = await request.json().catch(() => null) as { track?: unknown; url?: unknown } | null;
  if (!body || (body.track == null && body.url == null)) {
    return NextResponse.json({ ok: false, error: 'Send a track or a url.' }, { status: 400 });
  }

  try {
    if (body.track != null) {
      const track = sanitizeTrack(body.track);
      if (!track) return NextResponse.json({ ok: false, error: 'A track needs a title and an artist.' }, { status: 400 });
      return NextResponse.json(await resolveTrack(track, userId));
    }
    if (typeof body.url !== 'string' || body.url.length > 2048) {
      return NextResponse.json({ ok: false, error: 'Send the link as a string.' }, { status: 400 });
    }
    return NextResponse.json(await resolveLink(body.url, userId));
  } catch (error) {
    if (error instanceof UnsupportedLinkError) return NextResponse.json({ ok: false, error: error.message }, { status: 400 });
    if (error instanceof LinkUnreadableError) return NextResponse.json({ ok: false, error: error.message }, { status: 502 });
    console.error('Resonote resolve failed', error);
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : 'Could not match that track.' }, { status: 500 });
  }
}
