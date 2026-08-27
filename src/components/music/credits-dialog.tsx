'use client';
import { BadgeInfo, ExternalLink } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogTrigger } from '@/components/ui/dialog';
import { getCreditsForSong } from '@/lib/data/selectors';
import type { Song } from '@/lib/data/types';

export function CreditsDialog({ song }: { song: Song }) {
  const credits = getCreditsForSong(song.id);
  return (
    <Dialog><DialogTrigger asChild><Button variant="ghost"><BadgeInfo size={18} />Credits</Button></DialogTrigger>
      <DialogContent title={`Credits for “${song.name}”`} description="Recording-specific collaborators, kept out of the main reading flow until you ask for them.">
        <div className="credit-list">{credits.length ? credits.map((credit) => <div key={credit.id} className="credit-row"><div><strong>{credit.name}</strong><span>{credit.role}</span></div><small>{credit.sourceLabel}{credit.sourceUrl ? <a href={credit.sourceUrl} target="_blank" rel="noreferrer" aria-label={`Open ${credit.sourceLabel}`}><ExternalLink size={14} /></a> : null}</small></div>) : <p>No structured credits have been cached for this recording yet.</p>}</div>
      </DialogContent>
    </Dialog>
  );
}
