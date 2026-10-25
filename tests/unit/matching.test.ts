import { describe, expect, it } from 'vitest';
import {
  classifyCandidate,
  durationCloseness,
  fallbackSearchQuery,
  isAnthology,
  keyRank,
  luceneQuote,
  pickIsrcRecording,
  preferredRelease,
  rankRecordings,
  recordingSearchQuery,
  recordingToSearchResult,
  resolutionKeys,
  textKey,
  topGenres,
  trackNamesSong,
  trackPlausiblyIs,
  VARIOUS_ARTISTS_MBID,
  type MbRecording,
} from '@/lib/music/matching';

const nirvana = [{ name: 'Nirvana', joinphrase: '', artist: { id: '5b11f4ce-a62d-471e-81fc-a69a8278c7da', name: 'Nirvana' } }];
const album = (title: string, secondary: string[] = []) => ({ id: `rel-${title}`, title, status: 'Official', date: '1991-09-24', 'release-group': { id: `rg-${title}`, title, 'primary-type': 'Album', 'secondary-types': secondary } });

// Shaped like the live search for recording:"Lithium" AND artist:"Nirvana" (2026-10-24).
const lithiumResults: MbRecording[] = [
  { id: '9ec74b05', title: 'Lithium', length: 236800, 'artist-credit': nirvana, 'first-release-date': '2025-09-12', releases: [album('The Show Must Go On', ['Compilation'])] },
  { id: '86900fb6', title: 'Lithium', length: 256000, disambiguation: 'live, 1991-11-25: Paradiso, Amsterdam', 'artist-credit': nirvana, releases: [album('Nevermind'), album('Nevermind')] },
  { id: '71a43b7b', title: 'Lithium', length: 104000, disambiguation: 'part of “Apple Music 100 Best Albums” DJ‐mix', 'artist-credit': nirvana, releases: [album('Apple Music 100 Best Albums', ['DJ-mix'])] },
  { id: '3fac712c', title: 'Lithium', length: 257040, 'artist-credit': nirvana, 'first-release-date': '1991-09-24', releases: Array.from({ length: 40 }, () => album('Nevermind')) },
  { id: 'ca7c5b26', title: 'Lithium (music video)', length: 255000, 'artist-credit': nirvana, releases: [album('Nevermind')] },
];

describe('MusicBrainz search query', () => {
  it('fields title and primary artist, escapes quotes, and does not exclude compilations', () => {
    expect(recordingSearchQuery('Lithium - Remastered 2011', 'Nirvana feat. Nobody')).toBe('recording:"Lithium" AND artist:"Nirvana" AND status:official AND NOT secondarytype:live');
    expect(luceneQuote('Say "Hi" \\ now')).toBe('"Say \\"Hi\\" \\\\ now"');
    expect(recordingSearchQuery('', 'Nirvana')).toBeNull();
  });

  it('narrows to the source length when it is known', () => {
    // "One More Time" by Daft Punk matches 74 recordings scored 100; the Discovery one is not in the first 25.
    expect(recordingSearchQuery('One More Time', 'Daft Punk', 320357))
      .toBe('recording:"One More Time" AND artist:"Daft Punk" AND status:official AND NOT secondarytype:live AND dur:[315357 TO 325357]');
  });

  it('falls back to any credited artist with a similar length, or title words', () => {
    // Spotify lists the composer first; MusicBrainz credits the performer.
    expect(fallbackSearchQuery('Prelude for Piano No. 11 in F-Sharp Minor', 'Eduard Abramyan, Sona Shaboyan', 248293))
      .toBe('(artist:"Eduard Abramyan" OR artist:"Sona Shaboyan") AND dur:[243293 TO 253293]');
    expect(fallbackSearchQuery('Prelude No. 11 (Remastered)', 'Sona Shaboyan')).toBe('(artist:"Sona Shaboyan") AND recording:(prelude no 11)');
    expect(fallbackSearchQuery('x', '')).toBeNull();
  });
});

describe('candidate scoring', () => {
  it('classifies duration closeness', () => {
    expect(durationCloseness(257000, 260000)).toBe('strong');
    expect(durationCloseness(257000, 270000)).toBe('ok');
    expect(durationCloseness(257000, 300000)).toBe('far');
    expect(durationCloseness(undefined, 300000)).toBe('unknown');
  });

  it('ranks the canonical studio recording first and calls it strong', () => {
    const ranked = rankRecordings({ title: 'Lithium', artist: 'Nirvana', durationMs: 257048 }, lithiumResults);
    expect(ranked[0].recording.id).toBe('3fac712c');
    expect(classifyCandidate(ranked[0])).toBe('strong');
  });

  it('still prefers the canonical recording without a duration', () => {
    const ranked = rankRecordings({ title: 'Lithium', artist: 'Nirvana' }, lithiumResults);
    expect(ranked[0].recording.id).toBe('3fac712c');
    expect(classifyCandidate(ranked[0])).toBe('strong');
  });

  it('keeps live versions for listeners who are playing the live version', () => {
    const ranked = rankRecordings({ title: 'Lithium (Live)', artist: 'Nirvana', durationMs: 256000 }, lithiumResults);
    const live = ranked.find((candidate) => candidate.recording.id === '86900fb6')!;
    expect(live.versionMismatch).toBe(false);
  });

  it('is weak when durations disagree or the artist differs, and none without results', () => {
    const [far] = rankRecordings({ title: 'Lithium', artist: 'Nirvana', durationMs: 400000 }, [lithiumResults[3]]);
    expect(classifyCandidate(far)).toBe('weak');
    const [other] = rankRecordings({ title: 'Lithium', artist: 'Evanescence', durationMs: 257000 }, [lithiumResults[3]]);
    expect(classifyCandidate(other)).toBe('weak');
    expect(classifyCandidate(undefined)).toBe('none');
  });

  it('picks the best ISRC recording for the source text', () => {
    const recordings: MbRecording[] = [
      { id: 'video', title: 'Yellow Submarine', video: true },
      { id: 'mix', title: 'Yellow Submarine (2022 mix)', length: 160000, 'artist-credit': [{ name: 'The Beatles' }] },
      { id: 'studio', title: 'Yellow Submarine', length: 160000, 'artist-credit': [{ name: 'The Beatles' }], disambiguation: 'original stereo studio mix' },
    ];
    expect(pickIsrcRecording({ title: 'Yellow Submarine', artist: 'The Beatles', durationMs: 159000 }, recordings)?.id).toBe('studio');
    expect(pickIsrcRecording({}, recordings)?.id).toBe('mix');
  });

  it('picks the canonical ISRC recording when the source sent no title', () => {
    // GBAYE9200070 (Radiohead, "Creep") is on the studio recording and on a copy that only one Various Artists compilation uses.
    const radiohead = [{ name: 'Radiohead', artist: { id: 'a74b1b7f-71a5-4011-9441-d0b5e4122711', name: 'Radiohead' } }];
    const recordings: MbRecording[] = [
      { id: 'compilation-only', title: 'Creep', length: 238000, 'artist-credit': radiohead, releases: [album('Festival Anthems', ['Compilation'])] },
      { id: 'studio', title: 'Creep', length: 238640, 'artist-credit': radiohead, releases: [album('Pablo Honey'), album('Pablo Honey'), album('Creep'), album('Hits', ['Compilation'])] },
    ];
    expect(pickIsrcRecording({ title: '', artist: '' }, recordings)?.id).toBe('studio');
    // Equal release counts: the one whose best release is a studio album wins.
    const tie: MbRecording[] = [
      { id: 'anthology', title: 'Creep', releases: [album('Hits', ['Compilation'])] },
      { id: 'album', title: 'Creep', releases: [album('Pablo Honey')] },
    ];
    expect(pickIsrcRecording({}, tie)?.id).toBe('album');
    // Without releases (the ISRC lookup's JSON omits them), the earliest recording wins.
    const bare: MbRecording[] = [
      { id: '1f9f17c7', title: 'Creep', 'first-release-date': '2017' },
      { id: '70595637', title: 'Creep', 'first-release-date': '1992-09-21' },
    ];
    expect(pickIsrcRecording({ title: '', artist: '' }, bare)?.id).toBe('70595637');
  });

  it('treats compilations, DJ mixes, and Various Artists releases as anthologies', () => {
    expect(isAnthology({ 'primary-type': 'Album', 'secondary-types': ['Compilation'] })).toBe(true);
    expect(isAnthology({ 'primary-type': 'Album', 'secondary-types': ['DJ-mix'] })).toBe(true);
    expect(isAnthology({ 'primary-type': 'Album', 'secondary-types': [] }, VARIOUS_ARTISTS_MBID)).toBe(true);
    expect(isAnthology({ 'primary-type': 'Album', 'secondary-types': ['Soundtrack'] }, 'some-artist')).toBe(false);
  });
});

describe('cache key verification', () => {
  const lithium = { name: 'Lithium' };

  it('rejects a cached id row that names a different song', () => {
    expect(trackPlausiblyIs({ title: 'Never Gonna Give You Up', artist: 'Rick Astley' }, lithium, 'Nirvana')).toBe(false);
    expect(trackPlausiblyIs({ title: 'Lithium - Remastered', artist: 'Nirvana' }, lithium, 'Nirvana')).toBe(true);
    // An id-only track cannot disagree.
    expect(trackPlausiblyIs({ title: '', artist: '' }, lithium, 'Nirvana')).toBe(true);
    // Classical: the source lists the composer, the catalog the performers; the title still agrees.
    expect(trackPlausiblyIs(
      { title: 'Symphony No. 9 in D Minor, Op. 125 "Choral": IV. Presto', artist: 'Ludwig van Beethoven' },
      { name: 'Symphony no. 9 in D minor, op. 125 “Choral”: IV. Presto – Allegro assai' },
      'Berliner Philharmoniker',
    )).toBe(true);
  });

  it('caches a text key only when title and artist name the song', () => {
    expect(trackNamesSong({ title: 'Lithium', artist: 'Nirvana' }, lithium, 'Nirvana')).toBe(true);
    expect(trackNamesSong({ title: 'Never Gonna Give You Up', artist: 'Rick Astley' }, lithium, 'Nirvana')).toBe(false);
    expect(trackNamesSong({ title: '', artist: '' }, lithium, 'Nirvana')).toBe(false);
    expect(textKey({ title: 'Lithium (2011 Remaster)', artist: 'Nirvana' })).toBe('text:nirvana|lithium');
    expect(textKey({ title: '', artist: 'Nirvana' })).toBeUndefined();
  });
});

describe('MusicBrainz shapes', () => {
  it('prefers an official studio album release', () => {
    const releases = [album('Hits', ['Compilation']), { ...album('Lithium'), 'release-group': { id: 'rg-single', title: 'Lithium', 'primary-type': 'Single', 'secondary-types': [] } }, album('Nevermind')];
    expect(preferredRelease(releases)?.['release-group']?.title).toBe('Nevermind');
  });

  it('builds unimported candidates with the same ids as /api/music/search', () => {
    expect(recordingToSearchResult(lithiumResults[3])).toEqual({
      entity: { id: 'mb-song-3fac712c', kind: 'song', name: 'Lithium', slug: 'lithium', artistId: 'remote-nirvana', albumId: 'remote-nevermind', durationMs: 257040, musicbrainzId: '3fac712c' },
      subtitle: 'Nirvana · Nevermind · MusicBrainz',
      source: 'musicbrainz',
    });
  });

  it('orders community genres by votes', () => {
    expect(topGenres([{ id: 'a', name: 'pop', count: 5 }, { id: 'b', name: 'rock', count: 14 }, { id: 'c', name: '' }], 2).map((genre) => genre.name)).toEqual(['rock', 'pop']);
  });
});

describe('resolution cache keys', () => {
  it('lists identifiers most trustworthy first', () => {
    const keys = resolutionKeys({ title: 'Lithium - Remastered', artist: 'Nirvana', mbid: 'ABC', isrc: 'usgf19100345', spotifyId: '2YodwKJnbPyNKe8XXSE9V7', appleMusicId: '1440783764', youtubeId: 'pkcJEvMcnEg' });
    expect(keys).toEqual([
      'mbid:abc',
      'isrc:USGF19100345',
      'url:https://open.spotify.com/track/2YodwKJnbPyNKe8XXSE9V7',
      'url:https://music.apple.com/song/1440783764',
      'url:https://www.youtube.com/watch?v=pkcJEvMcnEg',
      'text:nirvana|lithium',
    ]);
    expect(keys.map(keyRank)).toEqual([1, 2, 3, 3, 3, 4]);
    expect(resolutionKeys({ title: '', artist: '' })).toEqual([]);
  });
});
