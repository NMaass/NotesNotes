// Pure ordering rules for the "write about this?" suggestions returned by
// POST /api/music/resolve. Data loading lives in resolve.ts.
import type { MusicLens } from '@/lib/data/types';
import { stableHash } from '@/lib/music/text';

/** Writing prompts from src/components/journal/journal-editor.tsx (same order). */
export const PROMPTS = [
  'Where did this song take you?',
  'What did you notice this time?',
  'When did you first hear this?',
  'What does this take you back to?',
  'Did you used to dislike this? What changed?',
  'What does the performance do that the lyrics do not?',
  'What production choice keeps pulling your attention?',
  'What would you play immediately after this?',
  'What is hard to explain about this music?',
] as const;

/** Listen moods from src/components/music/listen-dialog.tsx (same order). */
export const MOODS = ['restless', 'warm', 'euphoric', 'heavy', 'lonely', 'focused', 'nostalgic', 'weightless'] as const;

export const LENS_PADDING: MusicLens[] = ['feeling', 'production', 'lyrics', 'context'];
const LENSES: MusicLens[] = ['feeling', 'lyrics', 'composition', 'performance', 'production', 'context'];

export interface GenreSuggestion { id: string; name: string; source: string }
export interface WeightedGenre extends GenreSuggestion { votes: number }

/**
 * Genres attached to the song, then its album, then its artist (each level by
 * votes), then MusicBrainz community genres; de-duplicated, first `limit`.
 */
export function orderGenreSuggestions(levels: WeightedGenre[][], musicbrainz: WeightedGenre[], limit = 4): GenreSuggestion[] {
  const seen = new Set<string>();
  const ordered: GenreSuggestion[] = [];
  const take = (list: WeightedGenre[]) => {
    for (const genre of [...list].sort((a, b) => b.votes - a.votes || a.name.localeCompare(b.name))) {
      if (ordered.length >= limit) return;
      if (seen.has(genre.id)) continue;
      seen.add(genre.id);
      ordered.push({ id: genre.id, name: genre.name, source: genre.source });
    }
  };
  for (const level of levels) take(level);
  take(musicbrainz);
  return ordered;
}

/** Most frequent lenses across public entries, padded with the default order. */
export function rankLenses(entryLenses: unknown[][], limit = 4): MusicLens[] {
  const counts = new Map<MusicLens, number>();
  for (const lenses of entryLenses) {
    for (const lens of new Set(lenses)) {
      if (LENSES.includes(lens as MusicLens)) counts.set(lens as MusicLens, (counts.get(lens as MusicLens) ?? 0) + 1);
    }
  }
  const ranked = [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || LENSES.indexOf(a[0]) - LENSES.indexOf(b[0]))
    .map(([lens]) => lens);
  return [...new Set([...ranked, ...LENS_PADDING])].slice(0, limit);
}

/**
 * The caller's own moods, most used first; moods used for this song count
 * three times. Padded with the standard moods so the list is always complete.
 */
export function rankMoods(listens: Array<{ songId: string; moods: unknown[] }>, songId: string | undefined, limit: number = MOODS.length): string[] {
  const counts = new Map<string, number>();
  for (const listen of listens) {
    const weight = songId && listen.songId === songId ? 3 : 1;
    for (const mood of new Set(listen.moods)) {
      if (typeof mood !== 'string') continue;
      const key = mood.trim().toLowerCase().slice(0, 40);
      if (key) counts.set(key, (counts.get(key) ?? 0) + weight);
    }
  }
  const standard: readonly string[] = MOODS;
  const ranked = [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || (standard.indexOf(a[0]) + 1 || 99) - (standard.indexOf(b[0]) + 1 || 99) || a[0].localeCompare(b[0]))
    .map(([mood]) => mood);
  return [...new Set([...ranked, ...MOODS])].slice(0, limit);
}

/**
 * A returning writer is asked what they noticed this time; someone who has
 * logged a listen but not written is asked about memory; everyone else gets a
 * stable pick (by song) from the remaining prompts.
 */
export function pickPrompt(input: { wroteBefore: boolean; listenedBefore: boolean; seed: string }): string {
  if (input.wroteBefore) return PROMPTS[1];
  if (input.listenedBefore) return PROMPTS[3];
  const pool = PROMPTS.slice(2);
  return pool[stableHash(input.seed) % pool.length];
}
