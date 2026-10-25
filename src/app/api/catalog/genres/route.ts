import { NextResponse } from 'next/server';
import { genres as seedGenres } from '@/lib/data/catalog';
import { listGenres } from '@/lib/server/catalog';
import { getDb } from '@/lib/server/db';

export const runtime = 'nodejs';

/** Seeded genres plus genres stored in D1 (MusicBrainz community genres). */
export async function GET() {
  if (!(await getDb())) return NextResponse.json({ genres: seedGenres });
  try {
    return NextResponse.json({ genres: await listGenres() });
  } catch (error) {
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : 'Could not load genres.' }, { status: 500 });
  }
}
