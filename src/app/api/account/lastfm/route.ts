import { NextResponse } from 'next/server';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { deleteLinkedLastfm, lastfmConfig, linkedLastfm, webAuthConfigured } from '@/lib/server/lastfm';

export const runtime = 'nodejs';

/** Whether Last.fm sign-in is set up here, and the caller's linked account (never its session key). */
export async function GET() {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to link Last.fm.' }, { status: 401 });
  try {
    const [config, linked] = await Promise.all([lastfmConfig(), linkedLastfm(userId)]);
    return NextResponse.json(
      { ok: true, configured: webAuthConfigured(config), account: linked ? { username: linked.username, linkedAt: linked.linkedAt } : null },
      { headers: { 'Cache-Control': 'no-store' } },
    );
  } catch (error) {
    console.error('Resonote Last.fm account read failed', error);
    return NextResponse.json({ ok: false, error: 'Could not read your Last.fm link.' }, { status: 500 });
  }
}

/** Unlinks the caller's Last.fm account. Idempotent. */
export async function DELETE() {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to unlink Last.fm.' }, { status: 401 });
  try {
    await deleteLinkedLastfm(userId);
    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error('Resonote Last.fm unlink failed', error);
    return NextResponse.json({ ok: false, error: 'Could not unlink Last.fm. Try again in a moment.' }, { status: 500 });
  }
}
