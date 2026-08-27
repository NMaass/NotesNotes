'use client';
import { Play } from 'lucide-react';
import Link from 'next/link';
import { LikeButton } from '@/components/music/like-button';
import { Button } from '@/components/ui/button';
import { catalogLists, hrefForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';

export function TrackList({ albumId }: { albumId: string }) {
  const playSong = useResonoteStore((state) => state.playSong);
  const tracks = catalogLists.songs.filter((song) => song.albumId === albumId).sort((a, b) => (a.trackNumber ?? 99) - (b.trackNumber ?? 99));
  return <ol className="track-list">{tracks.map((song) => <li key={song.id}><span className="track-number stable-number">{song.trackNumber ?? '–'}</span><Button variant="ghost" size="icon" aria-label={`Play ${song.name}`} onClick={() => playSong(song.id)}><Play size={17} /></Button><Link href={hrefForEntity(song)}><strong>{song.name}</strong>{song.isBonusTrack ? <small>bonus track</small> : null}</Link><LikeButton entity={song} compact /></li>)}</ol>;
}
