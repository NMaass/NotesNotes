'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { EntityPage } from '@/components/entity/entity-page';
import { EmptyState } from '@/components/ui/empty-state';
import { catalogLists, getAlbumForSong, getEntityByPath } from '@/lib/data/selectors';
import { registerImportedCatalog } from '@/lib/data/imported-catalog';
import { useResonoteStore } from '@/lib/data/store';
import type { CatalogEntity } from '@/lib/data/types';

/**
 * A locally-known entity can still be incomplete: a cached album may predate its
 * tracklist arriving, or a song may reference an album the device never saw.
 */
function locallyComplete(entity: CatalogEntity | undefined): boolean {
  if (!entity) return false;
  if (entity.kind === 'album') return catalogLists.songs.some((song) => song.albumId === entity.id);
  if (entity.kind === 'song' && entity.albumId) return Boolean(getAlbumForSong(entity));
  return true;
}

export function ImportedEntityGate({ segments }: { segments: string[] }) {
  const [entity, setEntity] = useState<CatalogEntity | null | undefined>(undefined);

  useEffect(() => {
    let cancelled = false;
    const store = useResonoteStore.getState();
    registerImportedCatalog(store.importedEntities);
    const local = getEntityByPath(segments);
    if (locallyComplete(local)) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- seed catalog resolves synchronously on mount
      setEntity(local ?? null);
      return;
    }
    // Missing or half-known here — the shared catalog may have the rest.
    void (async () => {
      try {
        const { loadCatalogByPath } = await import('@/lib/data/cloud-sync');
        const slice = await loadCatalogByPath(segments.join('/'));
        if (cancelled) return;
        if (slice.artists.length || slice.albums.length || slice.songs.length) {
          // Merge heals partial caches: existing entries stay, gaps fill in.
          store.importCatalogBundle(slice);
          setEntity(getEntityByPath(segments) ?? null);
        } else if (local) {
          setEntity(local);
        } else {
          setEntity(null);
        }
      } catch {
        if (!cancelled) setEntity(local ?? null);
      }
    })();
    return () => { cancelled = true; };
  }, [segments]);

  if (entity === undefined) {
    return (
      <div className="page-shell page-loading">
        <div className="route-loading-frame">
          <span className="eyebrow">Resonote</span>
          <h1>Checking the shelf…</h1>
        </div>
      </div>
    );
  }

  if (!entity) {
    return (
      <div className="page-shell">
        <EmptyState title="This one hasn't been brought in yet">
          Resonote&apos;s crate grows when listeners import records from MusicBrainz.
          Nobody has claimed this release yet — its liner notes are still unwritten.
          <br /><br />
          <span style={{ display: 'inline-flex', gap: '10px' }}>
            <Link className="button button--outline" href="/">Back to the shelf</Link>
            <Link className="button button--ghost" href="/discover">Read the journals</Link>
          </span>
        </EmptyState>
      </div>
    );
  }

  return <EntityPage entity={entity} />;
}
