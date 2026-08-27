import { NextRequest, NextResponse } from 'next/server';
import { currentUser } from '@/lib/server/auth';
import { getDb } from '@/lib/server/db';
import { saveCollection, saveEntry, saveGenreAssertion, saveLike, saveListen, savePin, saveProfileFields } from '@/lib/server/repo';
import type { Collection, EntityKind, JournalEntry, ListenLog, ProfilePin, Profile } from '@/lib/data/types';

export const runtime = 'nodejs';

/**
 * Single authorized write surface. The session user is the only identity the
 * server trusts; profileId fields in payloads are ignored.
 */
export async function POST(request: NextRequest) {
  if (!(await getDb())) return NextResponse.json({ ok: false, error: 'Cloud data is not configured here.' }, { status: 503 });
  const userId = await currentUser();
  if (!userId) return NextResponse.json({ ok: false, error: 'Sign in to sync changes.' }, { status: 401 });

  const body = await request.json().catch(() => null) as Record<string, unknown> | null;
  if (!body || typeof body.op !== 'string') return NextResponse.json({ ok: false, error: 'Malformed sync payload.' }, { status: 400 });

  try {
    switch (body.op) {
      case 'like': {
        const payload = body as { entityId?: string; entityKind?: string; clientVersion?: number; liked?: boolean };
        if (!payload.entityId) break;
        await saveLike(userId, {
          entityId: String(payload.entityId),
          entityKind: (['artist', 'album', 'song', 'genre'].includes(String(payload.entityKind)) ? payload.entityKind : 'song') as EntityKind,
          clientVersion: Number(payload.clientVersion ?? 1),
          liked: Boolean(payload.liked),
          id: String(body.id ?? ''),
        });
        return NextResponse.json({ ok: true });
      }
      case 'genre-assertion': {
        const payload = body as { entityId?: string; entityKind?: string; genreId?: string; asserted?: boolean };
        if (!payload.entityId || !payload.genreId) break;
        await saveGenreAssertion(userId, {
          entityId: String(payload.entityId),
          entityKind: (['artist', 'album', 'song', 'genre'].includes(String(payload.entityKind)) ? payload.entityKind : 'song') as EntityKind,
          genreId: String(payload.genreId),
          asserted: Boolean(payload.asserted),
        });
        return NextResponse.json({ ok: true });
      }
      case 'entry': {
        await saveEntry(userId, body.entry as JournalEntry);
        return NextResponse.json({ ok: true });
      }
      case 'listen': {
        await saveListen(userId, body.listen as ListenLog);
        return NextResponse.json({ ok: true });
      }
      case 'collection': {
        await saveCollection(userId, body.collection as Collection);
        return NextResponse.json({ ok: true });
      }
      case 'pin': {
        const payload = body as { targetType?: ProfilePin['targetType']; targetId?: string; position?: number; pinned?: boolean };
        if (!payload.targetType || !payload.targetId) break;
        await savePin(userId, {
          targetType: payload.targetType,
          targetId: String(payload.targetId),
          position: Number(payload.position ?? 0),
          pinned: Boolean(payload.pinned),
        });
        return NextResponse.json({ ok: true });
      }
      case 'profile': {
        const profile = body.profile as Pick<Profile, 'displayName' | 'bio' | 'avatarUrl' | 'profileSongId' | 'genreIds'>;
        await saveProfileFields(userId, {
          displayName: String(profile.displayName ?? 'Listener').slice(0, 80),
          bio: String(profile.bio ?? '').slice(0, 600),
          avatarUrl: typeof profile.avatarUrl === 'string' ? profile.avatarUrl : undefined,
          profileSongId: typeof profile.profileSongId === 'string' ? profile.profileSongId : undefined,
          genreIds: Array.isArray(profile.genreIds) ? profile.genreIds.map(String).slice(0, 40) : [],
        });
        return NextResponse.json({ ok: true });
      }
      default:
        break;
    }
    return NextResponse.json({ ok: false, error: 'Unknown sync operation.' }, { status: 400 });
  } catch (error) {
    return NextResponse.json(
      { ok: false, error: error instanceof Error ? error.message : 'Sync failed.' },
      { status: 500 },
    );
  }
}
