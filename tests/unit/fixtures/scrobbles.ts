// Trimmed from live responses (ListenBrainz, 2026-10-24) and the documented
// Last.fm user.getRecentTracks JSON shape (no API key was available to record one).

export const listenBrainzListen = {
  inserted_at: 1771414107,
  listened_at: 1771414109,
  recording_msid: 'fd0cad33-ea33-453b-8155-1292379277db',
  track_metadata: {
    additional_info: {
      artist_mbids: ['1c70a3fc-fa3c-4be1-8b55-c3192db8a884'],
      artist_names: ['Röyksopp'],
      duration_ms: 402390,
      recording_mbid: '30d08f4c-d825-4ae1-b79c-44242cddd7c0',
      release_group_mbid: '1d98b0bc-5832-49d2-a93e-463032631a2f',
      release_mbid: 'f1418001-7f1e-46af-bfdb-95faeded8841',
      submission_client: 'navidrome',
      tracknumber: 10,
    },
    artist_name: 'Röyksopp',
    mbid_mapping: {
      artist_mbids: ['1c70a3fc-fa3c-4be1-8b55-c3192db8a884'],
      caa_id: 32916450708,
      caa_release_mbid: 'f1418001-7f1e-46af-bfdb-95faeded8841',
      recording_mbid: '30d08f4c-d825-4ae1-b79c-44242cddd7c0',
      recording_name: 'Some Resolve',
      release_group_mbid: '1d98b0bc-5832-49d2-a93e-463032631a2f',
      url_rels: [
        { type: 'free streaming', url: 'https://www.deezer.com/track/1787299817' },
        { type: 'free streaming', url: 'https://open.spotify.com/track/7H7RaiZoTNPwjNLygV4fXQ' },
      ],
    },
    release_name: 'Profound Mysteries II',
    track_name: 'Some Resolve',
  },
  user_name: 'rob',
};

/** playing-now listens carry no listened_at and usually no mbid_mapping. */
export const listenBrainzPlayingNow = {
  payload: {
    count: 1,
    playing_now: true,
    user_id: 'mr_monkey',
    listens: [{
      playing_now: true,
      track_metadata: {
        additional_info: {
          duration_ms: 218707,
          media_player: 'Spotify',
          spotify_id: 'https://open.spotify.com/track/4iV5W9uYEdYUVa79Axb7Rh',
          isrc: 'gbaye0601498',
          submission_client: 'ListenBrainz Android',
        },
        artist_name: 'HENGE',
        release_name: 'Journey to Voltus B LP',
        track_name: 'Nuclear Fusion',
      },
    }],
  },
};

export const listenBrainzNothingPlaying = { payload: { count: 0, listens: [], playing_now: true, user_id: 'rob' } };

export const lastfmNowPlaying = {
  recenttracks: {
    track: [
      {
        artist: { mbid: '5b11f4ce-a62d-471e-81fc-a69a8278c7da', '#text': 'Nirvana' },
        streamable: '0',
        image: [
          { size: 'small', '#text': 'https://lastfm.freetls.fastly.net/i/u/34s/abc.jpg' },
          { size: 'medium', '#text': 'https://lastfm.freetls.fastly.net/i/u/64s/abc.jpg' },
          { size: 'large', '#text': 'https://lastfm.freetls.fastly.net/i/u/174s/abc.jpg' },
          { size: 'extralarge', '#text': 'https://lastfm.freetls.fastly.net/i/u/300x300/abc.jpg' },
        ],
        mbid: '',
        album: { mbid: '', '#text': 'Nevermind' },
        name: 'Lithium',
        '@attr': { nowplaying: 'true' },
        url: 'https://www.last.fm/music/Nirvana/_/Lithium',
      },
      {
        artist: { mbid: '', '#text': 'my bloody valentine' },
        streamable: '0',
        image: [{ size: 'extralarge', '#text': 'https://lastfm.freetls.fastly.net/i/u/300x300/2a96cbd8b46e442fc41c2b86b821562f.png' }],
        mbid: '6c5ab2a4-4ab0-4f43-8d41-2b4a77c1e7b4',
        album: { mbid: '', '#text': 'Loveless' },
        name: 'When You Sleep',
        url: 'https://www.last.fm/music/my+bloody+valentine/_/When+You+Sleep',
        date: { uts: '1792859000', '#text': '24 Oct 2026, 16:23' },
      },
    ],
    '@attr': { user: 'someone', totalPages: '100', page: '1', perPage: '2', total: '200' },
  },
};
