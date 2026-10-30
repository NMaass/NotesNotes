import { NextResponse } from 'next/server';
import { currentUser, endSession } from '@/lib/server/auth';
import { all, batch, first, getDb, sql, type Statement } from '@/lib/server/db';

export const runtime = 'nodejs';

/** Tables added by later migrations; deletion skips any this database doesn't have yet. */
async function existingTables(names: string[]): Promise<Set<string>> {
  const rows = await all<{ name: string }>(
    `select name from sqlite_master where type = 'table' and name in (${names.map(() => '?').join(',')})`,
    ...names,
  );
  return new Set(rows.map((row) => row.name));
}

/**
 * Deletes the signed-in account and everything it made (App Store guideline
 * 5.1.1(v)): entries and their references, listens, likes, collections and their
 * items, pins (and other people's pins of this person's entries and collections),
 * genre tags, reports and blocks, linked scrobbling accounts, the profile, every
 * session on every device, and sign-in codes. One D1 batch, so it happens
 * completely or not at all.
 */
export async function DELETE() {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to delete your account.' }, { status: 401 });

  try {
    const user = await first<{ email: string }>('select email from users where id = ?', userId);
    const optional = await existingTables(['content_reports', 'profile_blocks', 'login_failures', 'linked_accounts']);
    const statements: Statement[] = [
      sql("delete from profile_pins where target_type = 'entry' and target_id in (select id from journal_entries where profile_id = ?)", userId),
      sql("delete from profile_pins where target_type = 'collection' and target_id in (select id from collections where profile_id = ?)", userId),
      sql('delete from profile_pins where profile_id = ?', userId),
      sql('delete from entry_references where entry_id in (select id from journal_entries where profile_id = ?)', userId),
      sql('delete from journal_entries where profile_id = ?', userId),
      sql('delete from collection_items where collection_id in (select id from collections where profile_id = ?)', userId),
      sql('delete from collections where profile_id = ?', userId),
      sql('delete from listen_logs where profile_id = ?', userId),
      sql('delete from likes where profile_id = ?', userId),
      sql('delete from entity_genres where created_by = ?', userId),
    ];
    if (optional.has('content_reports')) statements.push(sql('delete from content_reports where reporter_id = ?', userId));
    if (optional.has('linked_accounts')) statements.push(sql('delete from linked_accounts where profile_id = ?', userId));
    if (optional.has('profile_blocks')) statements.push(sql('delete from profile_blocks where blocker_id = ? or blocked_id = ?', userId, userId));
    statements.push(
      sql('delete from sessions where user_id = ?', userId),
      sql('delete from profiles where id = ?', userId),
    );
    if (user) {
      statements.push(sql('delete from otp_codes where email = ?', user.email));
      if (optional.has('login_failures')) statements.push(sql('delete from login_failures where email = ?', user.email));
    }
    statements.push(sql('delete from users where id = ?', userId));
    await batch(statements);
  } catch (error) {
    console.error('Resonote account deletion failed', error);
    return NextResponse.json({ ok: false, error: 'Your account could not be deleted. Try again in a moment.' }, { status: 500 });
  }

  // Every session row is gone already; this clears a web session cookie.
  await endSession().catch(() => undefined);
  return NextResponse.json({ ok: true });
}
