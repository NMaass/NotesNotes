'use client';
import { ArrowRight } from 'lucide-react';
import Link from 'next/link';
import { Artwork } from '@/components/ui/artwork';
import { getEntityById } from '@/lib/data/selectors';
import type { Collection, Profile } from '@/lib/data/types';

export function CollectionCard({ collection, profile }: { collection: Collection; profile: Profile }) {
  const preview = collection.items.slice(0, 4).map((item) => getEntityById(item.entityId)).filter(Boolean);
  return <Link href={`/@${profile.handle}/collections/${collection.slug}`} className="collection-card"><div className="collection-art-stack">{preview.map((entity, index) => entity ? <div key={entity.id} style={{ '--stack-index': index } as React.CSSProperties}><Artwork entity={entity} size="md" /></div> : null)}</div><div className="collection-card-copy"><span className="eyebrow">Collection</span><h3>{collection.name}</h3><p>{collection.description}</p><small>{collection.items.length} item{collection.items.length === 1 ? '' : 's'}</small></div><ArrowRight /></Link>;
}
