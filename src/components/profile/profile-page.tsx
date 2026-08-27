'use client';
import * as Tabs from '@radix-ui/react-tabs';
import { AudioLines, BookOpen, Headphones, Library, ListMusic, Play, Radio, Sparkles } from 'lucide-react';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { CollectionCard } from '@/components/collections/collection-card';
import { CreateCollectionDialog } from '@/components/collections/create-collection-dialog';
import { JournalEntryCard } from '@/components/journal/journal-entry-card';
import { ProfileLibrary } from '@/components/profile/profile-library';
import { ProfileListens } from '@/components/profile/profile-listens';
import { ProfilePins } from '@/components/profile/profile-pins';
import { Artwork } from '@/components/ui/artwork';
import { EmptyState } from '@/components/ui/empty-state';
import { getCollaboratorInsights, getEntriesForProfile, getEntityById, hrefForEntity } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';

const profileTabs = ['journal', 'listens', 'library', 'collections'] as const;
type ProfileTab = typeof profileTabs[number];

function tabFromHash(): ProfileTab {
  if (typeof window === 'undefined') return 'journal';
  const value = window.location.hash.replace(/^#/, '');
  return profileTabs.includes(value as ProfileTab) ? value as ProfileTab : 'journal';
}

export function ProfilePage({ profileId }: { profileId: string }) {
  const data = useResonoteStore((state) => state.data);
  const activeProfileId = useResonoteStore((state) => state.activeProfileId);
  const playSong = useResonoteStore((state) => state.playSong);
  const [activeTab, setActiveTab] = useState<ProfileTab>('journal');

  useEffect(() => {
    const syncHash = () => setActiveTab(tabFromHash());
    syncHash();
    window.addEventListener('hashchange', syncHash);
    return () => window.removeEventListener('hashchange', syncHash);
  }, []);

  const changeTab = (value: string) => {
    const tab = profileTabs.includes(value as ProfileTab) ? value as ProfileTab : 'journal';
    setActiveTab(tab);
    window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}#${tab}`);
  };
  const profile = data.profiles.find((candidate) => candidate.id === profileId);
  if (!profile) return <div className="page-shell"><EmptyState title="Profile not found">This profile may be private or unavailable.</EmptyState></div>;
  const track = profile.profileSongId ? getEntityById(profile.profileSongId) : null;
  const entries = getEntriesForProfile(profile.id, data);
  const collections = data.collections.filter((collection) => collection.profileId === profile.id && collection.public);
  const insights = getCollaboratorInsights(profile, data);
  const own = activeProfileId === profile.id;
  return (
    <div className="page-shell profile-page">
      <header className="profile-header">
        <div className="profile-avatar">{profile.displayName.slice(0, 1)}</div>
        <div className="profile-copy"><span className="eyebrow">@{profile.handle}</span><h1>{profile.displayName}</h1><p>{profile.bio}</p><div className="static-chip-row">{profile.genreIds.map((id) => { const genre = getEntityById(id); return genre ? <Link key={id} href={hrefForEntity(genre)}>{genre.name}</Link> : null; })}</div></div>
        {track?.kind === 'song' ? <button type="button" className="profile-track" onClick={() => playSong(track.id)}><Artwork entity={track} size="md" record /><span><small><Radio size={14} />profile track</small><strong>{track.name}</strong><em><Play size={16} />play</em></span></button> : null}
      </header>
      <ProfilePins profile={profile} />
      {insights.length ? <section className="insight-panel"><div className="section-heading"><div><span className="eyebrow">{own ? 'A pattern in your library' : 'A pattern in this library'}</span><h2>{own ? 'Collaborators you keep finding' : 'Collaborators they keep finding'}</h2></div><Sparkles /></div>{insights.map((insight) => <div className="collaborator-insight" key={insight.collaboratorKey}><div><strong>{insight.name}</strong><span>{insight.roles.join(' · ')}</span></div><p>Appears across music you liked by {insight.artistIds.length} different artists.</p><div className="insight-evidence">{insight.songIds.map((id) => { const song = getEntityById(id); return song ? <Link key={id} href={hrefForEntity(song)}>{song.name}</Link> : null; })}</div></div>)}</section> : null}
      <Tabs.Root value={activeTab} onValueChange={changeTab} className="profile-tabs">
        <Tabs.List aria-label="Profile sections"><Tabs.Trigger value="journal"><BookOpen />Journal <span className="stable-number">{entries.length}</span></Tabs.Trigger>{own ? <Tabs.Trigger value="listens"><Headphones />Listens <span className="stable-number">{data.listens.filter((listen) => listen.profileId === profile.id).length}</span></Tabs.Trigger> : null}<Tabs.Trigger value="library"><Library />Library</Tabs.Trigger><Tabs.Trigger value="collections"><ListMusic />Collections <span className="stable-number">{collections.length}</span></Tabs.Trigger></Tabs.List>
        <Tabs.Content value="journal" id="journal"><div className="section-heading"><div><span className="eyebrow">Public writing</span><h2>Journal</h2></div></div><div className="journal-feed">{entries.length ? entries.map((entry) => <JournalEntryCard key={entry.id} entry={entry} profile={profile} showEntity />) : <EmptyState title="Nothing published yet">Thoughts will appear here without being reduced to scores.</EmptyState>}</div></Tabs.Content>
        <Tabs.Content value="listens" id="listens"><div className="section-heading"><div><span className="eyebrow">Private listening log</span><h2>Recent listens</h2></div><Headphones /></div><ProfileListens profile={profile} visible={own} /></Tabs.Content>
        <Tabs.Content value="library" id="library"><div className="section-heading"><div><span className="eyebrow">Affirmative taste</span><h2>Liked music</h2></div><AudioLines /></div><ProfileLibrary profile={profile} /></Tabs.Content>
        <Tabs.Content value="collections" id="collections"><div className="section-heading"><div><span className="eyebrow">Personal constellations</span><h2>Collections</h2></div>{own ? <CreateCollectionDialog /> : null}</div><div className="collection-grid">{collections.length ? collections.map((collection) => <CollectionCard key={collection.id} collection={collection} profile={profile} />) : <EmptyState title="No collections yet">This is where spiritual similarity gets a name.</EmptyState>}</div></Tabs.Content>
      </Tabs.Root>
    </div>
  );
}
