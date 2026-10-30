import { NextRequest, NextResponse } from 'next/server';
import { isValidLastfmToken } from '@/lib/music/lastfm';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { exchangeLastfmToken, lastfmConfig, saveLinkedLastfm, webAuthConfigured } from '@/lib/server/lastfm';

export const runtime = 'nodejs';

/**
 * Trades the token from resonote://lastfm-auth?token= for a Last.fm session and
 * links it to the caller (relinking replaces the old link). The session key is
 * stored, never returned. A token works once, so a resent request is a 400.
 */
export async function POST(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to link Last.fm.' }, { status: 401 });
  const config = await lastfmConfig();
  if (!webAuthConfigured(config)) return NextResponse.json({ ok: false, error: 'Last.fm sign-in is not set up on this server.' }, { status: 501 });

  const body = await request.json().catch(() => null) as { token?: unknown } | null;
  const token = typeof body?.token === 'string' ? body.token.trim() : undefined;
  if (!isValidLastfmToken(token)) return NextResponse.json({ ok: false, error: 'That is not a Last.fm sign-in.' }, { status: 400 });

  const result = await exchangeLastfmToken(config, token);
  if (result.kind === 'rejected') return NextResponse.json({ ok: false, error: 'Last.fm did not accept that sign-in. Try again.' }, { status: 400 });
  if (result.kind === 'failed') return NextResponse.json({ ok: false, error: 'Last.fm did not answer. Try again in a moment.' }, { status: 502 });
  try {
    const linkedAt = await saveLinkedLastfm(userId, result.username, result.sessionKey);
    return NextResponse.json({ ok: true, account: { username: result.username, linkedAt } });
  } catch (error) {
    console.error('Resonote Last.fm link failed', error);
    return NextResponse.json({ ok: false, error: 'Could not save your Last.fm link. Try again in a moment.' }, { status: 500 });
  }
}
