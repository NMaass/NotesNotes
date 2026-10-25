import { NextResponse } from 'next/server';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { loadOwnBundle } from '@/lib/server/repo';

export const runtime = 'nodejs';

/**
 * `{ authenticated: false }` means only "this request has no valid session". When the
 * database is missing or the bundle can't be read, the response is an error instead,
 * so a client never mistakes a server hiccup for being signed out (the iOS app keeps
 * its local journal and queued writes through errors).
 */
export async function GET() {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  let userId: string | null;
  try {
    userId = await currentUser();
  } catch {
    return NextResponse.json({ ok: false, error: 'The session could not be checked.' }, { status: 500 });
  }
  if (!userId) return NextResponse.json({ authenticated: false });
  try {
    const bundle = await loadOwnBundle(userId);
    return NextResponse.json({ authenticated: true, bundle });
  } catch {
    return NextResponse.json({ ok: false, error: 'Your journal could not be loaded.' }, { status: 500 });
  }
}
