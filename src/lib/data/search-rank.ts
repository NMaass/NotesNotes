// Pure ranking for GET /api/catalog/search. Mirrors searchLocalCatalog in
// selectors.ts (exact 100 · prefix 70 · contains 40 on NFKD-normalized names
// and aliases, then name) so the phone and the web order results the same way.
import type { CatalogEntity } from '@/lib/data/types';
import { normalizeSearch } from '@/lib/music/text';

export interface RankInput {
  entity: CatalogEntity;
  aliases?: string[];
  /** Seeded rows win over D1 rows that describe the same MusicBrainz entity. */
  origin: 'seed' | 'd1';
  /**
   * Extra identities (e.g. "song:<artist mbid>:<folded title>") for rows that have
   * no MusicBrainz id of their own, like seeded songs: a D1 row sharing one with a
   * seeded row is the same entity imported again.
   */
  keys?: string[];
}

export function matchScore(query: string, names: string[]): number {
  const q = normalizeSearch(query);
  if (!q) return 0;
  const haystack = names.map(normalizeSearch);
  if (haystack.some((value) => value === q)) return 100;
  if (haystack.some((value) => value.startsWith(q))) return 70;
  if (haystack.some((value) => value.includes(q))) return 40;
  return 0;
}

function identities(row: RankInput): string[] {
  return [...(row.entity.musicbrainzId ? [`${row.entity.kind}:${row.entity.musicbrainzId}`] : []), ...(row.keys ?? [])];
}

/** Drops D1 rows whose MusicBrainz id (per kind) or identity key already belongs to a seeded row. */
export function dedupeAgainstSeed(rows: RankInput[]): RankInput[] {
  const seeded = new Set(rows.filter((row) => row.origin === 'seed').flatMap(identities));
  const seenIds = new Set<string>();
  return rows.filter((row) => {
    if (seenIds.has(row.entity.id)) return false;
    seenIds.add(row.entity.id);
    return row.origin === 'seed' || !identities(row).some((key) => seeded.has(key));
  });
}

/** Scores, filters, and orders one complete batch of results. */
export function rankCatalog(query: string, rows: RankInput[], limit: number): RankInput[] {
  return dedupeAgainstSeed(rows)
    .map((row) => ({ row, score: matchScore(query, [row.entity.name, ...(row.aliases ?? [])]) }))
    .filter((item) => item.score > 0)
    .sort((a, b) => b.score - a.score || a.row.entity.name.localeCompare(b.row.entity.name))
    .slice(0, limit)
    .map((item) => item.row);
}
