'use client';
import Link from 'next/link';
import { useResonoteStore } from '@/lib/data/store';
export function ProfileEntryLink({ href, songId, children, className }: { href: string; songId?: string; children: React.ReactNode; className?: string }) {
  const playSong = useResonoteStore((state) => state.playSong);
  return <Link href={href} className={className} onClick={() => { if (songId) playSong(songId); }}>{children}</Link>;
}
