'use client';

import { useEffect, useMemo, useState } from 'react';
import { CollectionPage } from '@/components/profile/collection-page';
import { EmptyState } from '@/components/ui/empty-state';
import { useResonoteStore } from '@/lib/data/store';
import { loadProfileBundleByHandle } from '@/lib/data/cloud-sync';
import { registerImportedCatalog } from '@/lib/data/imported-catalog';
import { isCloudMode } from '@/lib/data/config';

export function CollectionRoute({ handle, slug }: { handle: string; slug: string }) {
  const data = useResonoteStore((state) => state.data);
  const mergeProfileBundle = useResonoteStore((state) => state.mergeProfileBundle);
  const isProfileHandle = handle.startsWith('@');
  const normalizedHandle = handle.replace(/^@/, '').toLowerCase();
  const profile = useMemo(
    () => data.profiles.find((candidate) => candidate.handle.toLowerCase() === normalizedHandle),
    [data.profiles, normalizedHandle],
  );
  const collection = profile
    ? data.collections.find((candidate) => candidate.profileId === profile.id && candidate.slug === slug)
    : undefined;
  const [status, setStatus] = useState<'idle' | 'loading' | 'missing'>('idle');

  useEffect(() => {
    if (!isProfileHandle || collection || !isCloudMode || status !== 'idle') return;
    let cancelled = false;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- move into loading before the async fetch
    setStatus('loading');
    void loadProfileBundleByHandle(normalizedHandle)
      .then((bundle) => {
        if (cancelled) return;
        const catalog = bundle.catalog;
        if (catalog && (catalog.artists.length || catalog.albums.length || catalog.songs.length)) {
          // Shared-catalog entities referenced by this person's writing must exist
          // before their page renders, including for signed-out visitors.
          registerImportedCatalog(catalog);
        }
        mergeProfileBundle(bundle);
        const found = bundle.collections.some((candidate) => candidate.slug === slug);
        setStatus(found ? 'idle' : 'missing');
      })
      .catch(() => {
        if (!cancelled) setStatus('missing');
      });
    return () => { cancelled = true; };
  }, [collection, isProfileHandle, mergeProfileBundle, normalizedHandle, slug, status]);

  if (isProfileHandle && !collection && status === 'loading') {
    return (
      <div className="page-shell collection-page" aria-busy="true">
        <div className="route-loading-frame">
          <span className="eyebrow">Loading collection</span>
          <h1>Keeping the shelf ready...</h1>
        </div>
      </div>
    );
  }

  if (!isProfileHandle || !collection) {
    return (
      <div className="page-shell">
        <EmptyState title="Collection not found">It may have been removed or made private.</EmptyState>
      </div>
    );
  }

  return <CollectionPage collectionId={collection.id} />;
}
