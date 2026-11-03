import { NextRequest, NextResponse } from 'next/server';
import { parsePlaybackRequest, playbackCall, playbackOutcome } from '@/lib/music/spotify';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { callerSpotifyAccess, spotifyConfig, spotifyConfigured, spotifyFetch } from '@/lib/server/spotify';

export const runtime = 'nodejs';

/**
 * Plays, pauses or skips on the caller's Spotify Connect device through the Web API
 * (Premium only). `play` with `spotifyId` starts that track; without it, resumes.
 * Errors the app acts on carry a code in `error`: `not-linked`, `no-device` (open
 * Spotify somewhere first), `premium-required`.
 */
export async function POST(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to play through Spotify.' }, { status: 401 });
  if (!spotifyConfigured(await spotifyConfig())) return NextResponse.json({ ok: false, error: 'Spotify sign-in is not set up on this server.' }, { status: 501 });

  const command = parsePlaybackRequest(await request.json().catch(() => null));
  if (!command) return NextResponse.json({ ok: false, error: 'That is not a playback request.' }, { status: 400 });

  try {
    const access = await callerSpotifyAccess(userId);
    if (access.kind === 'not-linked') return NextResponse.json({ ok: false, error: 'not-linked', message: 'Sign in with Spotify first.' }, { status: 409 });
    if (access.kind === 'failed') return NextResponse.json({ ok: false, error: 'Spotify did not answer. Try again in a moment.' }, { status: 502 });
    const call = playbackCall(command);
    const response = await spotifyFetch(access.accessToken, call.url, { method: call.method, body: call.body });
    const outcome = response ? playbackOutcome(response.status) : 'failed';
    if (outcome === 'ok') return NextResponse.json({ ok: true });
    if (outcome === 'no-device') return NextResponse.json({ ok: false, error: 'no-device', message: 'Open Spotify on a device first.' }, { status: 409 });
    if (outcome === 'premium-required') {
      return NextResponse.json({ ok: false, error: 'premium-required', message: 'Playing through Spotify needs Spotify Premium.' }, { status: 403 });
    }
    return NextResponse.json({ ok: false, error: 'Spotify did not answer. Try again in a moment.' }, { status: 502 });
  } catch (error) {
    console.error('Resonote Spotify playback failed', error);
    return NextResponse.json({ ok: false, error: 'Could not reach Spotify. Try again in a moment.' }, { status: 502 });
  }
}
