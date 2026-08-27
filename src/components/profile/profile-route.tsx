'use client';

import { useEffect, useMemo, useState } from 'react';
import { EmptyState } from '@/components/ui/empty-state';
import { ProfileEntryPage } from '@/components/profile/profile-entry-page';
import { ProfilePage } from '@/components/profile/profile-page';
import { useResonoteStore } from '@/lib/data/store';
import { loadProfileBundleByHandle } from '@/lib/data/cloud-sync';
import { registerImportedCatalog } from '@/lib/data/imported-catalog';
import { isCloudMode } from '@/lib/data/config';

export function ProfileRoute({ handle, segments }: { handle: string; segments?: string[] }) {
  const data = useResonoteStore((state) => state.data);
  const mergeProfileBundle = useResonoteStore((state) => state.mergeProfileBundle);
  const isProfileHandle = handle.startsWith('@');
  const normalizedHandle = handle.replace(/^@/, '').toLowerCase();
  const profile = useMemo(
    () => data.profiles.find((candidate) => candidate.handle.toLowerCase() === normalizedHandle),
    [data.profiles, normalizedHandle],
  );
  const [status, setStatus] = useState<'idle' | 'loading' | 'missing'>('idle');

  useEffect(() => {
    if (!isProfileHandle || profile || !isCloudMode || status !== 'idle') return;
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
        setStatus('idle');
      })
      .catch(() => {
        if (!cancelled) setStatus('missing');
      });
    return () => { cancelled = true; };
  }, [isProfileHandle, mergeProfileBundle, normalizedHandle, profile, status]);

  if (isProfileHandle && !profile && status === 'loading') {
    return (
      <div className="page-shell profile-page" aria-busy="true">
        <div className="route-loading-frame">
          <span className="eyebrow">Loading profile</span>
          <h1>Keeping the page in place...</h1>
        </div>
      </div>
    );
  }

  if (!isProfileHandle || !profile) {
    return (
      <div className="page-shell">
        <EmptyState title="Profile not found">This profile may not exist or may not be available.</EmptyState>
      </div>
    );
  }

  return segments?.length
    ? <ProfileEntryPage profileId={profile.id} segments={segments} />
    : <ProfilePage profileId={profile.id} />;
}
