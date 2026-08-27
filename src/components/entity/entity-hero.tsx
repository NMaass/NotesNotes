'use client';
import { PenLine } from 'lucide-react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { AddToCollectionDialog } from '@/components/collections/add-to-collection-dialog';
import { useAuth } from '@/components/auth/auth-provider';
import { CreditsDialog } from '@/components/music/credits-dialog';
import { FactsDialog } from '@/components/music/facts-dialog';
import { LikeButton } from '@/components/music/like-button';
import { ListenDialog } from '@/components/music/listen-dialog';
import { PinButton } from '@/components/music/pin-button';
import { PlayButton } from '@/components/music/play-button';
import { ProfileTrackButton } from '@/components/music/profile-track-button';
import { GenreTagDialog } from '@/components/music/genre-tag-dialog';
import { Artwork } from '@/components/ui/artwork';
import { Button } from '@/components/ui/button';
import { getAlbumForSong, getArtistForEntity, getGenresForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';
import type { CatalogEntity } from '@/lib/data/types';
import { formatDuration } from '@/lib/utils';

export function EntityHero({ entity }: { entity: CatalogEntity }) {
  const router = useRouter();
  const { requireAuth } = useAuth();
  const player = useResonoteStore((state) => state.player);
  const data = useResonoteStore((state) => state.data);
  const artist = getArtistForEntity(entity);
  const album = getAlbumForSong(entity);
  const genreLinks = getGenresForEntity(entity.id, data);
  const playing = entity.kind === 'song' && player.songId === entity.id && player.playing;
  const write = () => router.push(`/write/${entity.kind}/${entity.id}`);
  return (
    <header className="entity-hero">
      <div className="entity-hero-art"><Artwork entity={entity} size="hero" record={entity.kind === 'song' || entity.kind === 'album'} playing={playing} /></div>
      <div className="entity-hero-copy">
        <span className="eyebrow">{entity.kind}</span>
        <h1>{entity.name}</h1>
        <div className="entity-byline">
          {artist && artist.id !== entity.id ? <Link href={`/music/${artist.slug}`}>{artist.name}</Link> : null}
          {album ? <><span>·</span><Link href={`/music/${artist?.slug}/${album.slug}`}>{album.name}</Link></> : null}
          {entity.kind === 'album' && entity.year ? <><span>·</span><span>{entity.year}</span></> : null}
          {entity.kind === 'song' && formatDuration(entity.durationMs) ? <><span>·</span><span>{formatDuration(entity.durationMs)}</span></> : null}
        </div>
        {entity.summary ? <p className="entity-summary">{entity.summary}</p> : null}
        {genreLinks.length ? <div className="static-chip-row">{genreLinks.map(({ genre, source, votes }) => <Link key={genre.id} href={`/genre/${genre.slug}`}>{genre.name}{source === 'community' && votes ? <small>{votes}</small> : null}</Link>)}</div> : null}
        <div className="hero-primary-actions">{entity.kind === 'song' ? <PlayButton song={entity} /> : null}<LikeButton entity={entity} /><Button variant="outline" onClick={() => { if (requireAuth(write)) write(); }}><PenLine size={18} />Write</Button></div>
        <div className="hero-secondary-actions"><AddToCollectionDialog entity={entity} />{entity.kind !== 'genre' ? <GenreTagDialog entity={entity} /> : null}<PinButton targetType="entity" targetId={entity.id} />{entity.kind === 'song' ? <><ListenDialog song={entity} /><CreditsDialog song={entity} /><FactsDialog song={entity} /><ProfileTrackButton song={entity} /></> : null}</div>
      </div>
    </header>
  );
}
