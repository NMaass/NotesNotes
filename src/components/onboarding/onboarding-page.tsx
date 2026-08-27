'use client';
import { ArrowRight, Check, Heart } from 'lucide-react';
import { useRouter } from 'next/navigation';
import { useMemo, useState } from 'react';
import { useAuth } from '@/components/auth/auth-provider';
import { Artwork } from '@/components/ui/artwork';
import { Button } from '@/components/ui/button';
import { Chip } from '@/components/ui/chip';
import { catalogLists, getRecommendedAlbumsForGenres } from '@/lib/data/selectors';
import { useResonoteStore } from '@/lib/data/store';

export function OnboardingPage() {
  const router = useRouter();
  const { profile, openAuth } = useAuth();
  const likes = useResonoteStore((state) => state.data.likes);
  const toggleLike = useResonoteStore((state) => state.toggleLike);
  const setGenres = useResonoteStore((state) => state.setGenrePreferences);
  const [selected, setSelected] = useState<string[]>(profile?.genreIds ?? []);
  const albums = useMemo(() => getRecommendedAlbumsForGenres(selected), [selected]);
  if (!profile) return <div className="onboarding-page"><div className="onboarding-intro"><span className="eyebrow">No password</span><h1>Make a place for what you hear.</h1><p>Use email and a one-time code. In local demo mode, the code is 000000.</p><Button size="lg" onClick={openAuth}>Continue with email <ArrowRight /></Button></div></div>;
  const done = () => { setGenres(selected); router.push(`/@${profile.handle}`); };
  return <div className="page-shell onboarding-page"><header><span className="eyebrow">First, tune the starting shelf</span><h1>What do you find yourself listening to?</h1><p>This only shapes the albums shown below. It does not lock you into a genre profile.</p></header><div className="genre-picker">{catalogLists.genres.map((genre) => <Chip key={genre.id} selected={selected.includes(genre.id)} onClick={() => setSelected((current) => current.includes(genre.id) ? current.filter((id) => id !== genre.id) : [...current, genre.id])}>{genre.name}</Chip>)}</div>{albums.length ? <section className="onboarding-albums"><div className="section-heading"><div><span className="eyebrow">Anything here you love?</span><h2>Build an initial library</h2></div></div><div className="album-pick-grid">{albums.map((album) => { const liked = likes.some((like) => like.profileId === profile.id && like.entityId === album.id); return <button type="button" className={liked ? 'album-pick album-pick--liked' : 'album-pick'} key={album.id} onClick={() => toggleLike(album.id, 'album')}><Artwork entity={album} size="lg" record /><span><strong>{album.name}</strong><small>{album.year}</small></span><em>{liked ? <><Check />Loved</> : <><Heart />I love this</>}</em></button>; })}</div></section> : null}<div className="onboarding-footer"><Button size="lg" onClick={done}>Open my journal <ArrowRight /></Button></div></div>;
}
