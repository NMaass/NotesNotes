// Spotify token refresh (docs/IOS_API.md, "Linked accounts: Spotify"): the real
// migration and queries, run against an in-memory SQLite database standing in for
// D1, with Spotify's token endpoint stubbed.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const d1 = vi.hoisted(() => {
  const state: { db: import('node:sqlite').DatabaseSync | null } = { db: null };
  const statement = (text: string, values: unknown[]) => {
    const prepared = () => state.db!.prepare(text);
    return {
      first: async () => prepared().get(...(values as never[])) ?? null,
      all: async () => ({ results: prepared().all(...(values as never[])) }),
      run: async () => ({ success: true, meta: { changes: Number(prepared().run(...(values as never[])).changes) } }),
    };
  };
  const DB = { prepare: (text: string) => ({ bind: (...values: unknown[]) => statement(text, values) }) };
  return { state, DB };
});

vi.mock('server-only', () => ({}));
vi.mock('@opennextjs/cloudflare', () => ({
  getCloudflareContext: async () => ({ env: { DB: d1.DB, SPOTIFY_CLIENT_ID: 'client-id', SPOTIFY_CLIENT_SECRET: 'client-secret' } }),
}));

const { linkedSpotify, saveLinkedSpotify, spotifyAccessToken } = await import('@/lib/server/spotify');

const ROOT = path.resolve(__dirname, '../..');
const OWNER = 'owner-profile';
const NOW = 1792859270_000;
const MIGRATION = readFileSync(path.join(ROOT, 'd1/migrations/0006_spotify.sql'), 'utf8');

function tokenAnswer(status: number, body: unknown) {
  return vi.fn(async () => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }));
}

async function link(refreshToken: string, accessExpiresInSeconds: number) {
  await saveLinkedSpotify(OWNER, { id: 'wizzler', displayName: 'Wiz', product: 'premium' }, {
    accessToken: 'at-1', expiresIn: accessExpiresInSeconds, refreshToken, scope: 'user-read-recently-played',
  });
  return (await linkedSpotify(OWNER))!;
}

/** Another request's successful refresh: the row now holds its tokens. */
async function rotate(refreshToken: string, accessToken: string, expiresInSeconds: number) {
  d1.state.db!.prepare('update spotify_accounts set refresh_token = ?, access_token = ?, access_expires_at = ? where profile_id = ?')
    .run(refreshToken, accessToken, new Date(Date.now() + expiresInSeconds * 1000).toISOString(), OWNER);
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(NOW);
  d1.state.db = new DatabaseSync(':memory:');
  d1.state.db.exec('create table profiles (id text primary key)');
  d1.state.db.exec(MIGRATION);
  d1.state.db.exec(MIGRATION); // idempotent
  d1.state.db.prepare('insert into profiles (id) values (?)').run(OWNER);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe('spotifyAccessToken', () => {
  it('uses a fresh access token without calling Spotify', async () => {
    const fetchMock = tokenAnswer(500, {});
    vi.stubGlobal('fetch', fetchMock);
    const linked = await link('rt-1', 3600);
    expect(await spotifyAccessToken(OWNER, linked)).toEqual({ kind: 'ok', accessToken: 'at-1' });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('refreshes with Basic auth and stores a rotated refresh token', async () => {
    const fetchMock = tokenAnswer(200, { access_token: 'at-2', expires_in: 3600, refresh_token: 'rt-2' });
    vi.stubGlobal('fetch', fetchMock);
    const linked = await link('rt-1', 30);
    expect(await spotifyAccessToken(OWNER, linked, NOW)).toEqual({ kind: 'ok', accessToken: 'at-2' });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://accounts.spotify.com/api/token');
    expect((init.headers as Record<string, string>).Authorization).toBe(`Basic ${Buffer.from('client-id:client-secret').toString('base64')}`);
    expect(init.body).toBe('grant_type=refresh_token&refresh_token=rt-1');
    expect(init.cache).toBe('no-store');
    expect(init.signal).toBeInstanceOf(AbortSignal);
    expect(await linkedSpotify(OWNER)).toMatchObject({ accessToken: 'at-2', refreshToken: 'rt-2', accessExpiresAt: new Date(NOW + 3_600_000).toISOString() });
  });

  it('keeps the refresh token when Spotify does not rotate it', async () => {
    vi.stubGlobal('fetch', tokenAnswer(200, { access_token: 'at-2', expires_in: 3600 }));
    const linked = await link('rt-1', 0);
    await spotifyAccessToken(OWNER, linked, NOW);
    expect(await linkedSpotify(OWNER)).toMatchObject({ accessToken: 'at-2', refreshToken: 'rt-1' });
  });

  it('drops the link when Spotify refuses the refresh token', async () => {
    vi.stubGlobal('fetch', tokenAnswer(400, { error: 'invalid_grant', error_description: 'Refresh token revoked' }));
    const linked = await link('rt-1', 0);
    expect(await spotifyAccessToken(OWNER, linked, NOW, { settleMs: 0 })).toEqual({ kind: 'revoked' });
    expect(await linkedSpotify(OWNER)).toBeNull();
  });

  it('uses a concurrent rotation that already landed instead of dropping the link', async () => {
    const fetchMock = tokenAnswer(400, { error: 'invalid_grant' });
    vi.stubGlobal('fetch', fetchMock);
    const stale = await link('rt-1', 0);
    await rotate('rt-2', 'at-2', 3600); // request A rotated rt-1 before B's refresh reached Spotify
    expect(await spotifyAccessToken(OWNER, stale, NOW, { settleMs: 0 })).toEqual({ kind: 'ok', accessToken: 'at-2' });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(await linkedSpotify(OWNER)).toMatchObject({ refreshToken: 'rt-2', accessToken: 'at-2' });
  });

  it('waits for a concurrent rotation whose write lands after the refusal', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => {
      // Request A's update commits shortly after Spotify refuses B's (now rotated) token.
      setTimeout(() => void rotate('rt-2', 'at-2', 3600), 5);
      return new Response(JSON.stringify({ error: 'invalid_grant' }), { status: 400 });
    }));
    const stale = await link('rt-1', 0);
    expect(await spotifyAccessToken(OWNER, stale, NOW, { settleMs: 30 })).toEqual({ kind: 'ok', accessToken: 'at-2' });
    expect(await linkedSpotify(OWNER)).toMatchObject({ refreshToken: 'rt-2' });
  });

  it('retries once with a rotated refresh token whose access token is stale', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: 'invalid_grant' }), { status: 400 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ access_token: 'at-3', expires_in: 3600, refresh_token: 'rt-3' }), { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    const stale = await link('rt-1', 0);
    await rotate('rt-2', 'at-2', 0);
    expect(await spotifyAccessToken(OWNER, stale, NOW, { settleMs: 0 })).toEqual({ kind: 'ok', accessToken: 'at-3' });
    expect((fetchMock.mock.calls[1] as unknown as [string, RequestInit])[1].body).toBe('grant_type=refresh_token&refresh_token=rt-2');
    expect(await linkedSpotify(OWNER)).toMatchObject({ refreshToken: 'rt-3', accessToken: 'at-3' });
  });

  it('treats any other failure as temporary and keeps the link', async () => {
    vi.stubGlobal('fetch', tokenAnswer(503, { error: 'server_error' }));
    const linked = await link('rt-1', 0);
    expect(await spotifyAccessToken(OWNER, linked, NOW)).toEqual({ kind: 'failed' });
    expect(await linkedSpotify(OWNER)).toMatchObject({ refreshToken: 'rt-1' });
  });

  it('reads "no such table" as not linked', async () => {
    d1.state.db = new DatabaseSync(':memory:');
    expect(await linkedSpotify(OWNER)).toBeNull();
  });
});
