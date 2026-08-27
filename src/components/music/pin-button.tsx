'use client';
import { Pin } from 'lucide-react';
import { useAuth } from '@/components/auth/auth-provider';
import { Button } from '@/components/ui/button';
import { StableText } from '@/components/ui/stable-swap';
import { useResonoteStore } from '@/lib/data/store';

export function PinButton({ targetType, targetId }: { targetType: 'entity' | 'entry' | 'collection'; targetId: string }) {
  const { profile, requireAuth } = useAuth();
  const pins = useResonoteStore((state) => state.data.pins);
  const toggle = useResonoteStore((state) => state.togglePin);
  const pinned = Boolean(profile && pins.some((pin) => pin.profileId === profile.id && pin.targetType === targetType && pin.targetId === targetId));
  const act = () => toggle(targetType, targetId);
  return <Button variant="ghost" className="stable-action" aria-pressed={pinned} onClick={() => { if (requireAuth(act)) act(); }}><Pin size={17} fill={pinned ? 'currentColor' : 'none'} /><StableText value={pinned ? 'Pinned' : 'Pin'} candidates={['Pin', 'Pinned']} /></Button>;
}
