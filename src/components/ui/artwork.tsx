import type { CatalogEntity } from '@/lib/data/types';
import { Disc3, Music2 } from 'lucide-react';
import { cn } from '@/lib/utils';

export function Artwork({ entity, size = 'md', playing = false, record = false }: { entity: CatalogEntity; size?: 'sm' | 'md' | 'lg' | 'hero'; playing?: boolean; record?: boolean }) {
  const initials = entity.name.split(/\s+/).slice(0, 2).map((part) => part[0]).join('').toUpperCase();
  return (
    <div className={cn('artwork-wrap', `artwork-wrap--${size}`, record && 'artwork-wrap--record')}>
      {record ? <div className={cn('vinyl', playing && 'vinyl--playing')} aria-hidden="true"><Disc3 /></div> : null}
      <div className="artwork">
        {entity.imageUrl ? <img src={entity.imageUrl} alt={entity.name} loading="lazy" /> : <div className="artwork-fallback" aria-hidden="true"><Music2 size={size === 'hero' ? 42 : 24} /><span>{initials}</span></div>}
      </div>
    </div>
  );
}
