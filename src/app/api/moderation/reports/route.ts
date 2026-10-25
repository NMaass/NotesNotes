import { randomUUID } from 'node:crypto';
import { NextRequest, NextResponse } from 'next/server';
import { currentUser } from '@/lib/server/auth';
import { getDb, run } from '@/lib/server/db';

export const runtime = 'nodejs';

const TARGETS = new Set(['entry', 'profile']);
const REASONS = new Set(['spam', 'harassment', 'hate', 'sexual', 'other']);

/**
 * Records a report of someone's entry or profile for the people who run Resonote to
 * review (App Store guideline 1.2). Body: `{ targetType, targetId, reason }`.
 * Reporting the same thing twice keeps one report.
 */
export async function POST(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to report something.' }, { status: 401 });

  const body = await request.json().catch(() => null) as { targetType?: unknown; targetId?: unknown; reason?: unknown } | null;
  const targetType = typeof body?.targetType === 'string' ? body.targetType : '';
  const targetId = typeof body?.targetId === 'string' ? body.targetId.slice(0, 200) : '';
  const reason = typeof body?.reason === 'string' ? body.reason : '';
  if (!TARGETS.has(targetType) || !targetId || !REASONS.has(reason)) {
    return NextResponse.json({ ok: false, error: 'A report needs a target and a reason.' }, { status: 400 });
  }

  try {
    await run(
      'insert into content_reports (id, reporter_id, target_type, target_id, reason) values (?, ?, ?, ?, ?) on conflict (reporter_id, target_type, target_id) do update set reason = excluded.reason',
      randomUUID(), userId, targetType, targetId, reason,
    );
    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error('Resonote report failed', error);
    return NextResponse.json({ ok: false, error: 'The report could not be saved.' }, { status: 500 });
  }
}
