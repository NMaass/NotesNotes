'use client';
import * as Accordion from '@radix-ui/react-accordion';
import { ChevronDown, Heart } from 'lucide-react';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { Artwork } from '@/components/ui/artwork';
import { getProfileLibrary, hrefForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';
import type { Profile } from '@/lib/data/types';

export function ProfileLibrary({ profile }: { profile: Profile }) {
  const data = useResonoteStore((state) => state.data);
  const groups = getProfileLibrary(profile, data);
  const storageKey = `resonote-library-open-${profile.id}`;
  const [openArtists, setOpenArtists] = useState<string[]>([]);

  useEffect(() => {
    try {
      const stored = JSON.parse(sessionStorage.getItem(storageKey) ?? '[]') as unknown;
      if (Array.isArray(stored)) {
        // eslint-disable-next-line react-hooks/set-state-in-effect -- restore persisted accordion state from sessionStorage
        setOpenArtists(stored.filter((value): value is string => typeof value === 'string'));
      }
    } catch {
      sessionStorage.removeItem(storageKey);
    }
  }, [storageKey]);

  const changeOpenArtists = (value: string[]) => {
    setOpenArtists(value);
    sessionStorage.setItem(storageKey, JSON.stringify(value));
  };
  return (
    <Accordion.Root type="multiple" value={openArtists} onValueChange={changeOpenArtists} className="library-accordion">{groups.map((group) => (
      <Accordion.Item key={group.artist.id} value={group.artist.id}>
        <Accordion.Header><Accordion.Trigger><Artwork entity={group.artist} size="sm" /><span><strong>{group.artist.name}</strong><small>{group.albums.reduce((sum, album) => sum + album.songs.length, 0)} liked song{group.albums.reduce((sum, album) => sum + album.songs.length, 0) === 1 ? '' : 's'}</small></span>{group.artistLiked ? <Heart size={16} fill="currentColor" /> : null}<ChevronDown className="accordion-chevron" /></Accordion.Trigger></Accordion.Header>
        <Accordion.Content><div className="library-artist-body">
          {group.albums.map((albumGroup) => <div className="library-album" key={albumGroup.album.id}><div className="library-album-heading"><Link href={hrefForEntity(albumGroup.album)}><Artwork entity={albumGroup.album} size="sm" /><span><strong>{albumGroup.album.name}</strong><small>{albumGroup.album.year}</small></span></Link>{albumGroup.albumLiked ? <span className="liked-label"><Heart size={14} fill="currentColor" />liked album</span> : null}</div>{albumGroup.songs.length ? <ul>{albumGroup.songs.map((song) => <li key={song.id}><Link href={hrefForEntity(song)}>{song.name}</Link><Heart size={14} fill="currentColor" /></li>)}</ul> : null}</div>)}
        </div></Accordion.Content>
      </Accordion.Item>
    ))}</Accordion.Root>
  );
}
