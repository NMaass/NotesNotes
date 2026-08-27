'use client';
import { AudioLines } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogTrigger } from '@/components/ui/dialog';
import { getFactsForSong } from '@/lib/data/selectors';
import type { Song } from '@/lib/data/types';

export function FactsDialog({ song }: { song: Song }) {
  const facts = getFactsForSong(song.id);
  return (
    <Dialog><DialogTrigger asChild><Button variant="ghost"><AudioLines size={18} />Structure</Button></DialogTrigger>
      <DialogContent title={`Inside “${song.name}”`} description="Catalog facts, estimates, and community annotations are labeled separately rather than presented as equally certain.">
        <div className="fact-grid">{facts.length ? facts.map((fact) => <div key={fact.id} className="fact-card"><span>{fact.label}</span><strong>{fact.value}</strong><small>{fact.confidence} · {fact.sourceLabel}</small></div>) : <p>No structural facts have been cached for this recording yet.</p>}</div>
      </DialogContent>
    </Dialog>
  );
}
