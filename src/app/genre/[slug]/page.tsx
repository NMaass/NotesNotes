import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { EntityPage } from '@/components/entity/entity-page';
import { catalogLists } from '@/lib/data/selectors';
import type { Genre } from '@/lib/data/types';
import { getDb } from '@/lib/server/db';
import { findStoredGenreBySlug } from '@/lib/server/repo';

/** Seeded genres first; genres created from MusicBrainz suggestions live in D1. */
async function findGenre(slug: string): Promise<Genre | undefined> {
  const seeded = catalogLists.genres.find((x) => x.slug === slug);
  if (seeded) return seeded;
  if (!(await getDb())) return undefined;
  return (await findStoredGenreBySlug(slug).catch(() => null)) ?? undefined;
}
export async function generateMetadata({params}:{params:Promise<{slug:string}>}):Promise<Metadata>{const{slug}=await params;const genre=await findGenre(slug);return genre?{title:genre.name,description:genre.description}:{};}
export default async function Page({params}:{params:Promise<{slug:string}>}){const{slug}=await params;const genre=await findGenre(slug);if(!genre)notFound();return <EntityPage entity={genre}/>;}
