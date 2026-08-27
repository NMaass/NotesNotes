import { NextResponse } from 'next/server';
import { getDb } from '@/lib/server/db';
export async function GET() { const db = await getDb(); return NextResponse.json({ ok: true, service: 'resonote', mode: process.env.NEXT_PUBLIC_DATA_MODE ?? 'demo', database: db ? 'd1' : 'local-only' }); }
