'use client';
import { JournalEntryCard } from '@/components/journal/journal-entry-card';
import { EmptyState } from '@/components/ui/empty-state';
import { getEntriesForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';

export function EntityJournalFeed({ entityId }: { entityId: string }) {
  const data = useResonoteStore((state) => state.data);
  const entries = getEntriesForEntity(entityId, data);
  return <div className="journal-feed">{entries.length ? entries.map((entry) => { const profile = data.profiles.find((candidate) => candidate.id === entry.profileId); return profile ? <JournalEntryCard key={entry.id} entry={entry} profile={profile} /> : null; }) : <EmptyState title="No public thoughts yet">This page is ready for someone to notice something specific.</EmptyState>}</div>;
}
