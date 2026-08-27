'use client';
import { useEffect } from 'react';
import Link from 'next/link';
import { ConnectionsPanel } from '@/components/entity/connections-panel';
import { EntityCard } from '@/components/entity/entity-card';
import { EntityHero } from '@/components/entity/entity-hero';
import { EntityJournalFeed } from '@/components/entity/entity-journal-feed';
import { TrackList } from '@/components/entity/track-list';
import { catalogLists, getGenreTagCount } from '@/lib/data/selectors';
import { entityGenres } from '@/lib/data/catalog';
import type { CatalogEntity } from '@/lib/data/types';
import { useResonoteStore } from '@/lib/data/store';

export function EntityPage({ entity }: { entity: CatalogEntity }) {
  const data = useResonoteStore((state) => state.data);
  const albums = entity.kind === 'artist' ? catalogLists.albums.filter((album) => album.artistId === entity.id) : [];
  const relatedArtistIds = entity.kind === 'genre'
    ? new Set([...entityGenres, ...(data.genreAssertions ?? [])].filter((link) => link.genreId === entity.id).map((link) => {
        const linked = catalogLists.artists.find((artist) => artist.id === link.entityId);
        if (linked) return linked.id;
        const album = catalogLists.albums.find((candidate) => candidate.id === link.entityId);
        if (album) return album.artistId;
        const song = catalogLists.songs.find((candidate) => candidate.id === link.entityId);
        return song?.artistId;
      }).filter((id): id is string => Boolean(id)))
    : new Set<string>();
  // Landing on a song's page starts the song. If it is already the loaded
  // track, do not restart it.
  useEffect(() => {
    if (entity.kind !== 'song' || (!entity.youtubeId && !entity.spotifyId)) return;
    const state = useResonoteStore.getState();
    if (state.player.songId === entity.id) return;
    state.playSong(entity.id);
  }, [entity.id]);

  const related = entity.kind === 'genre'
    ? catalogLists.artists.filter((artist) => relatedArtistIds.has(artist.id))
    : [];
  return (
    <div className="page-shell">
      <EntityHero entity={entity} />
      {entity.kind === 'album' ? <section className="content-section"><div className="section-heading"><div><span className="eyebrow">Tracklist</span><h2>Listen one track at a time</h2></div></div><TrackList albumId={entity.id} /></section> : null}
      {entity.kind === 'artist' && albums.length ? <section className="content-section"><div className="section-heading"><div><span className="eyebrow">Release groups</span><h2>Albums</h2></div></div><div className="entity-grid">{albums.map((album) => <EntityCard key={album.id} entity={album} />)}</div></section> : null}
      {entity.kind === 'genre' ? <section className="genre-intro"><p>{entity.description}</p><div className="genre-community-note"><strong>{getGenreTagCount(entity.id, data)} tags so far — what genre do you think this is?</strong><span>Open any artist, album, or song below and press Tag genre to add yours. Catalog and community tags keep their sources; the count is people, not songs.</span></div>{related.length ? <div className="entity-grid">{related.map((item) => <EntityCard key={item.id} entity={item} />)}</div> : null}</section> : null}
      <ConnectionsPanel entityId={entity.id} />
      <section className="content-section"><div className="section-heading"><div><span className="eyebrow">Public journal</span><h2>What people noticed</h2></div><Link href={`/write/${entity.kind}/${entity.id}`}>Write yours</Link></div><EntityJournalFeed entityId={entity.id} /></section>
    </div>
  );
}
