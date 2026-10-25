// Shared music links → a track description. Parsing and payload mapping are
// pure (unit-tested); the fetchers at the bottom call provider endpoints that
// need no credentials. Odesli's public API now answers 401
// PUBLIC_API_ACCESS_DEPRECATED, so it is used only when ODESLI_API_KEY is set
// and provider metadata (Spotify embed / oEmbed, iTunes lookup, YouTube oEmbed,
// song.link page data) is the default path.

export type LinkPlatform = 'spotify' | 'apple-music' | 'youtube' | 'youtube-music' | 'songlink';

export interface ParsedLink {
  platform: LinkPlatform;
  /** Provider track id: Spotify base62, Apple Music numeric, YouTube video id. */
  id?: string;
  /** Stable form used as the resolution cache key (one per recording link). */
  canonicalUrl: string;
  /** The link to hand back to clients so it opens in the right app. */
  openUrl: string;
  /** Only song.link links: the Odesli page path to read when no short form applies. */
  pagePath?: string;
}

/** Metadata a provider gave us about a shared link, before catalog matching. */
export interface LinkMetadata {
  title: string;
  artist: string;
  album?: string;
  durationMs?: number;
  artworkURL?: string;
  isrc?: string;
  spotifyId?: string;
  appleMusicId?: string;
  youtubeId?: string;
  /**
   * YouTube only: the video is an auto-generated "Artist - Topic" upload (a
   * label release), not something anyone could have uploaded under that title.
   */
  officialAudio?: boolean;
}

const SPOTIFY_ID = /^[A-Za-z0-9]{22}$/;
const YOUTUBE_ID = /^[A-Za-z0-9_-]{11}$/;
const APPLE_ID = /^\d{1,15}$/;

export class UnsupportedLinkError extends Error {}

function spotifyLink(id: string): ParsedLink {
  const url = `https://open.spotify.com/track/${id}`;
  return { platform: 'spotify', id, canonicalUrl: url, openUrl: url };
}

function appleLink(id: string, storefront = 'us'): ParsedLink {
  return { platform: 'apple-music', id, canonicalUrl: `https://music.apple.com/song/${id}`, openUrl: `https://music.apple.com/${storefront}/song/${id}` };
}

function youtubeLink(id: string, music: boolean): ParsedLink {
  return {
    platform: music ? 'youtube-music' : 'youtube',
    id,
    // YouTube and YouTube Music share video ids, so they share one cache key.
    canonicalUrl: `https://www.youtube.com/watch?v=${id}`,
    openUrl: music ? `https://music.youtube.com/watch?v=${id}` : `https://www.youtube.com/watch?v=${id}`,
  };
}

/**
 * Recognizes a song link from Spotify, Apple Music, YouTube / YouTube Music, or
 * song.link. Throws UnsupportedLinkError for anything else, including album,
 * playlist, and artist links (Resonote resolves songs here).
 */
export function parseMusicLink(input: string, depth = 0): ParsedLink {
  const raw = input.trim();
  const spotifyUri = /^spotify:track:([A-Za-z0-9]{22})$/.exec(raw);
  if (spotifyUri) return spotifyLink(spotifyUri[1]);

  let url: URL;
  try {
    url = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(raw) ? raw : `https://${raw}`);
  } catch {
    throw new UnsupportedLinkError('That is not a link.');
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') throw new UnsupportedLinkError('That is not a web link.');
  const host = url.hostname.toLowerCase().replace(/^www\./, '').replace(/^m\./, '');
  const segments = url.pathname.split('/').filter(Boolean);

  if (host === 'open.spotify.com' || host === 'play.spotify.com') {
    // Locale prefixes: /intl-de/track/<id>; embeds: /embed/track/<id>
    const path = segments.filter((segment) => !/^intl-[a-z-]+$/i.test(segment) && segment !== 'embed');
    if (path[0] === 'track' && path[1] && SPOTIFY_ID.test(path[1])) return spotifyLink(path[1]);
    throw new UnsupportedLinkError(path[0] === 'album' ? 'That Spotify link is an album; share a song.' : 'That Spotify link is not a song.');
  }

  if (host === 'music.apple.com' || host === 'geo.music.apple.com' || host === 'itunes.apple.com') {
    const storefront = segments[0] && /^[a-z]{2}$/i.test(segments[0]) ? segments[0].toLowerCase() : 'us';
    const trackParam = url.searchParams.get('i');
    if (trackParam && APPLE_ID.test(trackParam)) return appleLink(trackParam, storefront);
    const songIndex = segments.indexOf('song');
    const last = segments[segments.length - 1] ?? '';
    const id = last.replace(/^id/, '');
    if (songIndex >= 0 && APPLE_ID.test(id)) return appleLink(id, storefront);
    throw new UnsupportedLinkError(segments.includes('album') ? 'That Apple Music link is an album; share a song.' : 'That Apple Music link is not a song.');
  }

  if (host === 'youtube.com' || host === 'music.youtube.com' || host === 'youtu.be' || host === 'youtube-nocookie.com') {
    const music = host === 'music.youtube.com';
    let id: string | null = null;
    if (host === 'youtu.be') id = segments[0] ?? null;
    else if (segments[0] === 'watch') id = url.searchParams.get('v');
    else if (segments[0] === 'shorts' || segments[0] === 'embed' || segments[0] === 'live' || segments[0] === 'v') id = segments[1] ?? null;
    if (id && YOUTUBE_ID.test(id)) return youtubeLink(id, music);
    throw new UnsupportedLinkError('That YouTube link is not a video or song.');
  }

  if (host === 'song.link' || host === 'album.link' || host === 'odesli.co' || host === 'pods.link') {
    if (host === 'album.link') throw new UnsupportedLinkError('album.link links are albums; share a song link.');
    // Short forms: /s/<spotify>, /i/<apple>, /y/<youtube>, optionally after a storefront.
    const path = segments[0] && /^[a-z]{2}$/i.test(segments[0]) && segments.length > 2 ? segments.slice(1) : segments;
    const [kind, id] = path;
    if (kind === 's' && id && SPOTIFY_ID.test(id)) return spotifyLink(id);
    if (kind === 'i' && id && APPLE_ID.test(id)) return appleLink(id);
    if (kind === 'y' && id && YOUTUBE_ID.test(id)) return youtubeLink(id, false);
    // song.link/<url-encoded provider link>
    let embedded: string;
    try {
      embedded = decodeURIComponent(url.pathname.slice(1) + url.search);
    } catch {
      throw new UnsupportedLinkError('That song.link link could not be read.');
    }
    if (depth === 0 && /^(https?:\/\/|spotify:)/i.test(embedded)) return parseMusicLink(embedded, depth + 1);
    if (!segments.length) throw new UnsupportedLinkError('That song.link link has no song.');
    const pagePath = `/${segments.join('/')}`;
    const canonical = `https://song.link${pagePath}`;
    return { platform: 'songlink', canonicalUrl: canonical, openUrl: canonical, pagePath };
  }

  throw new UnsupportedLinkError('Resonote reads Spotify, Apple Music, YouTube Music, YouTube, and song.link links.');
}

// --- Provider payload mapping (pure) ---

function text(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined;
}

function positiveInt(value: unknown): number | undefined {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.round(parsed) : undefined;
}

/** Spotify's embed page ships its track as Next.js page data. */
export function spotifyEmbedMetadata(html: string, id: string): LinkMetadata | null {
  const match = /<script id="__NEXT_DATA__" type="application\/json">([\s\S]*?)<\/script>/.exec(html);
  if (!match) return null;
  try {
    const data = JSON.parse(match[1]) as { props?: { pageProps?: { state?: { data?: { entity?: Record<string, unknown> } } } } };
    const entity = data.props?.pageProps?.state?.data?.entity;
    if (!entity) return null;
    const title = text(entity.name) ?? text(entity.title);
    const artists = (entity.artists as Array<{ name?: unknown }> | undefined) ?? [];
    const artist = artists.map((item) => text(item.name)).filter(Boolean).join(', ');
    if (!title || !artist) return null;
    const images = ((entity.visualIdentity as { image?: Array<{ url?: unknown; maxWidth?: unknown }> } | undefined)?.image ?? [])
      .filter((image) => text(image.url))
      .sort((a, b) => (positiveInt(b.maxWidth) ?? 0) - (positiveInt(a.maxWidth) ?? 0));
    return {
      title,
      artist,
      durationMs: positiveInt(entity.duration),
      artworkURL: text(images[0]?.url),
      spotifyId: id,
    };
  } catch {
    return null;
  }
}

/** oEmbed carries a title and thumbnail; YouTube also names the channel. */
export function oembedMetadata(payload: Record<string, unknown>, platform: 'spotify' | 'youtube', id: string): LinkMetadata | null {
  const rawTitle = text(payload.title);
  if (!rawTitle) return null;
  const thumbnail = text(payload.thumbnail_url);
  if (platform === 'spotify') return { title: rawTitle, artist: '', artworkURL: thumbnail, spotifyId: id };
  const author = text(payload.author_name) ?? '';
  const { title, artist } = splitYouTubeTitle(rawTitle, author);
  return { title, artist, artworkURL: thumbnail, youtubeId: id, officialAudio: /\s+-\s+Topic$/i.test(author) };
}

const VIDEO_NOISE = /\s*[([](official\s+(music\s+)?(video|audio|visualizer|lyric\s+video)|official|music\s+video|lyric(s)?(\s+video)?|audio|visualizer|hd|hq|4k|mv|m\/v)[)\]]/gi;

/**
 * YouTube titles are free text. Auto-generated "Artist - Topic" channels title
 * the video with the song; most others use "Artist - Title (Official Video)".
 */
export function splitYouTubeTitle(rawTitle: string, author: string): { title: string; artist: string } {
  const title = rawTitle.replace(VIDEO_NOISE, '').trim();
  const topic = /^(.*)\s+-\s+Topic$/i.exec(author);
  if (topic) return { title, artist: topic[1].trim() };
  const dash = /^(.+?)\s+[-–—]\s+(.+)$/.exec(title);
  if (dash) return { artist: dash[1].trim(), title: dash[2].replace(/^["“](.*)["”]$/, '$1').trim() };
  const channel = author.replace(/VEVO$/i, '').replace(/\s*official$/i, '').trim();
  return { title, artist: channel };
}

/** iTunes Search API `lookup` result for one Apple Music track. */
export function itunesMetadata(payload: Record<string, unknown>, id: string): LinkMetadata | null {
  const results = (payload.results as Array<Record<string, unknown>> | undefined) ?? [];
  const track = results.find((item) => item.wrapperType === 'track' && String(item.trackId) === id) ?? results.find((item) => item.wrapperType === 'track');
  if (!track) return null;
  const title = text(track.trackName);
  const artist = text(track.artistName);
  if (!title || !artist) return null;
  const artwork = text(track.artworkUrl100)?.replace(/\/\d+x\d+bb\.(jpg|png)$/, '/600x600bb.$1');
  return {
    title,
    artist,
    album: text(track.collectionName),
    durationMs: positiveInt(track.trackTimeMillis),
    artworkURL: artwork,
    appleMusicId: id,
  };
}

/** Provider ids out of a list of cross-platform links. */
export function idsFromLinks(urls: string[]): Pick<LinkMetadata, 'spotifyId' | 'appleMusicId' | 'youtubeId'> {
  const ids: Pick<LinkMetadata, 'spotifyId' | 'appleMusicId' | 'youtubeId'> = {};
  for (const url of urls) {
    try {
      const parsed = parseMusicLink(url, 1);
      if (parsed.platform === 'spotify') ids.spotifyId ??= parsed.id;
      else if (parsed.platform === 'apple-music') ids.appleMusicId ??= parsed.id;
      else if (parsed.platform === 'youtube' || parsed.platform === 'youtube-music') ids.youtubeId ??= parsed.id;
    } catch {
      // Other platforms (Deezer, Tidal, …) carry nothing Resonote stores.
    }
  }
  return ids;
}

/** song.link pages ship their entity and platform links as Next.js page data. */
export function songlinkPageMetadata(html: string): LinkMetadata | null {
  const match = /<script id="__NEXT_DATA__" type="application\/json">([\s\S]*?)<\/script>/.exec(html);
  if (!match) return null;
  try {
    const data = JSON.parse(match[1]) as { props?: { pageProps?: { pageData?: { sections?: Array<Record<string, unknown>> } } } };
    const sections = data.props?.pageProps?.pageData?.sections ?? [];
    const head = sections.find((section) => text(section.title) && text(section.artistName));
    if (!head) return null;
    const links = sections.flatMap((section) => (section.links as Array<{ url?: unknown }> | undefined) ?? []).map((link) => text(link.url)).filter((url): url is string => Boolean(url));
    return { title: text(head.title)!, artist: text(head.artistName)!, artworkURL: text(head.thumbnailUrl), ...idsFromLinks(links) };
  } catch {
    return null;
  }
}

/** Odesli API `links` response (requires ODESLI_API_KEY since the public API closed). */
export function odesliMetadata(payload: Record<string, unknown>): LinkMetadata | null {
  const entities = (payload.entitiesByUniqueId as Record<string, Record<string, unknown>> | undefined) ?? {};
  const primary = entities[String(payload.entityUniqueId ?? '')] ?? Object.values(entities)[0];
  if (!primary) return null;
  const title = text(primary.title);
  const artist = text(primary.artistName);
  if (!title || !artist) return null;
  const links = Object.values((payload.linksByPlatform as Record<string, { url?: unknown }> | undefined) ?? {}).map((link) => text(link.url)).filter((url): url is string => Boolean(url));
  return { title, artist, artworkURL: text(primary.thumbnailUrl), ...idsFromLinks(links) };
}

// --- Fetchers ---

const BROWSER_UA = 'Mozilla/5.0 (compatible; Resonote/0.1; +https://resonote.nmaass.dev)';

async function fetchWithTimeout(url: string, init: RequestInit = {}, timeoutMs = 5000): Promise<Response | null> {
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs), next: { revalidate: 60 * 60 * 24 } } as RequestInit);
  } catch {
    return null;
  }
}

async function fetchJson(url: string, timeoutMs?: number): Promise<Record<string, unknown> | null> {
  const response = await fetchWithTimeout(url, { headers: { Accept: 'application/json' } }, timeoutMs);
  if (!response?.ok) return null;
  return response.json().catch(() => null) as Promise<Record<string, unknown> | null>;
}

async function fetchText(url: string, timeoutMs?: number): Promise<string | null> {
  const response = await fetchWithTimeout(url, { headers: { 'User-Agent': BROWSER_UA, Accept: 'text/html' } }, timeoutMs);
  if (!response?.ok) return null;
  return response.text().catch(() => null);
}

async function odesli(url: string): Promise<LinkMetadata | null> {
  const key = process.env.ODESLI_API_KEY;
  if (!key) return null;
  const payload = await fetchJson(`https://api.song.link/v1-alpha.1/links?url=${encodeURIComponent(url)}&userCountry=US&key=${encodeURIComponent(key)}`);
  return payload ? odesliMetadata(payload) : null;
}

/** Title, artist, and artwork for a parsed link, or null when no provider answered. */
export async function fetchLinkMetadata(link: ParsedLink): Promise<LinkMetadata | null> {
  const viaOdesli = await odesli(link.openUrl);
  if (viaOdesli) return { ...viaOdesli, ...(link.platform === 'spotify' ? { spotifyId: link.id } : {}) };

  if (link.platform === 'spotify' && link.id) {
    const html = await fetchText(`https://open.spotify.com/embed/track/${link.id}`);
    const embedded = html ? spotifyEmbedMetadata(html, link.id) : null;
    if (embedded) return embedded;
    const oembed = await fetchJson(`https://open.spotify.com/oembed?url=${encodeURIComponent(link.canonicalUrl)}`);
    return oembed ? oembedMetadata(oembed, 'spotify', link.id) : null;
  }
  if (link.platform === 'apple-music' && link.id) {
    const payload = await fetchJson(`https://itunes.apple.com/lookup?id=${link.id}&entity=song`);
    return payload ? itunesMetadata(payload, link.id) : null;
  }
  if ((link.platform === 'youtube' || link.platform === 'youtube-music') && link.id) {
    const payload = await fetchJson(`https://www.youtube.com/oembed?url=${encodeURIComponent(`https://www.youtube.com/watch?v=${link.id}`)}&format=json`);
    return payload ? oembedMetadata(payload, 'youtube', link.id) : null;
  }
  if (link.platform === 'songlink' && link.pagePath) {
    const html = await fetchText(`https://song.link${link.pagePath}`);
    return html ? songlinkPageMetadata(html) : null;
  }
  return null;
}
