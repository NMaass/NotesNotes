import { NextRequest, NextResponse } from 'next/server';
import { consumeLoginCode, isValidEmail, startSession } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { loadOwnBundle } from '@/lib/server/repo';

export const runtime = 'nodejs';

export async function POST(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const body = await request.json().catch(() => ({}) as { email?: string; code?: string; client?: string });
  const email = String(body.email ?? '');
  const code = String(body.code ?? '');
  if (!isValidEmail(email) || !/^\d{6}$/.test(code)) {
    return NextResponse.json({ ok: false, error: 'Check the address and the six-digit code.' }, { status: 400 });
  }
  const check = await consumeLoginCode(email, code);
  if (check === 'locked') {
    return NextResponse.json({ ok: false, error: 'Too many wrong codes. Wait ten minutes, then request a new one.' }, { status: 429 });
  }
  if (check !== 'ok') return NextResponse.json({ ok: false, error: 'That code did not match. Request a fresh one.' }, { status: 401 });

  // Native clients hold a bearer token instead of a cookie.
  if (body.client === 'ios') {
    const session = await startSession(email, 'native');
    const bundle = await loadOwnBundle(session.userId);
    return NextResponse.json(
      { ok: true, bundle, token: session.token, expiresAt: session.expiresAt },
      { headers: { 'Cache-Control': 'no-store' } },
    );
  }

  const session = await startSession(email);
  const bundle = await loadOwnBundle(session.userId);
  return NextResponse.json({ ok: true, bundle });
}
