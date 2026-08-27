'use client';
import { Pause, Play } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { StableText } from '@/components/ui/stable-swap';
import type { Song } from '@/lib/data/types';
import { useResonoteStore } from '@/lib/data/store';

export function PlayButton({ song, variant = 'solid' }: { song: Song; variant?: 'solid' | 'outline' | 'ghost' }) {
  const player = useResonoteStore((state) => state.player);
  const playSong = useResonoteStore((state) => state.playSong);
  const toggle = useResonoteStore((state) => state.togglePlayback);
  const active = player.songId === song.id;
  const playing = active && player.playing;
  const action = () => active ? toggle() : playSong(song.id);
  return <Button variant={variant} className="stable-action" onClick={action}>{playing ? <Pause size={18} /> : <Play size={18} />}<StableText value={playing ? 'Pause' : 'Play'} candidates={['Play', 'Pause']} /></Button>;
}
