import { NextRequest, NextResponse } from 'next/server';
import { canPlay, isValidAuthCode, isValidCodeVerifier, SPOTIFY_SCOPES } from '@/lib/music/spotify';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { exchangeSpotifyCode, fetchSpotifyProfile, saveLinkedSpotify, spotifyConfig, spotifyConfigured } from '@/lib/server/spotify';

export const runtime = 'nodejs';

/**
 * Trades the code from resonote://spotify-auth?code= (with the app's PKCE verifier)
 * for tokens, reads the account with GET /v1/me, and links it to the caller
 * (relinking replaces the old link). The tokens are stored, never returned. A code
 * works once, so a resent request is a 400.
 */
export async function POST(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to link Spotify.' }, { status: 401 });
  const config = await spotifyConfig();
  if (!spotifyConfigured(config)) return NextResponse.json({ ok: false, error: 'Spotify sign-in is not set up on this server.' }, { status: 501 });

  const body = await request.json().catch(() => null) as { code?: unknown; codeVerifier?: unknown } | null;
  const code = typeof body?.code === 'string' ? body.code.trim() : undefined;
  const codeVerifier = typeof body?.codeVerifier === 'string' ? body.codeVerifier.trim() : undefined;
  if (!isValidAuthCode(code) || !isValidCodeVerifier(codeVerifier)) {
    return NextResponse.json({ ok: false, error: 'That is not a Spotify sign-in.' }, { status: 400 });
  }

  const token = await exchangeSpotifyCode(config, code, codeVerifier);
  if (token.kind === 'rejected') return NextResponse.json({ ok: false, error: 'Spotify did not accept that sign-in. Try again.' }, { status: 400 });
  if (token.kind === 'failed' || !token.refreshToken) return NextResponse.json({ ok: false, error: 'Spotify did not answer. Try again in a moment.' }, { status: 502 });

  const me = await fetchSpotifyProfile(token.accessToken);
  if (me.kind === 'forbidden') return NextResponse.json({ ok: false, error: "This Spotify account isn't on Resonote's allowlist yet." }, { status: 403 });
  if (me.kind === 'failed') return NextResponse.json({ ok: false, error: 'Spotify did not answer. Try again in a moment.' }, { status: 502 });
  try {
    const linkedAt = await saveLinkedSpotify(userId, me.profile, {
      accessToken: token.accessToken,
      expiresIn: token.expiresIn,
      refreshToken: token.refreshToken,
      scope: token.scope ?? SPOTIFY_SCOPES,
    });
    const { id, displayName = null, product = null } = me.profile;
    return NextResponse.json({ ok: true, account: { id, displayName, product, canPlay: canPlay(product), linkedAt } });
  } catch (error) {
    console.error('Resonote Spotify link failed', error);
    return NextResponse.json({ ok: false, error: 'Could not save your Spotify link. Try again in a moment.' }, { status: 500 });
  }
}
