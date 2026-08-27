'use client';

import { Headphones, PenLine, Play } from 'lucide-react';
import Link from 'next/link';
import { Artwork } from '@/components/ui/artwork';
import { Button } from '@/components/ui/button';
import { EmptyState } from '@/components/ui/empty-state';
import { getEntityById, hrefForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';
import type { Profile } from '@/lib/data/types';
import { formatDate } from '@/lib/utils';

export function ProfileListens({ profile, visible }: { profile: Profile; visible: boolean }) {
  const data = useResonoteStore((state) => state.data);
  const playSong = useResonoteStore((state) => state.playSong);

  if (!visible) {
    return (
      <EmptyState title="Listening history is private">
        Journal entries and liked music remain available on this profile.
      </EmptyState>
    );
  }

  const listens = data.listens
    .filter((listen) => listen.profileId === profile.id)
    .sort((a, b) => b.listenedAt.localeCompare(a.listenedAt));

  if (!listens.length) {
    return (
      <EmptyState title="No listens logged yet">
        Use “Log listen” on a song page to keep the event without having to turn it into a review.
      </EmptyState>
    );
  }

  return (
    <ol className="listen-timeline">
      {listens.map((listen) => {
        const entity = getEntityById(listen.songId);
        if (!entity || entity.kind !== 'song') return null;
        return (
          <li key={listen.id}>
            <Artwork entity={entity} size="md" record />
            <div className="listen-copy">
              <span className="eyebrow"><Headphones size={14} />{formatDate(listen.listenedAt)}</span>
              <Link href={hrefForEntity(entity)}>{entity.name}</Link>
              {listen.moods.length ? <div className="static-chip-row">{listen.moods.map((mood) => <span key={mood}>{mood}</span>)}</div> : null}
              {listen.note ? <p>{listen.note}</p> : null}
            </div>
            <div className="listen-actions">
              <Button variant="ghost" size="icon" aria-label={`Play ${entity.name}`} onClick={() => playSong(entity.id)}><Play size={18} /></Button>
              <Link className="button button--outline button--sm" href={`/write/song/${entity.id}`}><PenLine size={16} />Write</Link>
            </div>
          </li>
        );
      })}
    </ol>
  );
}
