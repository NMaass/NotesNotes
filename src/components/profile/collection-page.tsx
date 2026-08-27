'use client';
import { Play, Trash2 } from 'lucide-react';
import Link from 'next/link';
import { PinButton } from '@/components/music/pin-button';
import { Artwork } from '@/components/ui/artwork';
import { Button } from '@/components/ui/button';
import { EmptyState } from '@/components/ui/empty-state';
import { getEntityById, hrefForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';

export function CollectionPage({ collectionId }: { collectionId: string }) {
  const data = useResonoteStore((state) => state.data);
  const activeProfileId = useResonoteStore((state) => state.activeProfileId);
  const remove = useResonoteStore((state) => state.removeFromCollection);
  const play = useResonoteStore((state) => state.playSong);
  const collection = data.collections.find((item) => item.id === collectionId);
  if (!collection) return <div className="page-shell"><EmptyState title="Collection not found">It may have been removed or made private.</EmptyState></div>;
  const profile = data.profiles.find((item) => item.id === collection.profileId);
  if (!profile) return null;
  const own = activeProfileId === profile.id;
  return <div className="page-shell collection-page"><header className="collection-hero"><span className="eyebrow">@{profile.handle}’s collection</span><h1>{collection.name}</h1><p>{collection.description}</p><div className="collection-hero-meta"><span>{collection.items.length} pieces of music</span><PinButton targetType="collection" targetId={collection.id} /></div></header><ol className="collection-items">{collection.items.length ? [...collection.items].sort((a, b) => a.position - b.position).map((item, index) => { const entity = getEntityById(item.entityId); if (!entity) return null; return <li key={item.id}><span className="collection-index stable-number">{String(index + 1).padStart(2, '0')}</span><Artwork entity={entity} size="md" record={entity.kind === 'song' || entity.kind === 'album'} /><div className="collection-item-copy"><span className="eyebrow">{entity.kind}</span><Link href={hrefForEntity(entity)}>{entity.name}</Link>{item.note ? <p>{item.note}</p> : null}</div>{entity.kind === 'song' ? <Button variant="ghost" size="icon" aria-label={`Play ${entity.name}`} onClick={() => play(entity.id)}><Play /></Button> : null}{own ? <Button variant="ghost" size="icon" aria-label={`Remove ${entity.name}`} onClick={() => remove(collection.id, item.id)}><Trash2 /></Button> : null}</li>; }) : <EmptyState title="This collection is empty">Add music from any artist, album, song, or genre page.</EmptyState>}</ol></div>;
}
