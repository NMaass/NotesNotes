'use client';
import { PenLine, Play } from 'lucide-react';
import Link from 'next/link';
import { EntityHero } from '@/components/entity/entity-hero';
import { JournalEntryCard } from '@/components/journal/journal-entry-card';
import { Button } from '@/components/ui/button';
import { EmptyState } from '@/components/ui/empty-state';
import { getProfileEntityByPath } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';

export function ProfileEntryPage({ profileId, segments }: { profileId: string; segments: string[] }) {
  const data = useResonoteStore((state) => state.data);
  const playSong = useResonoteStore((state) => state.playSong);
  const profile = data.profiles.find((candidate) => candidate.id === profileId);
  const entity = getProfileEntityByPath(segments);
  if (!profile || !entity) return <div className="page-shell"><EmptyState title="Journal page not found">The music or profile could not be resolved.</EmptyState></div>;
  const entry = data.entries.find((candidate) => candidate.profileId === profile.id && candidate.entityId === entity.id && candidate.public);
  return <div className="page-shell profile-entry-page"><div className="profile-context-bar"><Link href={`/@${profile.handle}`}>← @{profile.handle}</Link><span>their journal about {entity.kind}</span>{entity.kind === 'song' ? <Button variant="ghost" onClick={() => playSong(entity.id)}><Play size={17} />Play while reading</Button> : null}</div><EntityHero entity={entity} /><section className="single-entry">{entry ? <JournalEntryCard entry={entry} profile={profile} /> : <EmptyState title={`${profile.displayName} has not published here`}><Link href={`/write/${entity.kind}/${entity.id}`}><PenLine size={17} />Write your own thought</Link></EmptyState>}</section></div>;
}
