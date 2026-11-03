import { NextResponse } from 'next/server';
import { canPlay } from '@/lib/music/spotify';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { deleteLinkedSpotify, linkedSpotify, spotifyConfig, spotifyConfigured } from '@/lib/server/spotify';

export const runtime = 'nodejs';

/** Whether Spotify sign-in is set up here, and the caller's linked account (never its tokens). */
export async function GET() {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to link Spotify.' }, { status: 401 });
  try {
    const [config, linked] = await Promise.all([spotifyConfig(), linkedSpotify(userId)]);
    const account = linked
      ? { id: linked.spotifyUserId, displayName: linked.displayName, product: linked.product, canPlay: canPlay(linked.product), linkedAt: linked.linkedAt }
      : null;
    return NextResponse.json({ ok: true, configured: spotifyConfigured(config), account }, { headers: { 'Cache-Control': 'no-store' } });
  } catch (error) {
    console.error('Resonote Spotify account read failed', error);
    return NextResponse.json({ ok: false, error: 'Could not read your Spotify link.' }, { status: 500 });
  }
}

/** Unlinks the caller's Spotify account. Idempotent; Spotify has no revoke endpoint to call. */
export async function DELETE() {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to unlink Spotify.' }, { status: 401 });
  try {
    await deleteLinkedSpotify(userId);
    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error('Resonote Spotify unlink failed', error);
    return NextResponse.json({ ok: false, error: 'Could not unlink Spotify. Try again in a moment.' }, { status: 500 });
  }
}
