import type { Metadata } from 'next';
import { CollectionRoute } from '@/components/profile/collection-route';
import { getCollectionBySlug } from '@/lib/data/selectors';

export async function generateMetadata({
  params,
}: {
  params: Promise<{ handle: string; slug: string }>;
}): Promise<Metadata> {
  const { handle, slug } = await params;
  const collection = getCollectionBySlug(handle, slug);
  return collection
    ? { title: collection.name, description: collection.description }
    : { title: slug.replaceAll('-', ' ') };
}

export default async function Page({
  params,
}: {
  params: Promise<{ handle: string; slug: string }>;
}) {
  const { handle, slug } = await params;
  return <CollectionRoute handle={handle} slug={slug} />;
}
