'use client';
import { Radio } from 'lucide-react';
import { toast } from 'sonner';
import { useAuth } from '@/components/auth/auth-provider';
import { Button } from '@/components/ui/button';
import { StableText } from '@/components/ui/stable-swap';
import type { Song } from '@/lib/data/types';
import { useResonoteStore } from '@/lib/data/store';

export function ProfileTrackButton({ song }: { song: Song }) {
  const { profile, requireAuth } = useAuth();
  const setProfileSong = useResonoteStore((state) => state.setProfileSong);
  const active = profile?.profileSongId === song.id;
  const act = () => { setProfileSong(song.id); toast.success('Profile track updated'); };
  return <Button variant="ghost" className="stable-action" aria-pressed={active} onClick={() => { if (requireAuth(act)) act(); }}><Radio size={17} /><StableText value={active ? 'Profile track' : 'Set profile track'} candidates={['Set profile track', 'Profile track']} /></Button>;
}
