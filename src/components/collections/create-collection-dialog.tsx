'use client';
import { Plus } from 'lucide-react';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAuth } from '@/components/auth/auth-provider';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogTrigger } from '@/components/ui/dialog';
import { useResonoteStore } from '@/lib/data/store';

export function CreateCollectionDialog() {
  const router = useRouter();
  const { profile, requireAuth } = useAuth();
  const create = useResonoteStore((state) => state.createCollection);
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const launch = () => { if (requireAuth(() => setOpen(true))) setOpen(true); };
  const save = () => { const collection = create(name, description); if (collection && profile) { setOpen(false); router.push(`/@${profile.handle}/collections/${collection.slug}`); } };
  return <Dialog open={open} onOpenChange={setOpen}><DialogTrigger asChild><Button variant="outline" onClick={(event) => { event.preventDefault(); launch(); }}><Plus size={18} />New collection</Button></DialogTrigger><DialogContent title="Make a collection" description="Name a relationship between pieces of music in your own language."><div className="form-stack"><label className="field"><span>Name</span><input autoFocus value={name} onChange={(event) => setName(event.target.value)} placeholder="songs that sound like the room is breathing" /></label><label className="field"><span>What holds it together?</span><textarea rows={4} value={description} onChange={(event) => setDescription(event.target.value)} /></label><Button size="lg" disabled={!name.trim()} onClick={save}>Create collection</Button></div></DialogContent></Dialog>;
}
