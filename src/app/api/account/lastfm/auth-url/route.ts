import { NextResponse } from 'next/server';
import { LASTFM_CALLBACK_SCHEME, lastfmAuthUrl } from '@/lib/music/lastfm';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { lastfmConfig, webAuthConfigured } from '@/lib/server/lastfm';

export const runtime = 'nodejs';

/** The last.fm page where the person approves Resonote; it calls back to resonote://lastfm-auth. */
export async function GET() {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to link Last.fm.' }, { status: 401 });
  const config = await lastfmConfig();
  if (!webAuthConfigured(config)) return NextResponse.json({ ok: false, error: 'Last.fm sign-in is not set up on this server.' }, { status: 501 });
  return NextResponse.json({ ok: true, url: lastfmAuthUrl(config.apiKey), callbackScheme: LASTFM_CALLBACK_SCHEME });
}
