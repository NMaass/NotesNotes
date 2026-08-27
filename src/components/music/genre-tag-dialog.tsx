'use client';

import { Tags } from 'lucide-react';
import { useState } from 'react';
import { useAuth } from '@/components/auth/auth-provider';
import { Button } from '@/components/ui/button';
import { Chip } from '@/components/ui/chip';
import { Dialog, DialogContent, DialogTrigger } from '@/components/ui/dialog';
import { catalogLists } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';
import type { CatalogEntity } from '@/lib/data/types';

export function GenreTagDialog({ entity }: { entity: CatalogEntity }) {
  const { profile, requireAuth } = useAuth();
  const assertions = useResonoteStore((state) => state.data.genreAssertions ?? []);
  const toggle = useResonoteStore((state) => state.toggleGenreAssertion);
  const [open, setOpen] = useState(false);
  const mine = new Set(
    profile
      ? assertions
          .filter((row) => row.createdBy === profile.id && row.entityId === entity.id)
          .map((row) => row.genreId)
      : [],
  );
  const launch = () => { if (requireAuth(() => setOpen(true))) setOpen(true); };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" onClick={(event) => { event.preventDefault(); launch(); }}>
          <Tags size={18} />Tag genre
        </Button>
      </DialogTrigger>
      <DialogContent
        title={`How do you hear “${entity.name}”?`}
        description="Choose genre labels that help describe it. Your assertion remains attributed to you instead of becoming an anonymous verdict."
      >
        <div className="genre-assertion-dialog">
          <div className="chip-row" role="group" aria-label={`Your genre tags for ${entity.name}`}>
            {catalogLists.genres.map((genre) => (
              <Chip
                key={genre.id}
                selected={mine.has(genre.id)}
                onClick={() => toggle(entity.id, entity.kind, genre.id)}
              >
                {genre.name}
              </Chip>
            ))}
          </div>
          <p>Catalog tags, community totals, and your own tags stay separate in storage. The page only combines them for a lighter reading surface.</p>
        </div>
      </DialogContent>
    </Dialog>
  );
}
