'use client';
import { ArrowRight, PenLine } from 'lucide-react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useAuth } from '@/components/auth/auth-provider';
import { Artwork } from '@/components/ui/artwork';
import { Button } from '@/components/ui/button';
import { getEntityCount, hrefForEntity, subtitleForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';
import type { CatalogEntity } from '@/lib/data/types';

export function EntityCard({ entity, showWrite = true }: { entity: CatalogEntity; showWrite?: boolean }) {
  const router = useRouter();
  const { requireAuth } = useAuth();
  const data = useResonoteStore((state) => state.data);
  const count = getEntityCount(entity.id, data);
  const href = hrefForEntity(entity);
  const writeHref = `/write/${entity.kind}/${entity.id}`;
  const write = () => router.push(writeHref);
  return (
    <article className="entity-card">
      <Link href={href} className="entity-card-main">
        <Artwork entity={entity} size="lg" record={entity.kind === 'song' || entity.kind === 'album'} />
        <div className="entity-card-copy"><span className="eyebrow">{entity.kind}</span><h3>{entity.name}</h3><p>{subtitleForEntity(entity)}</p><small>{count ? `${count} public thought${count === 1 ? '' : 's'}` : 'Be the first to write here'}</small></div>
      </Link>
      <div className="entity-card-actions"><Button variant="ghost" onClick={() => router.push(href)}>Open <ArrowRight size={17} /></Button>{showWrite ? <Button variant="outline" onClick={() => { if (requireAuth(write)) write(); }}><PenLine size={17} />Write</Button> : null}</div>
    </article>
  );
}
