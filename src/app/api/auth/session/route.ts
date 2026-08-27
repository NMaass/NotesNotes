import { NextResponse } from 'next/server';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { loadOwnBundle } from '@/lib/server/repo';

export const runtime = 'nodejs';

export async function GET() {
  if (!(await getDb())) return NextResponse.json({ authenticated: false });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ authenticated: false });
  try {
    const bundle = await loadOwnBundle(userId);
    return NextResponse.json({ authenticated: true, bundle });
  } catch {
    return NextResponse.json({ authenticated: false });
  }
}
