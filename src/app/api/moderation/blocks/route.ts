import { NextRequest, NextResponse } from 'next/server';
import { currentUser } from '@/lib/server/auth';
import { all, getDb, run } from '@/lib/server/db';

export const runtime = 'nodejs';

type ProfileRow = {
  id: string;
  handle: string;
  display_name: string;
  bio: string;
  avatar_url: string | null;
  profile_song_id: string | null;
  genre_ids: string;
};

function genreIds(value: string): string[] {
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.map(String) : [];
  } catch {
    return [];
  }
}

async function signedIn(): Promise<string | NextResponse> {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to manage blocked people.' }, { status: 401 });
  return userId;
}

/**
 * People the signed-in person has blocked (App Store guideline 1.2). Clients hide
 * blocked people's writing everywhere. `GET` lists them; `POST { profileId }` blocks;
 * `DELETE ?profileId=` unblocks. Both writes are idempotent.
 */
export async function GET() {
  const userId = await signedIn();
  if (typeof userId !== 'string') return userId;
  try {
    const rows = await all<ProfileRow>(
      `select p.id, p.handle, p.display_name, p.bio, p.avatar_url, p.profile_song_id, p.genre_ids
         from profile_blocks b join profiles p on p.id = b.blocked_id
        where b.blocker_id = ? order by b.created_at`,
      userId,
    );
    const profiles = rows.map((row) => ({
      id: row.id,
      handle: row.handle,
      displayName: row.display_name,
      bio: row.bio,
      avatarUrl: row.avatar_url ?? undefined,
      profileSongId: row.profile_song_id ?? undefined,
      genreIds: genreIds(row.genre_ids),
    }));
    return NextResponse.json({ ok: true, profiles });
  } catch (error) {
    console.error('Resonote blocks read failed', error);
    return NextResponse.json({ ok: false, error: 'Blocked people could not be loaded.' }, { status: 500 });
  }
}

export async function POST(request: NextRequest) {
  const userId = await signedIn();
  if (typeof userId !== 'string') return userId;
  const body = await request.json().catch(() => null) as { profileId?: unknown } | null;
  const profileId = typeof body?.profileId === 'string' ? body.profileId : '';
  if (!profileId || profileId === userId) return NextResponse.json({ ok: false, error: 'Choose someone else to block.' }, { status: 400 });
  try {
    await run('insert into profile_blocks (blocker_id, blocked_id) select ?, id from profiles where id = ? on conflict do nothing', userId, profileId);
    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error('Resonote block failed', error);
    return NextResponse.json({ ok: false, error: 'That person could not be blocked.' }, { status: 500 });
  }
}

export async function DELETE(request: NextRequest) {
  const userId = await signedIn();
  if (typeof userId !== 'string') return userId;
  const profileId = request.nextUrl.searchParams.get('profileId') ?? '';
  if (!profileId) return NextResponse.json({ ok: false, error: 'Choose someone to unblock.' }, { status: 400 });
  try {
    await run('delete from profile_blocks where blocker_id = ? and blocked_id = ?', userId, profileId);
    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error('Resonote unblock failed', error);
    return NextResponse.json({ ok: false, error: 'That person could not be unblocked.' }, { status: 500 });
  }
}
