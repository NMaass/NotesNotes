import { describe, expect, it } from 'vitest';
import {
  idsFromLinks,
  itunesMetadata,
  oembedMetadata,
  odesliMetadata,
  parseMusicLink,
  songlinkPageMetadata,
  splitYouTubeTitle,
  spotifyEmbedMetadata,
  UnsupportedLinkError,
} from '@/lib/music/links';

const nextData = (data: unknown) => `<html><script id="__NEXT_DATA__" type="application/json">${JSON.stringify(data)}</script></html>`;

describe('parseMusicLink', () => {
  it('reads Spotify track links, URIs, and locale prefixes into one canonical URL', () => {
    const canonical = 'https://open.spotify.com/track/4iV5W9uYEdYUVa79Axb7Rh';
    for (const input of [
      'https://open.spotify.com/track/4iV5W9uYEdYUVa79Axb7Rh?si=abc123',
      'https://open.spotify.com/intl-de/track/4iV5W9uYEdYUVa79Axb7Rh',
      'spotify:track:4iV5W9uYEdYUVa79Axb7Rh',
      'open.spotify.com/embed/track/4iV5W9uYEdYUVa79Axb7Rh',
    ]) {
      expect(parseMusicLink(input)).toMatchObject({ platform: 'spotify', id: '4iV5W9uYEdYUVa79Axb7Rh', canonicalUrl: canonical });
    }
  });

  it('reads Apple Music song and album?i= links', () => {
    expect(parseMusicLink('https://music.apple.com/us/album/lithium/1440783617?i=1440783764')).toMatchObject({
      platform: 'apple-music', id: '1440783764', canonicalUrl: 'https://music.apple.com/song/1440783764', openUrl: 'https://music.apple.com/us/song/1440783764',
    });
    expect(parseMusicLink('https://music.apple.com/gb/song/lithium/1440783764')).toMatchObject({ id: '1440783764', openUrl: 'https://music.apple.com/gb/song/1440783764' });
  });

  it('reads YouTube Music and YouTube links into one cache key but keeps the app to open', () => {
    const music = parseMusicLink('https://music.youtube.com/watch?v=pkcJEvMcnEg&feature=share');
    const video = parseMusicLink('https://youtu.be/pkcJEvMcnEg?t=10');
    expect(music).toMatchObject({ platform: 'youtube-music', id: 'pkcJEvMcnEg', openUrl: 'https://music.youtube.com/watch?v=pkcJEvMcnEg' });
    expect(video).toMatchObject({ platform: 'youtube', id: 'pkcJEvMcnEg' });
    expect(music.canonicalUrl).toBe(video.canonicalUrl);
    expect(parseMusicLink('https://m.youtube.com/watch?v=pkcJEvMcnEg').id).toBe('pkcJEvMcnEg');
    expect(parseMusicLink('https://www.youtube.com/shorts/pkcJEvMcnEg').id).toBe('pkcJEvMcnEg');
  });

  it('unwraps song.link short forms and embedded provider links', () => {
    expect(parseMusicLink('https://song.link/s/4iV5W9uYEdYUVa79Axb7Rh')).toMatchObject({ platform: 'spotify', id: '4iV5W9uYEdYUVa79Axb7Rh' });
    expect(parseMusicLink('https://song.link/us/i/1440783764')).toMatchObject({ platform: 'apple-music', id: '1440783764' });
    expect(parseMusicLink('https://song.link/y/pkcJEvMcnEg')).toMatchObject({ platform: 'youtube', id: 'pkcJEvMcnEg' });
    expect(parseMusicLink('https://song.link/https%3A%2F%2Fopen.spotify.com%2Ftrack%2F4iV5W9uYEdYUVa79Axb7Rh')).toMatchObject({ platform: 'spotify' });
    expect(parseMusicLink('https://song.link/nirvana-lithium')).toMatchObject({ platform: 'songlink', pagePath: '/nirvana-lithium', canonicalUrl: 'https://song.link/nirvana-lithium' });
    // Broken percent-encoding is a bad link (400), not a server error.
    expect(() => parseMusicLink('https://song.link/%E0%A4%A')).toThrow(UnsupportedLinkError);
  });

  it('refuses albums, playlists, and unknown hosts', () => {
    for (const input of [
      'https://open.spotify.com/album/1Ugdi2OTxKopVVqsprp5pb',
      'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
      'https://music.apple.com/us/album/nevermind/1440783617',
      'https://album.link/s/1Ugdi2OTxKopVVqsprp5pb',
      'https://example.com/track/1',
      'not a link at all',
      'ftp://open.spotify.com/track/4iV5W9uYEdYUVa79Axb7Rh',
    ]) {
      expect(() => parseMusicLink(input), input).toThrow(UnsupportedLinkError);
    }
  });
});

describe('provider metadata', () => {
  it('reads the Spotify embed page data (title, all artists, duration, largest image)', () => {
    const html = nextData({ props: { pageProps: { state: { data: { entity: {
      name: 'Prelude for Piano No. 11 in F-Sharp Minor',
      artists: [{ name: 'Eduard Abramyan' }, { name: 'Sona Shaboyan' }],
      duration: 248293,
      visualIdentity: { image: [
        { url: 'https://image-cdn-ak.spotifycdn.com/image/small', maxWidth: 64 },
        { url: 'https://image-cdn-ak.spotifycdn.com/image/large', maxWidth: 640 },
      ] },
    } } } } } });
    expect(spotifyEmbedMetadata(html, '4iV5W9uYEdYUVa79Axb7Rh')).toEqual({
      title: 'Prelude for Piano No. 11 in F-Sharp Minor',
      artist: 'Eduard Abramyan, Sona Shaboyan',
      durationMs: 248293,
      artworkURL: 'https://image-cdn-ak.spotifycdn.com/image/large',
      spotifyId: '4iV5W9uYEdYUVa79Axb7Rh',
    });
    expect(spotifyEmbedMetadata('<html></html>', 'x')).toBeNull();
  });

  it('keeps at least a title from Spotify oEmbed', () => {
    expect(oembedMetadata({ title: 'Lithium', thumbnail_url: 'https://i.scdn.co/x' }, 'spotify', 'id')).toMatchObject({ title: 'Lithium', artist: '', artworkURL: 'https://i.scdn.co/x' });
  });

  it('splits YouTube titles', () => {
    expect(oembedMetadata({ title: 'Nirvana - Lithium (Official Music Video)', author_name: 'NirvanaVEVO', thumbnail_url: 'https://i.ytimg.com/vi/pkcJEvMcnEg/hqdefault.jpg' }, 'youtube', 'pkcJEvMcnEg'))
      .toMatchObject({ title: 'Lithium', artist: 'Nirvana', youtubeId: 'pkcJEvMcnEg' });
    expect(splitYouTubeTitle('Lithium', 'Nirvana - Topic')).toEqual({ title: 'Lithium', artist: 'Nirvana' });
    // Only auto-generated "Artist - Topic" uploads count as the label's own audio.
    expect(oembedMetadata({ title: 'Lithium', author_name: 'Nirvana - Topic' }, 'youtube', 'pkcJEvMcnEg')).toMatchObject({ officialAudio: true });
    expect(oembedMetadata({ title: 'Nirvana - Lithium', author_name: 'NirvanaVEVO' }, 'youtube', 'pkcJEvMcnEg')).toMatchObject({ officialAudio: false });
    expect(splitYouTubeTitle('Some Resolve [Official Audio]', 'RoyksoppVEVO')).toEqual({ title: 'Some Resolve', artist: 'Royksopp' });
  });

  it('reads an iTunes lookup at 600 px artwork', () => {
    const payload = { resultCount: 1, results: [{ wrapperType: 'track', trackId: 1440783764, trackName: 'Lithium', artistName: 'Nirvana', collectionName: 'Nevermind', trackTimeMillis: 257048,
      artworkUrl100: 'https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/95/fd/b9/00602527874609.rgb.jpg/100x100bb.jpg' }] };
    expect(itunesMetadata(payload, '1440783764')).toEqual({
      title: 'Lithium', artist: 'Nirvana', album: 'Nevermind', durationMs: 257048,
      artworkURL: 'https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/95/fd/b9/00602527874609.rgb.jpg/600x600bb.jpg',
      appleMusicId: '1440783764',
    });
    expect(itunesMetadata({ resultCount: 0, results: [] }, '1')).toBeNull();
  });

  it('reads song.link page data and cross-platform ids', () => {
    const html = nextData({ props: { pageProps: { pageData: { sections: [
      { title: 'Prelude for Piano No. 11', artistName: 'Eduard Abramyan, Sona Shaboyan', thumbnailUrl: 'https://i.scdn.co/image/x' },
      { links: [
        { platform: 'spotify', url: 'https://open.spotify.com/track/4iV5W9uYEdYUVa79Axb7Rh' },
        { platform: 'tidal', url: 'https://listen.tidal.com/track/25159364' },
        { platform: 'appleMusic' },
      ] },
    ] } } } });
    expect(songlinkPageMetadata(html)).toEqual({ title: 'Prelude for Piano No. 11', artist: 'Eduard Abramyan, Sona Shaboyan', artworkURL: 'https://i.scdn.co/image/x', spotifyId: '4iV5W9uYEdYUVa79Axb7Rh' });
  });

  it('maps the documented Odesli response', () => {
    const payload = {
      entityUniqueId: 'SPOTIFY_SONG::4iV5W9uYEdYUVa79Axb7Rh',
      entitiesByUniqueId: { 'SPOTIFY_SONG::4iV5W9uYEdYUVa79Axb7Rh': { title: 'Lithium', artistName: 'Nirvana', thumbnailUrl: 'https://i.scdn.co/t' } },
      linksByPlatform: {
        spotify: { url: 'https://open.spotify.com/track/2YodwKJnbPyNKe8XXSE9V7' },
        appleMusic: { url: 'https://music.apple.com/us/album/lithium/1440783617?i=1440783764' },
        youtubeMusic: { url: 'https://music.youtube.com/watch?v=pkcJEvMcnEg' },
      },
    };
    expect(odesliMetadata(payload)).toEqual({ title: 'Lithium', artist: 'Nirvana', artworkURL: 'https://i.scdn.co/t', spotifyId: '2YodwKJnbPyNKe8XXSE9V7', appleMusicId: '1440783764', youtubeId: 'pkcJEvMcnEg' });
    expect(idsFromLinks(['https://www.deezer.com/track/1'])).toEqual({});
  });
});
