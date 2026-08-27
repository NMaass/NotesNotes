'use client';
import { forwardRef, useCallback, useEffect, useImperativeHandle, useState } from 'react';
import { Artwork } from '@/components/ui/artwork';
import type { SearchResult } from '@/lib/data/types';
import { kindLabel } from '@/lib/utils';

export interface MusicReferenceMenuHandle { onKeyDown: (event: KeyboardEvent) => boolean }
interface Props { items: SearchResult[]; command: (item: SearchResult) => void }

export const MusicReferenceMenu = forwardRef<MusicReferenceMenuHandle, Props>(function MusicReferenceMenu({ items, command }, ref) {
  const [selected, setSelected] = useState(0);
  useEffect(() => setSelected(0), [items]);
  const choose = useCallback((index: number) => { const item = items[index]; if (item) command(item); }, [items, command]);
  useImperativeHandle(ref, () => ({
    onKeyDown: (event) => {
      if (event.key === 'ArrowUp') { setSelected((current) => (current + Math.max(items.length, 1) - 1) % Math.max(items.length, 1)); return true; }
      if (event.key === 'ArrowDown') { setSelected((current) => (current + 1) % Math.max(items.length, 1)); return true; }
      if (event.key === 'Enter') { choose(selected); return true; }
      return false;
    }
  }), [choose, items, selected]);
  return (
    <div className="reference-menu" role="listbox" aria-label="Music references">
      {items.length ? items.map((result, index) => (
        <button key={result.entity.id} type="button" role="option" aria-selected={index === selected} className={index === selected ? 'reference-option reference-option--active' : 'reference-option'} onMouseDown={(event) => { event.preventDefault(); choose(index); }}>
          <Artwork entity={result.entity} size="sm" />
          <span><strong>{result.entity.name}</strong><small>{result.subtitle}</small></span>
          <em>{kindLabel(result.entity.kind)}</em>
        </button>
      )) : <div className="reference-empty">Keep typing to find music.</div>}
    </div>
  );
});
