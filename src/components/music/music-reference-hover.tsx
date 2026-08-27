'use client';
import * as HoverCard from '@radix-ui/react-hover-card';
import Link from 'next/link';
import { Play } from 'lucide-react';
import { Artwork } from '@/components/ui/artwork';
import { Button } from '@/components/ui/button';
import { getArtistForEntity, getEntityById, hrefForEntity, subtitleForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';

export function MusicReferenceLink({ entityId, label }: { entityId: string; label: string }) {
  const entity = getEntityById(entityId);
  const playSong = useResonoteStore((state) => state.playSong);
  if (!entity) return <span>{label}</span>;
  const artist = getArtistForEntity(entity);
  return (
    <HoverCard.Root openDelay={260} closeDelay={120}>
      <HoverCard.Trigger asChild><Link href={hrefForEntity(entity)} className="music-reference-link">{label}</Link></HoverCard.Trigger>
      <HoverCard.Portal>
        <HoverCard.Content className="music-hover-card" sideOffset={8} collisionPadding={12}>
          <Artwork entity={entity} size="md" record={entity.kind === 'album' || entity.kind === 'song'} />
          <div className="music-hover-copy"><span className="eyebrow">{entity.kind}</span><strong>{entity.name}</strong><small>{subtitleForEntity(entity)}</small>{entity.summary ? <p>{entity.summary}</p> : null}</div>
          {entity.kind === 'song' ? <Button size="sm" onClick={(event) => { event.preventDefault(); playSong(entity.id); }}><Play size={16} />Play</Button> : artist ? <span className="hover-artist">{artist.name}</span> : null}
          <HoverCard.Arrow className="hover-arrow" />
        </HoverCard.Content>
      </HoverCard.Portal>
    </HoverCard.Root>
  );
}
