'use client';
import { Headphones, Plus } from 'lucide-react';
import { useState } from 'react';
import { toast } from 'sonner';
import { useAuth } from '@/components/auth/auth-provider';
import { Button } from '@/components/ui/button';
import { Chip } from '@/components/ui/chip';
import { Dialog, DialogContent, DialogTrigger } from '@/components/ui/dialog';
import type { Song } from '@/lib/data/types';
import { useResonoteStore } from '@/lib/data/store';

const moods = ['restless', 'warm', 'euphoric', 'heavy', 'lonely', 'focused', 'nostalgic', 'weightless'];

export function ListenDialog({ song }: { song: Song }) {
  const { requireAuth } = useAuth();
  const logListen = useResonoteStore((state) => state.logListen);
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<string[]>([]);
  const [custom, setCustom] = useState('');
  const [note, setNote] = useState('');
  const save = () => {
    const finalMoods = [...selected, ...(custom.trim() ? [custom.trim()] : [])];
    logListen(song.id, finalMoods, note.trim() || undefined);
    setOpen(false); setSelected([]); setCustom(''); setNote('');
    toast.success('Listen logged');
  };
  const launch = () => { if (requireAuth(() => setOpen(true))) setOpen(true); };
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild><Button variant="outline" onClick={(event) => { event.preventDefault(); launch(); }}><Headphones size={18} />Log listen</Button></DialogTrigger>
      <DialogContent title={`Log “${song.name}”`} description="A listen is an event. It does not have to become a review.">
        <div className="form-stack">
          <fieldset><legend>How did this listen feel?</legend><div className="chip-row">{moods.map((mood) => <Chip key={mood} selected={selected.includes(mood)} onClick={() => setSelected((current) => current.includes(mood) ? current.filter((value) => value !== mood) : [...current, mood])}>{mood}</Chip>)}</div></fieldset>
          <label className="field"><span>Another mood</span><div className="input-with-icon"><Plus size={18} /><input value={custom} onChange={(event) => setCustom(event.target.value)} placeholder="your own word" /></div></label>
          <label className="field"><span>Optional note</span><textarea value={note} onChange={(event) => setNote(event.target.value)} placeholder="Anything specific about this listen?" rows={3} /></label>
          <Button size="lg" onClick={save}>Save listen</Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
