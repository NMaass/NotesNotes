'use client';
import * as Accordion from '@radix-ui/react-accordion';
import { ChevronDown, MessageSquareText } from 'lucide-react';
import Link from 'next/link';
import { PinButton } from '@/components/music/pin-button';
import { RichDocumentView } from '@/components/journal/rich-document';
import { getEntityById, hrefForEntity } from '@/lib/data/selectors';
import type { JournalEntry, Profile } from '@/lib/data/types';
import { formatDate } from '@/lib/utils';

export function JournalEntryCard({ entry, profile, showEntity = false }: { entry: JournalEntry; profile: Profile; showEntity?: boolean }) {
  const entity = getEntityById(entry.entityId);
  if (!entity) return null;
  return (
    <article className="journal-card">
      <header className="journal-card-header">
        <div>
          {showEntity ? <Link href={hrefForEntity(entity)} className="journal-entity">{entity.name}</Link> : null}
          <Link href={`/@${profile.handle}`} className="journal-author">@{profile.handle}</Link>
          <time dateTime={entry.updatedAt}>{formatDate(entry.updatedAt)}</time>
        </div>
        <PinButton targetType="entry" targetId={entry.id} />
      </header>
      {entry.title ? <h3>{entry.title}</h3> : null}
      <RichDocumentView document={entry.document} />
      {entry.lenses.length ? <div className="static-chip-row">{entry.lenses.map((lens) => <span key={lens}>{lens}</span>)}</div> : null}
      {entry.worked || entry.didntWork ? (
        <Accordion.Root type="multiple" className="reflection-accordion">
          {entry.worked ? <Accordion.Item value="worked"><Accordion.Header><Accordion.Trigger><span>What worked for me</span><ChevronDown /></Accordion.Trigger></Accordion.Header><Accordion.Content><p>{entry.worked}</p></Accordion.Content></Accordion.Item> : null}
          {entry.didntWork ? <Accordion.Item value="didnt"><Accordion.Header><Accordion.Trigger><span>What didn’t work for me</span><ChevronDown /></Accordion.Trigger></Accordion.Header><Accordion.Content><p>{entry.didntWork}</p></Accordion.Content></Accordion.Item> : null}
        </Accordion.Root>
      ) : null}
      {entry.references.length ? <footer className="entry-reference-summary"><MessageSquareText size={16} /><span>{entry.references.length} linked music reference{entry.references.length === 1 ? '' : 's'}</span></footer> : null}
    </article>
  );
}
