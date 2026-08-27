'use client';

import { ChevronDown, ChevronUp, Pause, Play, X } from 'lucide-react';
import Link from 'next/link';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Artwork } from '@/components/ui/artwork';
import { Button } from '@/components/ui/button';
import { catalog } from '@/lib/data/catalog';
import { getAlbumForSong, hrefForEntity } from '@/lib/data/selectors';
import { getPlayingSong, useResonoteStore } from '@/lib/data/store';

interface SpotifyPlaybackEvent {
  data?: { isPaused?: boolean };
}

interface SpotifyEmbedController {
  play: () => void;
  pause: () => void;
  seek?: (seconds: number) => void;
  destroy: () => void;
  addListener: (event: 'playback_update', listener: (event: SpotifyPlaybackEvent) => void) => void;
}

interface SpotifyIFrameApi {
  createController: (
    element: HTMLElement,
    options: { width: string; height: number; uri: string },
    callback: (controller: SpotifyEmbedController) => void,
  ) => void;
}

type SpotifyWindow = Window & {
  onSpotifyIframeApiReady?: (api: SpotifyIFrameApi) => void;
  __resonoteSpotifyApi?: SpotifyIFrameApi;
};

function YouTubeEmbed({ videoId, playing, expanded, title, seekMs, onSeekConsumed }: {
  videoId: string;
  playing: boolean;
  expanded: boolean;
  title: string;
  seekMs: number | null;
  onSeekConsumed: () => void;
}) {
  const frameRef = useRef<HTMLIFrameElement | null>(null);
  const siteOrigin = process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, '');
  const originParameter = siteOrigin ? `&origin=${encodeURIComponent(siteOrigin)}` : '';
  const [initialAutoplay] = useState(playing);
  const appliedSeekRef = useRef<number | null>(null);
  const playingRef = useRef(playing);

  useEffect(() => {
    playingRef.current = playing;
  }, [playing]);

  const sendPlaybackCommand = useCallback(() => {
    frameRef.current?.contentWindow?.postMessage(
      JSON.stringify({ event: 'command', func: playing ? 'playVideo' : 'pauseVideo', args: [] }),
      'https://www.youtube-nocookie.com',
    );
  }, [playing]);

  const applySeek = useCallback(() => {
    if (seekMs == null || appliedSeekRef.current === seekMs) return;
    frameRef.current?.contentWindow?.postMessage(
      JSON.stringify({ event: 'command', func: 'seekTo', args: [seekMs / 1000, true] }),
      'https://www.youtube-nocookie.com',
    );
    appliedSeekRef.current = seekMs;
    onSeekConsumed();
    if (playingRef.current) sendPlaybackCommand();
  }, [seekMs, onSeekConsumed, sendPlaybackCommand]);

  useEffect(() => {
    applySeek();
  }, [applySeek]);

  useEffect(() => {
    sendPlaybackCommand();
  }, [sendPlaybackCommand]);

  return (
    <iframe
      ref={frameRef}
      title={title}
      src={`https://www.youtube-nocookie.com/embed/${videoId}?enablejsapi=1&playsinline=1&rel=0&autoplay=${initialAutoplay ? 1 : 0}${originParameter}`}
      allow="autoplay; encrypted-media; picture-in-picture"
      loading="lazy"
      tabIndex={expanded ? 0 : -1}
      onLoad={() => { applySeek(); sendPlaybackCommand(); }}
    />
  );
}

function SpotifyEmbed({ trackId, playing, seekMs, onSeekConsumed }: { trackId: string; playing: boolean; seekMs: number | null; onSeekConsumed: () => void }) {
  const mountRef = useRef<HTMLDivElement | null>(null);
  const controllerRef = useRef<SpotifyEmbedController | null>(null);
  const playingRef = useRef(playing);
  const appliedSeekRef = useRef<number | null>(null);
  const setPlaybackState = useResonoteStore((state) => state.setPlaybackState);

  const applySeekTo = useCallback((controller: SpotifyEmbedController) => {
    if (seekMs == null || appliedSeekRef.current === seekMs) return;
    if (typeof controller.seek !== 'function') {
      onSeekConsumed();
      return;
    }
    controller.seek(seekMs / 1000);
    appliedSeekRef.current = seekMs;
    onSeekConsumed();
  }, [seekMs, onSeekConsumed]);

  const applySeekRef = useRef(applySeekTo);

  useEffect(() => {
    applySeekRef.current = applySeekTo;
  }, [applySeekTo]);

  useEffect(() => {
    playingRef.current = playing;
    const controller = controllerRef.current;
    if (!controller) return;
    if (playing) controller.play();
    else controller.pause();
  }, [playing]);

  useEffect(() => {
    if (seekMs != null && controllerRef.current) applySeekTo(controllerRef.current);
  }, [applySeekTo, seekMs]);

  useEffect(() => {
    let cancelled = false;
    const spotifyWindow = window as SpotifyWindow;

    const create = (api: SpotifyIFrameApi) => {
      spotifyWindow.__resonoteSpotifyApi = api;
      if (cancelled || !mountRef.current) return;
      api.createController(
        mountRef.current,
        { width: '100%', height: 176, uri: `spotify:track:${trackId}` },
        (controller) => {
          if (cancelled) {
            controller.destroy();
            return;
          }
          controllerRef.current = controller;
          controller.addListener('playback_update', (event) => {
            if (typeof event.data?.isPaused === 'boolean') setPlaybackState(!event.data.isPaused);
          });
          if (playingRef.current) controller.play();
          applySeekRef.current(controller);
        },
      );
    };

    if (spotifyWindow.__resonoteSpotifyApi) {
      create(spotifyWindow.__resonoteSpotifyApi);
    } else {
      spotifyWindow.onSpotifyIframeApiReady = create;
      if (!document.querySelector('script[data-resonote-spotify-api]')) {
        const script = document.createElement('script');
        script.src = 'https://open.spotify.com/embed/iframe-api/v1';
        script.async = true;
        script.dataset.resonoteSpotifyApi = '';
        document.body.append(script);
      }
    }

    return () => {
      cancelled = true;
      if (spotifyWindow.onSpotifyIframeApiReady === create) {
        delete spotifyWindow.onSpotifyIframeApiReady;
      }
      controllerRef.current?.destroy();
      controllerRef.current = null;
    };
  }, [setPlaybackState, trackId]);

  return <div ref={mountRef} className="spotify-embed" />;
}

export function PersistentPlayer() {
  const player = useResonoteStore((state) => state.player);
  const togglePlayback = useResonoteStore((state) => state.togglePlayback);
  const stopPlayback = useResonoteStore((state) => state.stopPlayback);
  const setExpanded = useResonoteStore((state) => state.setPlayerExpanded);
  const consumePendingSeek = useResonoteStore((state) => state.consumePendingSeek);
  const song = getPlayingSong({ player });

  if (!song) return null;
  const artist = catalog.artists.get(song.artistId);
  const album = getAlbumForSong(song);
  const iframeTitle = `${song.name} playback`;

  // Needle position within the record: where this track sits in the album sequence.
  const albumTracks = album
    ? [...catalog.songs.values()].filter((candidate) => candidate.albumId === album.id).sort((a, b) => (a.trackNumber ?? 99) - (b.trackNumber ?? 99))
    : [song];
  const trackIndex = Math.max(0, albumTracks.findIndex((candidate) => candidate.id === song.id));
  const armAngle = -26 + 44 * (albumTracks.length > 1 ? trackIndex / (albumTracks.length - 1) : 0);
  const labelImage = album?.imageUrl ?? song.imageUrl;

  return (
    <>
      {!player.expanded ? (
        <div className="player-disc-wrap">
          <button
            type="button"
            className={player.playing ? 'player-disc player-disc--spinning' : 'player-disc'}
            onClick={togglePlayback}
            aria-label={`${player.playing ? 'Pause' : 'Play'} ${song.name} by ${artist?.name ?? 'unknown artist'} — track ${trackIndex + 1} of ${albumTracks.length}`}
          >
            <span className="player-disc-face">
              <span className="player-disc-label">
                {labelImage
                  ? <img src={labelImage} alt="" loading="lazy" />
                  : <span className="player-disc-label-fallback">{song.name}</span>}
              </span>
              <span className="player-disc-spindle" />
            </span>
            <span className="player-disc-arm" style={{ transform: `rotate(${armAngle}deg)` }} aria-hidden="true" />
            {!player.playing ? <Play className="player-disc-glyph" size={20} aria-hidden="true" /> : null}
          </button>
          <button type="button" className="player-disc-expand" aria-label="Show player controls" onClick={() => setExpanded(true)}>
            <ChevronUp size={15} />
          </button>
        </div>
      ) : null}

      {/* The embed stays mounted while hidden — collapsing must never stop playback. */}
      <aside
        className={player.expanded ? 'persistent-player' : 'persistent-player persistent-player--hidden'}
        aria-label="Now playing"
        aria-hidden={!player.expanded}
        inert={!player.expanded}
      >
        <div className="player-summary">
          <Artwork entity={song} size="sm" playing={player.playing} record />
          <Link href={hrefForEntity(song)} className="player-copy"><strong>{song.name}</strong><span>{artist?.name}{album ? ` · ${album.name}` : ''}</span></Link>
          <Button variant="ghost" size="icon" onClick={togglePlayback} aria-label={player.playing ? 'Pause' : 'Play'}>{player.playing ? <Pause size={20} /> : <Play size={20} />}</Button>
          <Button variant="ghost" size="icon" onClick={() => setExpanded(false)} aria-label="Hide player controls" tabIndex={player.expanded ? 0 : -1}><ChevronDown size={20} /></Button>
          <Button variant="ghost" size="icon" onClick={stopPlayback} aria-label="Close player" tabIndex={player.expanded ? 0 : -1}><X size={20} /></Button>
        </div>
        <div className="player-embed" inert={!player.expanded ? true : undefined}>
          {song.youtubeId ? (
            <YouTubeEmbed key={song.id} videoId={song.youtubeId} playing={player.playing} expanded={player.expanded} title={iframeTitle} seekMs={player.pendingSeekMs} onSeekConsumed={consumePendingSeek} />
          ) : song.spotifyId ? (
            <SpotifyEmbed key={song.id} trackId={song.spotifyId} playing={player.playing} seekMs={player.pendingSeekMs} onSeekConsumed={consumePendingSeek} />
          ) : null}
        </div>
      </aside>
    </>
  );
}
