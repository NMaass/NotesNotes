'use client';

import { create } from 'zustand';
import { createJSONStorage, persist } from 'zustand/middleware';
import { toast } from 'sonner';
import { seedDemoData } from '@/lib/data/catalog';
import { emptyImportedCatalog, registerImportedCatalog, type ImportedCatalogBundle } from '@/lib/data/imported-catalog';
import { getEntityById } from '@/lib/data/selectors';
import type {
  Collection,
  DemoData,
  EntityGenre,
  EntityKind,
  JournalEntry,
  ListenLog,
  Profile,
  ProfileBundle,
  ProfilePin,
  Song,
} from '@/lib/data/types';
import { dataMode } from '@/lib/data/config';
import {
  syncCollection,
  syncEntry,
  syncGenreAssertion,
  syncLike,
  syncListen,
  syncPin,
  syncProfile,
} from '@/lib/data/cloud-sync';
import { slugify, uid } from '@/lib/utils';

export interface PlayerState {
  songId: string | null;
  playing: boolean;
  expanded: boolean;
  pendingSeekMs: number | null;
}

interface ResonoteState {
  data: DemoData;
  activeProfileId: string | null;
  hydrated: boolean;
  player: PlayerState;
  importedEntities: ImportedCatalogBundle;
  setHydrated: (value: boolean) => void;
  importCatalogBundle: (bundle: ImportedCatalogBundle) => void;
  signInDemo: () => void;
  signInProfile: (bundle: ProfileBundle) => void;
  mergeProfileBundle: (bundle: ProfileBundle) => void;
  signOut: () => void;
  toggleLike: (entityId: string, entityKind: EntityKind) => void;
  toggleGenreAssertion: (entityId: string, entityKind: EntityKind, genreId: string) => void;
  saveEntry: (entry: JournalEntry) => void;
  logListen: (songId: string, moods: string[], note?: string) => void;
  createCollection: (name: string, description: string) => Collection | null;
  addToCollection: (collectionId: string, entityId: string, entityKind: EntityKind, note?: string) => void;
  removeFromCollection: (collectionId: string, itemId: string) => void;
  togglePin: (targetType: ProfilePin['targetType'], targetId: string) => void;
  setProfileSong: (songId: string) => void;
  setGenrePreferences: (genreIds: string[]) => void;
  playSong: (songId: string) => void;
  playSongFrom: (songId: string, fraction: number) => void;
  consumePendingSeek: () => number | null;
  togglePlayback: () => void;
  setPlaybackState: (playing: boolean) => void;
  stopPlayback: () => void;
  setPlayerExpanded: (value: boolean) => void;
  resetDemo: () => void;
}

const cloneSeed = (): DemoData => JSON.parse(JSON.stringify(seedDemoData)) as DemoData;
const emptyData = (): DemoData => ({ profiles: [], likes: [], entries: [], listens: [], collections: [], pins: [], genreAssertions: [] });
const initialData = (): DemoData => dataMode === 'demo' ? cloneSeed() : emptyData();
const writeQueues = new Map<string, Promise<void>>();
const likeVersions = new Map<string, number>();

function queueWrite(key: string, write: () => Promise<void>) {
  const prior = writeQueues.get(key) ?? Promise.resolve();
  let next: Promise<void>;
  next = prior
    .catch(() => undefined)
    .then(write)
    .catch((error: unknown) => {
      console.error(`Resonote sync failed for ${key}`, error);
      if (dataMode === 'cloud') {
        toast.error('Saved on this device, but the server did not sync.', {
          description: 'Check your connection before closing this tab.',
        });
      }
    })
    .finally(() => {
      if (writeQueues.get(key) === next) writeQueues.delete(key);
    });
  writeQueues.set(key, next);
}

function replaceProfileRows<T extends { profileId: string }>(rows: T[], profileId: string, incoming: T[]) {
  return [...rows.filter((row) => row.profileId !== profileId), ...incoming];
}

function mergeBundle(data: DemoData, bundle: ProfileBundle): DemoData {
  const profileId = bundle.profile.id;
  return {
    profiles: [
      ...data.profiles.filter((profile) => profile.id !== profileId && profile.handle !== bundle.profile.handle),
      bundle.profile,
    ],
    likes: replaceProfileRows(data.likes, profileId, bundle.likes),
    entries: replaceProfileRows(data.entries, profileId, bundle.entries),
    listens: replaceProfileRows(data.listens, profileId, bundle.listens),
    collections: replaceProfileRows(data.collections, profileId, bundle.collections),
    pins: replaceProfileRows(data.pins, profileId, bundle.pins),
    genreAssertions: [
      ...(data.genreAssertions ?? []).filter((row) => row.createdBy !== profileId),
      ...bundle.genreAssertions,
    ],
  };
}

function removePrivateProfileData(data: DemoData, profileId: string): DemoData {
  return {
    profiles: data.profiles.filter((profile) => profile.id !== profileId),
    likes: data.likes.filter((row) => row.profileId !== profileId),
    entries: data.entries.filter((row) => row.profileId !== profileId),
    listens: data.listens.filter((row) => row.profileId !== profileId),
    collections: data.collections.filter((row) => row.profileId !== profileId),
    pins: data.pins.filter((row) => row.profileId !== profileId),
    genreAssertions: (data.genreAssertions ?? []).filter((row) => row.createdBy !== profileId),
  };
}

function updatedProfile(data: DemoData, profileId: string, update: (profile: Profile) => Profile) {
  let changed: Profile | null = null;
  const profiles = data.profiles.map((profile) => {
    if (profile.id !== profileId) return profile;
    changed = update(profile);
    return changed;
  });
  return { data: { ...data, profiles }, profile: changed };
}

export const useResonoteStore = create<ResonoteState>()(
  persist(
    (set, get) => ({
      data: initialData(),
      activeProfileId: null,
      hydrated: false,
      player: { songId: null, playing: false, expanded: false, pendingSeekMs: null },
      importedEntities: emptyImportedCatalog(),
      setHydrated: (hydrated) => set({ hydrated }),
      importCatalogBundle: (bundle) => {
        registerImportedCatalog(bundle);
        set((state) => ({
          importedEntities: {
            artists: [...state.importedEntities.artists.filter((a) => !bundle.artists.some((b) => b.id === a.id)), ...bundle.artists],
            albums: [...state.importedEntities.albums.filter((a) => !bundle.albums.some((b) => b.id === a.id)), ...bundle.albums],
            songs: [...state.importedEntities.songs.filter((a) => !bundle.songs.some((b) => b.id === a.id)), ...bundle.songs],
          },
        }));
      },
      signInDemo: () => set({ activeProfileId: '50000000-0000-0000-0000-000000000001' }),
      signInProfile: (bundle) => set((state) => ({
        data: mergeBundle(state.data, bundle),
        activeProfileId: bundle.profile.id,
      })),
      mergeProfileBundle: (bundle) => set((state) => ({ data: mergeBundle(state.data, bundle) })),
      signOut: () => set((state) => ({
        activeProfileId: null,
        data: dataMode === 'cloud' && state.activeProfileId
          ? removePrivateProfileData(state.data, state.activeProfileId)
          : state.data,
        player: { songId: null, playing: false, expanded: false, pendingSeekMs: null },
      })),
      toggleLike: (entityId, entityKind) => {
        const { activeProfileId, data } = get();
        if (!activeProfileId) return;
        const existing = data.likes.find((like) => like.profileId === activeProfileId && like.entityId === entityId);
        const queueKey = `like:${activeProfileId}:${entityId}`;
        const persistedVersion = Math.max(
          0,
          ...data.likes
            .filter((like) => like.profileId === activeProfileId && like.entityId === entityId)
            .map((like) => like.clientVersion),
        );
        const clientVersion = Math.max(likeVersions.get(queueKey) ?? 0, persistedVersion) + 1;
        likeVersions.set(queueKey, clientVersion);
        const nextLike = existing ? null : {
          id: uid('like'),
          profileId: activeProfileId,
          entityId,
          entityKind,
          clientVersion,
          createdAt: new Date().toISOString(),
        };
        set({
          data: {
            ...data,
            likes: existing
              ? data.likes.filter((like) => like.id !== existing.id)
              : [...data.likes, nextLike!],
          },
        });
        queueWrite(queueKey, () => syncLike(nextLike, entityId));
      },
      toggleGenreAssertion: (entityId, entityKind, genreId) => {
        const { activeProfileId, data } = get();
        if (!activeProfileId) return;
        const assertions = data.genreAssertions ?? [];
        const existing = assertions.find((row) =>
          row.createdBy === activeProfileId && row.entityId === entityId && row.genreId === genreId
        );
        const assertion: EntityGenre | null = existing ? null : {
          id: uid('genre-assertion'),
          entityId,
          entityKind,
          genreId,
          source: 'user',
          createdBy: activeProfileId,
          votes: 1,
        };
        set({
          data: {
            ...data,
            genreAssertions: existing
              ? assertions.filter((row) => row.id !== existing.id)
              : [...assertions, assertion!],
          },
        });
        queueWrite(`genre:${activeProfileId}:${entityId}:${genreId}`, () =>
          syncGenreAssertion(assertion, entityId, entityKind, genreId)
        );
      },
      saveEntry: (entry) => {
        const data = get().data;
        const exists = data.entries.some((candidate) => candidate.id === entry.id);
        set({
          data: {
            ...data,
            entries: exists
              ? data.entries.map((candidate) => candidate.id === entry.id ? entry : candidate)
              : [entry, ...data.entries],
          },
        });
        queueWrite(`entry:${entry.id}`, () => syncEntry(entry));
      },
      logListen: (songId, moods, note) => {
        const { activeProfileId, data } = get();
        if (!activeProfileId) return;
        const listen: ListenLog = {
          id: uid('listen'),
          profileId: activeProfileId,
          songId,
          moods,
          note,
          listenedAt: new Date().toISOString(),
        };
        set({ data: { ...data, listens: [listen, ...data.listens] } });
        queueWrite(`listen:${listen.id}`, () => syncListen(listen));
      },
      createCollection: (name, description) => {
        const { activeProfileId, data } = get();
        if (!activeProfileId || !name.trim()) return null;
        const now = new Date().toISOString();
        const baseSlug = slugify(name);
        const occupied = new Set(
          data.collections
            .filter((collection) => collection.profileId === activeProfileId)
            .map((collection) => collection.slug),
        );
        let slug = baseSlug || 'untitled-collection';
        let suffix = 2;
        while (occupied.has(slug)) {
          slug = `${baseSlug || 'untitled-collection'}-${suffix}`;
          suffix += 1;
        }
        const collection: Collection = {
          id: uid('collection'),
          profileId: activeProfileId,
          name: name.trim(),
          slug,
          description: description.trim(),
          public: true,
          items: [],
          createdAt: now,
          updatedAt: now,
        };
        set({ data: { ...data, collections: [collection, ...data.collections] } });
        queueWrite(`collection:${collection.id}`, () => syncCollection(collection));
        return collection;
      },
      addToCollection: (collectionId, entityId, entityKind, note) => {
        const data = get().data;
        const collection = data.collections.find((item) => item.id === collectionId);
        if (!collection || collection.items.some((item) => item.entityId === entityId)) return;
        const updated: Collection = {
          ...collection,
          items: [
            ...collection.items,
            { id: uid('collection-item'), entityId, entityKind, note, position: collection.items.length },
          ],
          updatedAt: new Date().toISOString(),
        };
        set({
          data: {
            ...data,
            collections: data.collections.map((item) => item.id === collectionId ? updated : item),
          },
        });
        queueWrite(`collection:${updated.id}`, () => syncCollection(updated));
      },
      removeFromCollection: (collectionId, itemId) => {
        const data = get().data;
        const collection = data.collections.find((item) => item.id === collectionId);
        if (!collection) return;
        const updated: Collection = {
          ...collection,
          items: collection.items
            .filter((item) => item.id !== itemId)
            .map((item, position) => ({ ...item, position })),
          updatedAt: new Date().toISOString(),
        };
        set({
          data: {
            ...data,
            collections: data.collections.map((item) => item.id === collectionId ? updated : item),
          },
        });
        queueWrite(`collection:${updated.id}`, () => syncCollection(updated));
      },
      togglePin: (targetType, targetId) => {
        const { activeProfileId, data } = get();
        if (!activeProfileId) return;
        const existing = data.pins.find((pin) =>
          pin.profileId === activeProfileId && pin.targetType === targetType && pin.targetId === targetId
        );
        const pin = existing ? null : {
          id: uid('pin'),
          profileId: activeProfileId,
          targetType,
          targetId,
          position: data.pins.filter((item) => item.profileId === activeProfileId).length,
        };
        set({
          data: {
            ...data,
            pins: existing
              ? data.pins.filter((item) => item.id !== existing.id)
              : [...data.pins, pin!],
          },
        });
        queueWrite(`pin:${activeProfileId}:${targetType}:${targetId}`, () =>
          syncPin(pin, targetType, targetId)
        );
      },
      setGenrePreferences: (genreIds) => {
        const { activeProfileId, data } = get();
        if (!activeProfileId) return;
        const result = updatedProfile(data, activeProfileId, (profile) => ({ ...profile, genreIds }));
        set({ data: result.data });
        if (result.profile) queueWrite(`profile:${activeProfileId}`, () => syncProfile(result.profile!));
      },
      setProfileSong: (songId) => {
        const { activeProfileId, data } = get();
        if (!activeProfileId) return;
        const result = updatedProfile(data, activeProfileId, (profile) => ({ ...profile, profileSongId: songId }));
        set({ data: result.data });
        if (result.profile) queueWrite(`profile:${activeProfileId}`, () => syncProfile(result.profile!));
      },
      playSong: (songId) => {
        const entity = getEntityById(songId);
        if (entity?.kind !== 'song') return;
        const revealNativePlayer = Boolean(entity.spotifyId && !entity.youtubeId);
        set({ player: { songId, playing: true, expanded: revealNativePlayer || get().player.expanded, pendingSeekMs: null } });
      },
      playSongFrom: (songId, fraction) => {
        const entity = getEntityById(songId);
        if (entity?.kind !== 'song') return;
        const clamped = Math.min(Math.max(fraction, 0), 0.98);
        const durationMs = entity.durationMs ?? 210000;
        const revealNativePlayer = Boolean(entity.spotifyId && !entity.youtubeId);
        set({
          player: {
            songId,
            playing: true,
            expanded: revealNativePlayer || get().player.expanded,
            pendingSeekMs: Math.round(durationMs * clamped),
          },
        });
      },
      consumePendingSeek: () => {
        const value = get().player.pendingSeekMs;
        if (value !== null) set({ player: { ...get().player, pendingSeekMs: null } });
        return value;
      },
      togglePlayback: () => set({ player: { ...get().player, playing: !get().player.playing } }),
      setPlaybackState: (playing) => {
        if (get().player.playing === playing) return;
        set({ player: { ...get().player, playing } });
      },
      stopPlayback: () => set({ player: { songId: null, playing: false, expanded: false, pendingSeekMs: null } }),
      setPlayerExpanded: (expanded) => set({ player: { ...get().player, expanded } }),
      resetDemo: () => set({
        data: cloneSeed(),
        activeProfileId: null,
        player: { songId: null, playing: false, expanded: false, pendingSeekMs: null },
      }),
    }),
    {
      name: `resonote-${dataMode}-v1`,
      storage: createJSONStorage(() => localStorage),
      partialize: (state) => ({
        data: state.data,
        activeProfileId: state.activeProfileId,
        player: { ...state.player, playing: false, pendingSeekMs: null },
        importedEntities: state.importedEntities,
      }),
      version: 2,
      merge: (persisted, current) => {
        const saved = persisted as Partial<ResonoteState>;
        return {
          ...current,
          ...saved,
          data: {
            ...initialData(),
            ...(saved.data ?? {}),
            genreAssertions: saved.data?.genreAssertions ?? [],
          },
          player: { ...current.player, ...(saved.player ?? {}), playing: false, pendingSeekMs: null },
          importedEntities: {
            artists: saved.importedEntities?.artists ?? [],
            albums: saved.importedEntities?.albums ?? [],
            songs: saved.importedEntities?.songs ?? [],
          },
        };
      },
      onRehydrateStorage: () => (state) => {
        registerImportedCatalog(state?.importedEntities);
        state?.setHydrated(true);
      },
    },
  ),
);

export function getActiveProfile(state: Pick<ResonoteState, 'activeProfileId' | 'data'>) {
  return state.data.profiles.find((profile) => profile.id === state.activeProfileId) ?? null;
}

export function getPlayingSong(state: Pick<ResonoteState, 'player'>): Song | null {
  const entity = state.player.songId ? getEntityById(state.player.songId) : null;
  return entity?.kind === 'song' ? entity : null;
}
