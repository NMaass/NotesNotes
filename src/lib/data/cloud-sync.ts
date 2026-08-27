'use client';

import type {
  Collection,
  EntityGenre,
  EntityKind,
  JournalEntry,
  Like,
  ListenLog,
  Profile,
  ProfileBundle,
  ProfilePin,
} from '@/lib/data/types';
import type { CatalogSlice } from '@/lib/server/repo';

export interface CloudBundle extends ProfileBundle { catalog: CatalogSlice }

async function post(op: string, payload: Record<string, unknown>): Promise<void> {
  const response = await fetch('/api/sync', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ op, ...payload }),
  });
  const body = await response.json().catch(() => ({}) as { ok?: boolean; error?: string });
  if (!response.ok || !body.ok) throw new Error(body.error ?? 'Sync failed.');
}

function withProfileId<T extends { profileId: string }>(object: T): T {
  // The server trusts only the session cookie; this field is stripped of meaning.
  return object;
}

export async function syncLike(like: Like | null, entityId: string) {
  void entityId;
  await post('like', {
    id: like?.id ?? '',
    entityId: like?.entityId,
    entityKind: like?.entityKind,
    clientVersion: like?.clientVersion ?? 1,
    liked: Boolean(like),
  });
}

export async function syncGenreAssertion(assertion: EntityGenre | null, entityId: string, entityKind: EntityKind, genreId: string) {
  await post('genre-assertion', { entityId, entityKind, genreId, asserted: Boolean(assertion) });
  void assertion;
}

export async function syncEntry(entry: JournalEntry) {
  await post('entry', { entry: withProfileId(entry) });
}

export async function syncListen(listen: ListenLog) {
  await post('listen', { listen: withProfileId(listen) });
}

export async function syncCollection(collection: Collection) {
  await post('collection', { collection: withProfileId(collection) });
}

export async function syncPin(pin: ProfilePin | null, targetType: ProfilePin['targetType'], targetId: string) {
  await post('pin', { targetType, targetId, position: pin?.position ?? 0, pinned: Boolean(pin) });
}

export async function syncProfile(profile: Profile) {
  await post('profile', {
    profile: {
      displayName: profile.displayName,
      bio: profile.bio,
      avatarUrl: profile.avatarUrl,
      profileSongId: profile.profileSongId,
      genreIds: profile.genreIds,
    },
  });
}

async function getJson<T>(url: string): Promise<T> {
  const response = await fetch(url);
  const body = await response.json().catch(() => ({}) as T & { ok?: boolean; error?: string });
  if (!response.ok || (body as { ok?: boolean }).ok === false) throw new Error((body as { error?: string }).error ?? 'Request failed.');
  return body;
}

export async function loadProfileBundleByHandle(handle: string): Promise<CloudBundle> {
  return getJson<CloudBundle>(`/api/profiles/${encodeURIComponent(handle.replace(/^@/, ''))}`);
}

export async function loadSessionBundle(): Promise<CloudBundle | null> {
  const body = await fetch('/api/auth/session').then((response) => response.json()) as { authenticated?: boolean; bundle?: CloudBundle };
  return body.authenticated && body.bundle ? body.bundle : null;
}

/** Resolve an /music/... slug path against D1-only imports. */
export async function loadCatalogByPath(path: string): Promise<CatalogSlice> {
  const body = await getJson<{ catalog: CatalogSlice }>(`/api/catalog/path?path=${encodeURIComponent(path)}`);
  return body.catalog;
}
