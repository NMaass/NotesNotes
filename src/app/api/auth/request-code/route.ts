import { NextRequest, NextResponse } from 'next/server';
import { getDb } from '@/lib/server/db';
import { isValidEmail, issueLoginCode } from '@/lib/server/auth';

export const runtime = 'nodejs';

export async function POST(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const body = await request.json().catch(() => ({}) as { email?: string });
  const email = String(body.email ?? '');
  if (!isValidEmail(email)) return NextResponse.json({ ok: false, error: 'Enter a valid email address.' }, { status: 400 });
  try {
    const result = await issueLoginCode(email);
    return NextResponse.json({ ok: true, devCode: result.devCode });
  } catch (error) {
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : 'Could not send a code.' }, { status: 429 });
  }
}
