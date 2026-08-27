import type { Metadata } from 'next';
import { ProfileRoute } from '@/components/profile/profile-route';
import { getProfileByHandle, getProfileEntityByPath } from '@/lib/data/selectors';

export async function generateMetadata({
  params,
}: {
  params: Promise<{ handle: string; segments?: string[] }>;
}): Promise<Metadata> {
  const { handle, segments } = await params;
  const profile = getProfileByHandle(handle);
  if (!profile) return { title: `@${handle.replace(/^@/, '')}` };
  if (!segments?.length) {
    return { title: `${profile.displayName} (@${profile.handle})`, description: profile.bio };
  }
  const entity = getProfileEntityByPath(segments);
  return entity
    ? { title: `${profile.displayName} on ${entity.name}`, description: `${profile.displayName}'s Resonote journal about ${entity.name}.` }
    : {};
}

export default async function Page({
  params,
}: {
  params: Promise<{ handle: string; segments?: string[] }>;
}) {
  const { handle, segments } = await params;
  return <ProfileRoute handle={handle} segments={segments} />;
}
