import { NextRequest, NextResponse } from 'next/server';
import { callbackScheme, isValidAuthState, isValidCodeChallenge, spotifyAuthUrl } from '@/lib/music/spotify';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { spotifyConfig, spotifyConfigured } from '@/lib/server/spotify';

export const runtime = 'nodejs';

/**
 * The accounts.spotify.com page where the person approves Resonote. The app makes the
 * PKCE verifier and state and sends only the S256 challenge; Spotify calls back to
 * the redirect URI (resonote://spotify-auth) with `?code=&state=`.
 */
export async function GET(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to link Spotify.' }, { status: 401 });
  const config = await spotifyConfig();
  if (!spotifyConfigured(config)) return NextResponse.json({ ok: false, error: 'Spotify sign-in is not set up on this server.' }, { status: 501 });

  const params = request.nextUrl.searchParams;
  const codeChallenge = params.get('code_challenge') ?? undefined;
  const state = params.get('state') ?? undefined;
  if (!isValidCodeChallenge(codeChallenge)) {
    return NextResponse.json({ ok: false, error: 'code_challenge must be an S256 challenge (43–128 base64url characters).' }, { status: 400 });
  }
  if (!isValidAuthState(state)) {
    return NextResponse.json({ ok: false, error: 'state must be 16–128 letters, digits, - or _.' }, { status: 400 });
  }
  return NextResponse.json(
    {
      ok: true,
      url: spotifyAuthUrl({ clientId: config.clientId, redirectUri: config.redirectUri, codeChallenge, state }),
      callbackScheme: callbackScheme(config.redirectUri),
      redirectUri: config.redirectUri,
    },
    { headers: { 'Cache-Control': 'no-store' } },
  );
}
