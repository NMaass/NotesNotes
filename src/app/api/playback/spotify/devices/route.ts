import { NextResponse } from 'next/server';
import { mapSpotifyDevices, SPOTIFY_API } from '@/lib/music/spotify';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { callerSpotifyAccess, spotifyConfig, spotifyConfigured, spotifyFetch } from '@/lib/server/spotify';

export const runtime = 'nodejs';

/** The caller's Spotify Connect devices (GET /v1/me/player/devices), for picking where to play. */
export async function GET() {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to play through Spotify.' }, { status: 401 });
  if (!spotifyConfigured(await spotifyConfig())) return NextResponse.json({ ok: false, error: 'Spotify sign-in is not set up on this server.' }, { status: 501 });

  try {
    const access = await callerSpotifyAccess(userId);
    if (access.kind === 'not-linked') return NextResponse.json({ ok: false, error: 'not-linked', message: 'Sign in with Spotify first.' }, { status: 409 });
    if (access.kind === 'failed') return NextResponse.json({ ok: false, error: 'Spotify did not answer. Try again in a moment.' }, { status: 502 });
    const response = await spotifyFetch(access.accessToken, `${SPOTIFY_API}/me/player/devices`);
    if (!response?.ok) return NextResponse.json({ ok: false, error: 'Spotify did not answer. Try again in a moment.' }, { status: 502 });
    return NextResponse.json({ ok: true, devices: mapSpotifyDevices(await response.json().catch(() => null)) }, { headers: { 'Cache-Control': 'no-store' } });
  } catch (error) {
    console.error('Resonote Spotify devices failed', error);
    return NextResponse.json({ ok: false, error: 'Could not reach Spotify. Try again in a moment.' }, { status: 502 });
  }
}
