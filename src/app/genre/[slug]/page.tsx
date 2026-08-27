import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { EntityPage } from '@/components/entity/entity-page';
import { catalogLists } from '@/lib/data/selectors';
export async function generateMetadata({params}:{params:Promise<{slug:string}>}):Promise<Metadata>{const{slug}=await params;const genre=catalogLists.genres.find((x)=>x.slug===slug);return genre?{title:genre.name,description:genre.description}:{};}
export default async function Page({params}:{params:Promise<{slug:string}>}){const{slug}=await params;const genre=catalogLists.genres.find((x)=>x.slug===slug);if(!genre)notFound();return <EntityPage entity={genre}/>;}
