'use client';
import * as DialogPrimitive from '@radix-ui/react-dialog';
import { Command } from 'cmdk';
import { Search, X } from 'lucide-react';
import { useRouter } from 'next/navigation';
import { useEffect, useMemo, useState } from 'react';
import { Artwork } from '@/components/ui/artwork';
import { Button } from '@/components/ui/button';
import { hrefForEntity, searchLocalCatalog } from '@/lib/data/selectors';
import type { EntityKind, SearchResult } from '@/lib/data/types';
import { kindLabel } from '@/lib/utils';

const tabs: Array<{ value: 'all' | EntityKind; label: string }> = [
  { value: 'all', label: 'All' }, { value: 'song', label: 'Songs' }, { value: 'album', label: 'Albums' },
  { value: 'artist', label: 'Artists' }, { value: 'genre', label: 'Genres' }
];

export function GlobalSearch({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const router = useRouter();
  const [query, setQuery] = useState('');
  const [tab, setTab] = useState<'all' | EntityKind>('all');
  const [remote, setRemote] = useState<SearchResult[]>([]);
  const [remoteState, setRemoteState] = useState<'idle' | 'loading' | 'done' | 'error'>('idle');
  const local = useMemo(() => searchLocalCatalog(query, 14).filter((result) => tab === 'all' || result.entity.kind === tab), [query, tab]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- clear stale remote results when the query/tab changes
    setRemote([]);
    if (query.trim().length < 3 || tab === 'genre' || local.length >= 5 || process.env.NEXT_PUBLIC_ENABLE_REMOTE_SEARCH === 'false') {
      setRemoteState('idle');
      return;
    }
    const controller = new AbortController();
    const timer = window.setTimeout(async () => {
      setRemoteState('loading');
      const kind = tab === 'artist' || tab === 'album' || tab === 'song' ? tab : 'song';
      try {
        const response = await fetch(`/api/music/search?q=${encodeURIComponent(query)}&kind=${kind}`, { signal: controller.signal });
        const body = await response.json() as { results?: SearchResult[] };
        setRemote(body.results ?? []);
        setRemoteState(response.ok ? 'done' : 'error');
      } catch (error) {
        if ((error as Error).name !== 'AbortError') setRemoteState('error');
      }
    }, 420);
    return () => { window.clearTimeout(timer); controller.abort(); };
  }, [query, tab, local.length]);

  const go = (result: SearchResult) => {
    const href = result.source === 'local'
      ? hrefForEntity(result.entity)
      : `/discover/${result.entity.kind}/${result.entity.musicbrainzId}?name=${encodeURIComponent(result.entity.name)}&subtitle=${encodeURIComponent(result.subtitle)}`;
    onOpenChange(false);
    setQuery('');
    router.push(href);
  };

  const allResults = [...local, ...remote.filter((candidate) => !local.some((result) => result.entity.name === candidate.entity.name && result.entity.kind === candidate.entity.kind))];

  return (
    <DialogPrimitive.Root open={open} onOpenChange={onOpenChange}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="dialog-overlay" />
        <DialogPrimitive.Content className="search-dialog" aria-describedby={undefined}>
          <DialogPrimitive.Title className="sr-only">Search music</DialogPrimitive.Title>
          <Command shouldFilter={false} className="command-shell">
            <div className="search-input-row"><Search size={22} /><Command.Input autoFocus value={query} onValueChange={setQuery} placeholder="Search artists, albums, songs, or genres…" /><DialogPrimitive.Close asChild><Button variant="ghost" size="icon" aria-label="Close search"><X size={20} /></Button></DialogPrimitive.Close></div>
            <div className="search-tabs" role="group" aria-label="Filter search results">{tabs.map((item) => <button type="button" key={item.value} className={tab === item.value ? 'search-tab search-tab--active' : 'search-tab'} aria-pressed={tab === item.value} onClick={() => setTab(item.value)}>{item.label}</button>)}</div>
            <Command.List className="search-results">
              {!query ? <div className="search-guidance"><strong>Find something you have thoughts about.</strong><span>Try “Lithium,” “Nevermind,” “Nirvana,” or “shoegaze.”</span></div> : null}
              {query && allResults.length === 0 && remoteState !== 'loading' ? <Command.Empty>No matching music yet.</Command.Empty> : null}
              {allResults.map((result) => (
                <Command.Item key={`${result.source}-${result.entity.id}`} value={`${result.entity.kind}-${result.entity.id}`} onSelect={() => go(result)} onMouseEnter={() => { if (result.source === 'local') router.prefetch(hrefForEntity(result.entity)); }} className="search-result">
                  <Artwork entity={result.entity} size="sm" />
                  <span className="search-result-copy"><strong>{result.entity.name}</strong><small>{result.subtitle}</small></span>
                  <span className="search-result-kind">{kindLabel(result.entity.kind)}</span>
                </Command.Item>
              ))}
              {remoteState === 'loading' ? <div className="search-loading" aria-live="polite">Looking beyond your local catalog…</div> : null}
              {remoteState === 'error' ? <div className="search-loading">MusicBrainz is unavailable. Local search still works.</div> : null}
            </Command.List>
          </Command>
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}
