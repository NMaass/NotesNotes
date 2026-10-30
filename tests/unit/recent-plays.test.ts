import { describe, expect, it } from 'vitest';
import {
  mapLastfmRecentList,
  mapListenBrainzListens,
  mergeRecentPlays,
  RECENT_LIMIT,
  type NowPlayingTrack,
} from '@/lib/music/scrobbles';
import { lastfmNowPlaying, listenBrainzListen } from './fixtures/scrobbles';

const NOW = 1792859270_000; // 2026-10-24T16:27:50Z
const MIN = 60_000;

function play(title: string, minutesAgo: number, extra: Partial<NowPlayingTrack> = {}): NowPlayingTrack {
  return { title, artist: 'Radiohead', source: 'lastfm', isPlaying: false, observedAt: new Date(NOW - minutesAgo * MIN).toISOString(), ...extra };
}

describe('recent plays from each service', () => {
  it('maps every Last.fm row with no ten-minute window', () => {
    const list = mapLastfmRecentList(lastfmNowPlaying, NOW + 3_600_000);
    expect(list.map((track) => [track.title, track.isPlaying])).toEqual([['Lithium', true], ['When You Sleep', false]]);
    expect(list[1].observedAt).toBe(new Date(1792859000_000).toISOString());
  });

  it('skips finished Last.fm rows without a date and answers [] for errors', () => {
    const undated = { ...lastfmNowPlaying.recenttracks.track[1], date: undefined };
    expect(mapLastfmRecentList({ recenttracks: { track: [undated] } }, NOW)).toEqual([]);
    expect(mapLastfmRecentList({ error: 6 }, NOW)).toEqual([]);
  });

  it('maps every dated ListenBrainz listen at its listened_at', () => {
    const older = { ...listenBrainzListen, listened_at: listenBrainzListen.listened_at - 600 };
    const list = mapListenBrainzListens({ payload: { listens: [listenBrainzListen, older, { track_metadata: listenBrainzListen.track_metadata }] } }, NOW);
    expect(list).toHaveLength(2);
    expect(list.every((track) => !track.isPlaying && track.source === 'listenbrainz')).toBe(true);
    expect(list[0].observedAt).toBe(new Date(listenBrainzListen.listened_at * 1000).toISOString());
    expect(mapListenBrainzListens(null, NOW)).toEqual([]);
  });
});

describe('mergeRecentPlays', () => {
  it('orders the playing row first, then newest first', () => {
    const merged = mergeRecentPlays([
      [play('Nude', 20), play('Reckoner', 5)],
      [play('Bodysnatchers', 1, { isPlaying: true, source: 'listenbrainz' }), play('15 Step', 40, { source: 'listenbrainz' })],
    ]);
    expect(merged.map((track) => track.title)).toEqual(['Bodysnatchers', 'Reckoner', 'Nude', '15 Step']);
  });

  it('merges reports of the same play and fills identifiers only the other had', () => {
    const merged = mergeRecentPlays([
      [play('Weird Fishes / Arpeggi', 2, { album: 'In Rainbows' })],
      [play('Weird Fishes/Arpeggi', 6, { source: 'listenbrainz', mbid: '0b6ddb52-b0a1-4b3a-9c1f-6f3b7d5e2a10', durationMs: 318000, album: 'Other' })],
    ]);
    expect(merged).toHaveLength(1);
    expect(merged[0]).toMatchObject({ source: 'lastfm', album: 'In Rainbows', mbid: '0b6ddb52-b0a1-4b3a-9c1f-6f3b7d5e2a10', durationMs: 318000 });
  });

  it('matches on ISRC across differently written titles', () => {
    const merged = mergeRecentPlays([[play('Nude (Remastered)', 3, { isrc: 'GBSTK0700002' })], [play('Big Ideas', 4, { isrc: 'GBSTK0700002', artist: 'Radiohead' })]]);
    expect(merged).toHaveLength(1);
  });

  it('keeps repeat plays of a song that are ten minutes or more apart', () => {
    const merged = mergeRecentPlays([[play('Nude', 0), play('Nude', 10), play('Nude', 25)]]);
    expect(merged).toHaveLength(3);
  });

  it('keeps repeat plays of a song from one service, even minutes apart', () => {
    const looped = [play('Nude', 0, { isPlaying: true }), play('Nude', 3), play('Nude', 6)];
    expect(mergeRecentPlays([looped])).toHaveLength(3);
    // Each Last.fm row pairs with at most one ListenBrainz report of it.
    const merged = mergeRecentPlays([looped, [play('Nude', 1, { source: 'listenbrainz' }), play('Nude', 4, { source: 'listenbrainz' })]]);
    expect(merged).toHaveLength(3);
    expect(merged[0]).toMatchObject({ source: 'lastfm', isPlaying: true });
  });

  it('keeps one playing row: the newest sample wins, the same song collapses, a different song stays as history', () => {
    const lastfmPlaying = play('Reckoner', 0, { isPlaying: true, observedAt: new Date(NOW).toISOString() });
    const lbSame = play('Reckoner', 0, { isPlaying: true, source: 'listenbrainz', isrc: 'GBSTK0700005', observedAt: new Date(NOW - 1000).toISOString() });
    const same = mergeRecentPlays([[lastfmPlaying], [lbSame]]);
    expect(same).toHaveLength(1);
    expect(same[0]).toMatchObject({ source: 'lastfm', isPlaying: true, isrc: 'GBSTK0700005' });

    const lbOther = play('House of Cards', 0, { isPlaying: true, source: 'listenbrainz', observedAt: new Date(NOW - 1000).toISOString() });
    const other = mergeRecentPlays([[lastfmPlaying], [lbOther]]);
    expect(other.map((track) => [track.title, track.isPlaying])).toEqual([['Reckoner', true], ['House of Cards', false]]);
    expect(other.filter((track) => track.isPlaying)).toHaveLength(1);
  });

  it('prefers the playing report over a newer finished one of the same play', () => {
    const merged = mergeRecentPlays([[play('Videotape', 3, { isPlaying: true })], [play('Videotape', 1, { source: 'listenbrainz' })]]);
    expect(merged).toHaveLength(1);
    expect(merged[0]).toMatchObject({ source: 'lastfm', isPlaying: true });
  });

  it('caps the list and tolerates missing or empty services', () => {
    const many = Array.from({ length: 15 }, (_, index) => play(`Song ${index}`, index * 15));
    const merged = mergeRecentPlays([many, null, undefined, []]);
    expect(merged).toHaveLength(RECENT_LIMIT);
    expect(merged[0].title).toBe('Song 0');
    expect(mergeRecentPlays([null, []])).toEqual([]);
  });
});
