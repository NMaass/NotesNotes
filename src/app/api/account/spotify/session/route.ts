import { NextRequest, NextResponse } from 'next/server';
import { canPlay, isValidAuthCode, isValidCodeVerifier, SPOTIFY_SCOPES } from '@/lib/music/spotify';
import { currentUser, startSession, startSessionForUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { loadOwnBundle } from '@/lib/server/repo';
import { exchangeSpotifyCode, fetchSpotifyProfile, profileForSpotifyUser, saveLinkedSpotify, spotifyConfig, spotifyConfigured } from '@/lib/server/spotify';

export const runtime = 'nodejs';

/**
 * Trades the code from resonote://spotify-auth?code= (with the app's PKCE verifier)
 * for tokens, reads the account with GET /v1/me, and links it to the caller
 * (relinking replaces the old link). The tokens are stored, never returned. A code
 * works once, so a resent request is a 400.
 *
 * Signed out, with `client: "ios"`, this is Sign in with Spotify: the Resonote account
 * already linked to that Spotify account signs in, or a new one is made for it. A new
 * account never takes the Spotify email (Spotify doesn't verify it, and an existing
 * Resonote account must not be reachable through it); its address is a placeholder
 * no one can request a code for. The response then also carries the bundle and token.
 */
export async function POST(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const signedIn = await currentUser();
  const config = await spotifyConfig();
  if (!spotifyConfigured(config)) return NextResponse.json({ ok: false, error: 'Spotify sign-in is not set up on this server.' }, { status: 501 });

  const body = await request.json().catch(() => null) as { code?: unknown; codeVerifier?: unknown; client?: unknown } | null;
  if (!signedIn && body?.client !== 'ios') return NextResponse.json({ ok: false, error: 'Sign in to link Spotify.' }, { status: 401 });
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
    let userId = signedIn;
    let session: { token?: string; expiresAt: string } | null = null;
    if (!userId) {
      const existing = await profileForSpotifyUser(me.profile.id);
      const started = existing
        ? await startSessionForUser(existing)
        : await startSession(spotifyPlaceholderEmail(me.profile.id), 'native', me.profile.displayName);
      if (!started) return NextResponse.json({ ok: false, error: 'Could not sign you in. Try again in a moment.' }, { status: 500 });
      userId = started.userId;
      session = started;
    }
    const linkedAt = await saveLinkedSpotify(userId, me.profile, {
      accessToken: token.accessToken,
      expiresIn: token.expiresIn,
      refreshToken: token.refreshToken,
      scope: token.scope ?? SPOTIFY_SCOPES,
    });
    const { id, displayName = null, product = null } = me.profile;
    const account = { id, displayName, product, canPlay: canPlay(product), linkedAt };
    if (session) {
      const bundle = await loadOwnBundle(userId);
      return NextResponse.json(
        { ok: true, account, bundle, token: session.token, expiresAt: session.expiresAt },
        { headers: { 'Cache-Control': 'no-store' } },
      );
    }
    return NextResponse.json({ ok: true, account });
  } catch (error) {
    console.error('Resonote Spotify link failed', error);
    return NextResponse.json({ ok: false, error: 'Could not save your Spotify link. Try again in a moment.' }, { status: 500 });
  }
}

/** Not deliverable (.invalid is reserved), so no one can sign in to it with an email code. */
function spotifyPlaceholderEmail(spotifyUserId: string): string {
  return `spotify-${spotifyUserId.toLowerCase().replace(/[^a-z0-9]/g, '')}@users.resonote.invalid`;
}
