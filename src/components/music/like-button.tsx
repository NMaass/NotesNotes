'use client';
import { Heart } from 'lucide-react';
import { useAuth } from '@/components/auth/auth-provider';
import { Button } from '@/components/ui/button';
import { StableText } from '@/components/ui/stable-swap';
import type { CatalogEntity } from '@/lib/data/types';
import { useResonoteStore } from '@/lib/data/store';

export function LikeButton({ entity, compact = false }: { entity: CatalogEntity; compact?: boolean }) {
  const { profile, requireAuth } = useAuth();
  const likes = useResonoteStore((state) => state.data.likes);
  const toggleLike = useResonoteStore((state) => state.toggleLike);
  const liked = Boolean(profile && likes.some((like) => like.profileId === profile.id && like.entityId === entity.id));
  const act = () => toggleLike(entity.id, entity.kind);
  const handleClick = () => { if (requireAuth(act)) act(); };
  if (compact) {
    return (
      <Button
        variant="ghost"
        size="icon"
        aria-label={liked ? `Unlike ${entity.name}` : `Like ${entity.name}`}
        aria-pressed={liked}
        onClick={handleClick}
      >
        <Heart size={17} fill={liked ? 'currentColor' : 'none'} />
      </Button>
    );
  }
  return <Button variant={liked ? 'solid' : 'outline'} className="stable-action" aria-pressed={liked} onClick={handleClick}><Heart size={18} fill={liked ? 'currentColor' : 'none'} /><StableText value={liked ? 'Liked' : 'Like'} candidates={['Like', 'Liked']} /></Button>;
}
