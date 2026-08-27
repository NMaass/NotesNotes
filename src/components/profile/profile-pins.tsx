'use client';
import { Pin } from 'lucide-react';
import Link from 'next/link';
import { JournalEntryCard } from '@/components/journal/journal-entry-card';
import { Artwork } from '@/components/ui/artwork';
import { getEntityById, hrefForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';
import type { Profile } from '@/lib/data/types';

export function ProfilePins({ profile }: { profile: Profile }) {
  const data = useResonoteStore((state) => state.data);
  const pins = data.pins.filter((pin) => pin.profileId === profile.id).sort((a, b) => a.position - b.position);
  if (!pins.length) return null;
  return <section className="profile-pins"><div className="section-heading"><div><span className="eyebrow">Pinned</span><h2>Start here</h2></div><Pin /></div><div className="pin-grid">{pins.map((pin) => {
    if (pin.targetType === 'entry') { const entry = data.entries.find((item) => item.id === pin.targetId); return entry ? <JournalEntryCard key={pin.id} entry={entry} profile={profile} showEntity /> : null; }
    if (pin.targetType === 'collection') { const collection = data.collections.find((item) => item.id === pin.targetId); return collection ? <Link className="pinned-collection" key={pin.id} href={`/@${profile.handle}/collections/${collection.slug}`}><span className="eyebrow">Collection</span><strong>{collection.name}</strong><p>{collection.description}</p><small>{collection.items.length} pieces of music</small></Link> : null; }
    const entity = getEntityById(pin.targetId); return entity ? <Link className="pinned-entity" key={pin.id} href={hrefForEntity(entity)}><Artwork entity={entity} size="md" /><span><small>{entity.kind}</small><strong>{entity.name}</strong></span></Link> : null;
  })}</div></section>;
}
