'use client';
import { Database, Download, LoaderCircle, Search } from 'lucide-react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { hrefForEntity, getEntityById } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';
import type { ImportedCatalogBundle } from '@/lib/data/imported-catalog';

export function DiscoveredPage({ kind, id, name, subtitle }: { kind: string; id: string; name: string; subtitle: string }) {
  const router = useRouter();
  const importCatalogBundle = useResonoteStore((state) => state.importCatalogBundle);
  const [status, setStatus] = useState<'idle' | 'importing' | 'error'>('idle');

  const runImport = async () => {
    setStatus('importing');
    try {
      const response = await fetch('/api/music/import', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ kind, mbid: id }),
      });
      const body = await response.json() as { ok?: boolean; error?: string; warning?: string; bundle?: ImportedCatalogBundle & { focusKind: string; focusId: string } };
      if (!response.ok || !body.ok || !body.bundle) throw new Error(body.error ?? 'Import failed.');
      importCatalogBundle(body.bundle);
      if (body.warning) toast.warning(body.warning);
      else toast.success(`${name} is now part of your catalog.`);
      const focus = getEntityById(body.bundle.focusId);
      router.push(focus ? hrefForEntity(focus) : '/');
    } catch (error) {
      setStatus('error');
      toast.error(error instanceof Error ? error.message : 'Import failed.');
    }
  };

  return <div className="page-shell discovered-page"><div className="discovered-card"><Database /><span className="eyebrow">Found on MusicBrainz · {kind}</span><h1>{name}</h1><p>{subtitle}</p><code>{id}</code><div className="discovered-explanation"><strong>Nobody has brought this one home yet.</strong><p>It exists on MusicBrainz, so you can be the first: importing resolves the artist, the release group, every track, and the cover art together and adds it to Resonote&apos;s shared crate — usually in a few seconds.</p></div><div className="hero-primary-actions"><Button size="lg" onClick={() => void runImport()} disabled={status === 'importing'}>{status === 'importing' ? <LoaderCircle className="spin-slow" size={18} /> : <Download size={18} />}{status === 'importing' ? 'Resolving from MusicBrainz…' : `Import this ${kind}`}</Button><Link href="/" className="button button--outline button--lg"><Search />Search something already cached</Link></div></div></div>;
}
