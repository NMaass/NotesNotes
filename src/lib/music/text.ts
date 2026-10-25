// Text normalization shared by search ranking and now-playing resolution.
// `fold`, `cleanTitle`, `primaryArtist`, and `matchKey` mirror TrackText in
// ios/Packages/ResonoteKit/Sources/ResonoteKit/NowPlaying/TrackText.swift so the
// phone and the server agree on when two tracks are "the same song".

const NON_ALPHANUMERIC = new RegExp('[^\\p{L}\\p{N}]+', 'gu');
const COMBINING_MARKS = new RegExp('\\p{M}+', 'gu');

/** Search normalization identical to the web's local search (selectors.ts). */
export function normalizeSearch(value: string): string {
  return value.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

/** Lowercased, diacritic-free, punctuation-collapsed text for comparisons. */
export function fold(value: string): string {
  return value
    .normalize('NFKD')
    .replace(COMBINING_MARKS, '')
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/[’']/g, '')
    .replace(NON_ALPHANUMERIC, ' ')
    .trim()
    .replace(/\s+/g, ' ');
}

const NOISE_MARKERS = [
  'remaster', 'remastered', 'deluxe', 'anniversary', 'edition', 'explicit', 'clean',
  'mono', 'stereo', 'single version', 'album version', 'radio edit', 'bonus track',
];

function isNoise(fragment: string): boolean {
  const folded = fold(fragment);
  if (!folded) return false;
  return NOISE_MARKERS.some((marker) => folded.includes(marker));
}

/**
 * The title without featured-artist credits and remaster/edition noise. Live,
 * acoustic, demo, and remix markers stay: those are different recordings.
 */
export function cleanTitle(title: string): string {
  let result = title;
  // "Song (feat. X)", "Song [with X]"
  result = result.replace(/\s*[([]\s*(feat\.?|ft\.?|featuring|with)\s[^)\]]*[)\]]/gi, '');
  // "Song - feat. X"
  result = result.replace(/\s+-\s+(feat\.?|ft\.?|featuring)\s.*$/i, '');
  // "Song (2011 Remaster)", "Song [Deluxe Edition]"
  result = result.replace(/\s*[([]([^)\]]*)[)\]]/g, (whole, inner: string) => (isNoise(inner) ? '' : whole));
  // "Song - Remastered 2011", "Song - Single Version"
  const dash = result.lastIndexOf(' - ');
  if (dash >= 0 && isNoise(result.slice(dash + 3))) result = result.slice(0, dash);
  return result.trim();
}

/** The primary artist: "A, B & C" and "A feat. B" both become "A". */
export function primaryArtist(artist: string): string {
  const separators = [/\s+(feat\.?|ft\.?|featuring|with|x|vs\.?)\s+/i, /\s*[,;/]\s*/, /\s+&\s+/];
  let result = artist;
  for (const separator of separators) {
    const match = separator.exec(result);
    if (match) result = result.slice(0, match.index);
  }
  return result.trim();
}

/** Every credited name: "A, B & C feat. D" → ["A", "B", "C", "D"]. */
export function splitArtists(artist: string): string[] {
  return artist
    .split(/\s+(?:feat\.?|ft\.?|featuring|with|x|vs\.?)\s+|\s*[,;/]\s*|\s+&\s+/i)
    .map((name) => name.trim())
    .filter(Boolean);
}

/** The key two sources must share to count as the same song. */
export function matchKey(artist: string, title: string): string {
  return `${fold(primaryArtist(artist))}|${fold(cleanTitle(title))}`;
}

/** Whether two artist strings name the same primary artist. */
export function sameArtist(a: string, b: string): boolean {
  const left = fold(primaryArtist(a));
  const right = fold(primaryArtist(b));
  if (!left || !right) return false;
  if (left === right) return true;
  // "The Smashing Pumpkins" vs "Smashing Pumpkins"
  const strip = (value: string) => value.replace(/^the /, '');
  return strip(left) === strip(right) || fold(a) === fold(b);
}

/** Whether two titles name the same song once version noise is removed. */
export function sameTitle(a: string, b: string): boolean {
  const left = fold(cleanTitle(a));
  return Boolean(left) && left === fold(cleanTitle(b));
}

/**
 * D1 rejects LIKE/GLOB patterns longer than 50 bytes ("pattern too complex").
 * Patterns are built from normalizeSearch output, which is ASCII, so bytes = characters.
 */
export const MAX_LIKE_PATTERN_BYTES = 50;

/**
 * `%tok1%tok2%…%` from the leading tokens that fit in MAX_LIKE_PATTERN_BYTES. A
 * pattern built from only some of the tokens over-matches, never under-matches:
 * callers always re-check candidates in JS (sameTitle, matchScore).
 */
function boundedPattern(tokens: string[]): string | null {
  let pattern = '%';
  for (const token of tokens) {
    const room = MAX_LIKE_PATTERN_BYTES - pattern.length - 1;
    if (room <= 0) break;
    if (token.length > room) {
      // Only the first token is ever cut: later ones are simply left out.
      if (pattern === '%') pattern += `${token.slice(0, room)}%`;
      break;
    }
    pattern += `${token}%`;
  }
  return pattern === '%' ? null : pattern;
}

/**
 * A SQL LIKE pattern that over-matches `value`: every search token must appear
 * in order. Null when nothing searchable remains. At most 50 bytes (D1's limit).
 */
export function strictLikePattern(value: string): string | null {
  return boundedPattern(normalizeSearch(value).split(' ').filter(Boolean));
}

const WORD_SEPARATOR = new RegExp('[^\\p{L}\\p{N}]+', 'u');

/** Lowercased words as stored (NFC, marks dropped), split on anything that is not a letter or digit. */
function rawWords(value: string): string[] {
  return value.normalize('NFC').replace(COMBINING_MARKS, '').toLowerCase().split(WORD_SEPARATOR).filter(Boolean);
}

/**
 * One word as a LIKE fragment: ASCII consonants and digits stay literal; vowels
 * (which most often carry diacritics) and every non-ASCII letter match any one
 * character, so "bjork" and "Françoise" both find their stored spelling. Each
 * character maps to one byte, so the 50-byte budget counts characters.
 */
function looseWord(word: string): string {
  return [...word].map((char) => (/[a-z0-9]/.test(char) && !/[aeiouy]/.test(char) ? char : '_')).join('');
}

/**
 * A SQL LIKE pattern that over-matches `value` so a diacritic-insensitive
 * comparison can run afterwards in JS: every word must appear in order, with
 * vowels and non-ASCII letters wildcarded ("bjork" finds "Björk"). SQLite LIKE
 * is already ASCII case-insensitive. At most 50 bytes (D1's limit); long values
 * keep their leading words.
 */
export function likePattern(value: string): string | null {
  return boundedPattern(rawWords(value).map(looseWord));
}

/**
 * A loose LIKE pattern for the first word of the primary artist, ignoring a
 * leading "The". Every artist name `sameArtist` accepts contains it, so it can
 * narrow a SQL scan without losing matches. Null when nothing searchable remains.
 */
export function artistLikePattern(artist: string): string | null {
  const words = rawWords(primaryArtist(artist));
  const first = words[0] === 'the' && words.length > 1 ? words[1] : words[0];
  return first ? boundedPattern([looseWord(first)]) : null;
}

/**
 * `name like '<query>%'` for a prefix search, which SQLite can answer from a
 * NOCASE index on name instead of reading every row. Within D1's 50-byte limit
 * (cut on a character boundary). Null when the query is empty or holds LIKE
 * wildcards (`%`, `_`) or a backslash.
 */
export function prefixLikePattern(query: string): string | null {
  const raw = query.trim();
  if (!raw || /[%_\\]/.test(raw)) return null;
  const encoder = new TextEncoder();
  let prefix = '';
  for (const char of raw) {
    if (encoder.encode(`${prefix}${char}%`).length > MAX_LIKE_PATTERN_BYTES) break;
    prefix += char;
  }
  return `${prefix}%`;
}

/** FNV-1a: a small deterministic hash for stable picks. */
export function stableHash(value: string): number {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

/** Display name for a lowercase MusicBrainz genre: "baroque pop" → "Baroque pop". */
export function genreDisplayName(name: string): string {
  const trimmed = name.trim();
  return trimmed ? trimmed[0].toUpperCase() + trimmed.slice(1) : trimmed;
}
