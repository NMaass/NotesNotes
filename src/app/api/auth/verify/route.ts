import { NextRequest, NextResponse } from 'next/server';
import { consumeLoginCode, currentUser, isValidEmail, startSession } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { loadOwnBundle } from '@/lib/server/repo';

export const runtime = 'nodejs';

export async function POST(request: NextRequest) {
  void request;
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const body = await request.json().catch(() => ({}) as { email?: string; code?: string });
  const email = String(body.email ?? '');
  const code = String(body.code ?? '');
  if (!isValidEmail(email) || !/^\d{6}$/.test(code)) {
    return NextResponse.json({ ok: false, error: 'Check the address and the six-digit code.' }, { status: 400 });
  }
  const valid = await consumeLoginCode(email, code);
  if (!valid) return NextResponse.json({ ok: false, error: 'That code did not match. Request a fresh one.' }, { status: 401 });
  await startSession(email);
  const userId = await currentUser();
  const bundle = userId ? await loadOwnBundle(userId) : null;
  return NextResponse.json({ ok: true, bundle });
}
