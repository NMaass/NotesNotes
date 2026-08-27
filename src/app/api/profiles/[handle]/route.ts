import { NextResponse } from 'next/server';
import { getDb } from '@/lib/server/db';
import { loadPublicBundleByHandle } from '@/lib/server/repo';

export const runtime = 'nodejs';

export async function GET(_request: Request, context: { params: Promise<{ handle: string }> }) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const { handle } = await context.params;
  try {
    const bundle = await loadPublicBundleByHandle(decodeURIComponent(handle));
    return NextResponse.json({ ok: true, bundle });
  } catch (error) {
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : 'Profile not found.' }, { status: 404 });
  }
}
