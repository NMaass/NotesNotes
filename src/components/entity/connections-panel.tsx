'use client';
import { Link2 } from 'lucide-react';
import Link from 'next/link';
import { Artwork } from '@/components/ui/artwork';
import { getReferencedConnections, hrefForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';
import type { RelationKind } from '@/lib/data/types';

const relationLabels: Record<RelationKind, string> = {
  'reminds-me-of': 'reminds listeners of',
  'influenced-by': 'heard as an influence',
  'pairs-with': 'pairs with',
  'contrasts-with': 'contrasts with',
  mentions: 'mentioned alongside',
};

export function ConnectionsPanel({ entityId }: { entityId: string }) {
  const data = useResonoteStore((state) => state.data);
  const connections = getReferencedConnections(entityId, data);
  if (!connections.length) return null;
  return (
    <section className="connections-panel"><div className="section-heading"><div><span className="eyebrow">Human-made links</span><h2>Connections people heard</h2></div><Link2 /></div>
      <div className="connection-list">{connections.map((connection) => <Link key={connection.entity.id} href={hrefForEntity(connection.entity)} className="connection-row"><Artwork entity={connection.entity} size="sm" /><div><strong>{connection.entity.name}</strong><span>{connection.relations.map((relation) => relationLabels[relation as RelationKind]).join(' · ')}</span><small>{connection.lenses.join(' · ') || 'uncategorized connection'}</small></div><em>{connection.count} mention{connection.count === 1 ? '' : 's'}</em></Link>)}</div>
    </section>
  );
}
