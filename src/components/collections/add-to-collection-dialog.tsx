'use client';
import { FolderPlus, Plus } from 'lucide-react';
import { useState } from 'react';
import { toast } from 'sonner';
import { useAuth } from '@/components/auth/auth-provider';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogTrigger } from '@/components/ui/dialog';
import type { CatalogEntity } from '@/lib/data/types';
import { useResonoteStore } from '@/lib/data/store';

export function AddToCollectionDialog({ entity }: { entity: CatalogEntity }) {
  const { profile, requireAuth } = useAuth();
  const collections = useResonoteStore((state) => state.data.collections);
  const add = useResonoteStore((state) => state.addToCollection);
  const create = useResonoteStore((state) => state.createCollection);
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const mine = profile ? collections.filter((collection) => collection.profileId === profile.id) : [];
  const launch = () => { if (requireAuth(() => setOpen(true))) setOpen(true); };
  const addExisting = (collectionId: string) => {
    const collection = mine.find((candidate) => candidate.id === collectionId);
    if (!collection || collection.items.some((item) => item.entityId === entity.id)) return;
    add(collectionId, entity.id, entity.kind);
    setOpen(false);
    toast.success('Added to collection');
  };
  const createAndAdd = () => { const collection = create(name, description); if (collection) { add(collection.id, entity.id, entity.kind); setOpen(false); setName(''); setDescription(''); toast.success('Collection created'); } };
  return (
    <Dialog open={open} onOpenChange={setOpen}><DialogTrigger asChild><Button variant="outline" onClick={(event) => { event.preventDefault(); launch(); }}><FolderPlus size={18} />Collect</Button></DialogTrigger>
      <DialogContent title="Add to a collection" description="Collections are personal explanations of spiritual similarity—not algorithmic genres.">
        <div className="collection-picker">
          {mine.map((collection) => {
            const alreadyAdded = collection.items.some((item) => item.entityId === entity.id);
            return (
              <button
                key={collection.id}
                type="button"
                className="collection-picker-item"
                disabled={alreadyAdded}
                onClick={() => addExisting(collection.id)}
              >
                <strong>{collection.name}</strong>
                <span>{alreadyAdded ? 'Already here' : `${collection.items.length} item${collection.items.length === 1 ? '' : 's'}`}</span>
              </button>
            );
          })}
          <div className="divider"><span>or make one</span></div>
          <label className="field"><span>Name</span><input value={name} onChange={(event) => setName(event.target.value)} placeholder="fluorescent parking lots at 2am" /></label>
          <label className="field"><span>What holds it together?</span><textarea rows={2} value={description} onChange={(event) => setDescription(event.target.value)} /></label>
          <Button onClick={createAndAdd} disabled={!name.trim()}><Plus size={18} />Create and add</Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
