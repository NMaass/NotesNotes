'use client';
import { ArrowRight, BookOpen, Headphones, Search, Sparkles } from 'lucide-react';
import Link from 'next/link';
import { CollectionCard } from '@/components/collections/collection-card';
import { EntityCard } from '@/components/entity/entity-card';
import { JournalEntryCard } from '@/components/journal/journal-entry-card';
import { useAuth } from '@/components/auth/auth-provider';
import { catalogLists, getPopularEntities } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';
import type { CatalogEntity } from '@/lib/data/types';

export function HomePage() {
  const { profile } = useAuth();
  const data = useResonoteStore((state) => state.data);
  const popular = getPopularEntities(data);
  const curated: CatalogEntity[] = [
    catalogLists.songs[3],
    catalogLists.albums[1],
    catalogLists.songs[7],
    catalogLists.albums[0],
  ];
  const activeEntities = [
    ...popular.map(({ entity }) => entity),
    ...curated,
  ].filter((entity, index, all) => all.findIndex((candidate) => candidate.id === entity.id) === index).slice(0, 4);
  const recentEntries = data.entries.filter((entry) => entry.public).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)).slice(0, 3);
  const featuredCollection = data.collections[0];
  const collectionOwner = data.profiles.find((candidate) => candidate.id === featuredCollection?.profileId);
  return (
    <div className="home-page">
      <section className="home-hero">
        <div className="home-hero-copy"><span className="eyebrow">A journal for close listening</span><h1>Describe what you hear.<br />Connect what it reminds you of.</h1><p>Resonote is for music as an art form: feelings, structure, production, memory, disagreement, and the links only a listener would make. No star ratings.</p><div className="home-hero-actions"><Link className="button button--solid button--lg" href={profile ? `/@${profile.handle}` : '/join'}>{profile ? 'Open your journal' : 'Start a journal'}<ArrowRight size={18} /></Link><Link className="button button--outline button--lg" href="/music/nirvana/nevermind/lithium"><Headphones size={18} />See an example</Link></div></div>
        <div className="hero-note-stack" aria-label="Example observations"><article><span>production</span><p>“The vocal sounds close and impossible to locate at the same time.”</p><small>linked to <strong>When You Sleep</strong></small></article><article><span>memory</span><p>“I did not understand this song until I heard it alone in a different city.”</p></article><article><span>composition</span><p>“The chorus does not release the tension. It changes its shape.”</p></article></div>
      </section>
      <section className="home-search-prompt"><Search /><div><strong>Already have something in mind?</strong><span>Use the search bar above to find an artist, album, song, or genre.</span></div><kbd>/</kbd></section>
      <section className="page-shell home-section"><div className="section-heading"><div><span className="eyebrow">Active now</span><h2>What people are thinking about</h2></div><Sparkles /></div><div className="entity-grid">{activeEntities.map((entity) => <EntityCard key={entity.id} entity={entity} />)}</div></section>
      <section className="home-dark-band"><div className="page-shell"><div className="section-heading"><div><span className="eyebrow">Recent observations</span><h2>Writing, not scoring</h2></div><BookOpen /></div><div className="journal-feed journal-feed--columns">{recentEntries.length ? recentEntries.map((entry) => { const author = data.profiles.find((candidate) => candidate.id === entry.profileId); return author ? <JournalEntryCard key={entry.id} entry={entry} profile={author} showEntity /> : null; }) : <article className="home-empty-observation"><strong>The first observation can be yours.</strong><p>Choose any song above, then write what you noticed without assigning it a score.</p></article>}</div></div></section>
      {featuredCollection && collectionOwner ? <section className="page-shell home-section"><div className="section-heading"><div><span className="eyebrow">Spiritually similar</span><h2>A collection can explain a feeling</h2></div></div><CollectionCard collection={featuredCollection} profile={collectionOwner} /></section> : null}
      <section className="page-shell home-principles"><article><strong>Links are deliberate.</strong><p>Type <kbd>\</kbd> in the editor and choose the exact piece of music you mean.</p></article><article><strong>Depth is optional.</strong><p>Credits, collaborators, key, tempo, and sources stay behind deliberate disclosure.</p></article><article><strong>Your actions stay predictable.</strong><p>Like changes one heart. Opening an album opens one album. Drafts remain yours.</p></article></section>
    </div>
  );
}
