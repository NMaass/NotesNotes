import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';
import type { CatalogEntity, EntityKind } from '@/lib/data/types';
export function cn(...inputs: ClassValue[]) { return twMerge(clsx(inputs)); }
export function slugify(value: string) { return value.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[’']/g, '').replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 80); }
export function formatDuration(durationMs?: number) { if (!durationMs) return null; const seconds = Math.round(durationMs / 1000); return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`; }
export function formatCompactNumber(value: number) { return new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 1 }).format(value); }
export function formatDate(value: string) { return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(value)); }
export function kindLabel(kind: EntityKind) { return ({ artist: 'Artist', album: 'Album', song: 'Song', genre: 'Genre' } as const)[kind]; }
export function uid(_prefix: string) { if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) return crypto.randomUUID(); const bytes = Array.from({ length: 16 }, () => Math.floor(Math.random() * 256)); bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128; const hex = bytes.map((value) => value.toString(16).padStart(2, '0')).join(''); return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`; }
export function dedupe<T>(values: T[]) { return [...new Set(values)]; }
export function clampText(value: string, length = 140) { return value.length > length ? `${value.slice(0, length - 1).trim()}…` : value; }
export function absoluteUrl(path: string) { const base = process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, '') ?? 'http://localhost:3000'; return `${base}${path.startsWith('/') ? path : `/${path}`}`; }
export function isPlayable(entity: CatalogEntity): entity is Extract<CatalogEntity, { kind: 'song' }> { return entity.kind === 'song' && Boolean(entity.spotifyId || entity.youtubeId); }
