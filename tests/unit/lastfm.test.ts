import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  isValidLastfmToken,
  lastfmAuthUrl,
  lastfmSessionUrl,
  lastfmSignature,
  parseLastfmSession,
  signedLastfmUrl,
} from '@/lib/music/lastfm';

const md5 = (value: string) => createHash('md5').update(value, 'utf8').digest('hex');
const KEY = 'a'.repeat(32);
const SECRET = 's3cr3t';
const TOKEN = 'AbCdEf0123456789AbCdEf0123456789';

describe('Last.fm request signing', () => {
  it('signs auth.getSession as the MD5 of api_key, method, token, then the secret', () => {
    expect(lastfmSignature({ api_key: KEY, method: 'auth.getSession', token: TOKEN }, SECRET))
      .toBe(md5(`api_key${KEY}methodauth.getSessiontoken${TOKEN}${SECRET}`));
  });

  it('sorts parameters by name and leaves out format and callback', () => {
    const signature = lastfmSignature({ user: 'rj', sk: 'session', method: 'user.getrecenttracks', format: 'json', callback: 'cb', api_key: KEY, limit: '10' }, SECRET);
    expect(signature).toBe(md5(`api_key${KEY}limit10methoduser.getrecenttrackssksessionuserrj${SECRET}`));
  });

  it('builds the signed session URL with format=json', () => {
    const url = new URL(lastfmSessionUrl(KEY, SECRET, TOKEN));
    expect(url.origin + url.pathname).toBe('https://ws.audioscrobbler.com/2.0/');
    expect(url.searchParams.get('method')).toBe('auth.getSession');
    expect(url.searchParams.get('token')).toBe(TOKEN);
    expect(url.searchParams.get('format')).toBe('json');
    expect(url.searchParams.get('api_sig')).toBe(md5(`api_key${KEY}methodauth.getSessiontoken${TOKEN}${SECRET}`));
    expect(new URL(signedLastfmUrl({ api_key: KEY, method: 'x' }, SECRET)).searchParams.get('api_sig')).toMatch(/^[0-9a-f]{32}$/);
  });

  it('sends the person to last.fm with the app callback', () => {
    expect(lastfmAuthUrl(KEY)).toBe(`https://www.last.fm/api/auth/?api_key=${KEY}&cb=resonote%3A%2F%2Flastfm-auth`);
  });
});

describe('Last.fm tokens and sessions', () => {
  it('accepts only 32 ASCII letters and digits', () => {
    expect(isValidLastfmToken(TOKEN)).toBe(true);
    expect(isValidLastfmToken(TOKEN.slice(1))).toBe(false);
    expect(isValidLastfmToken(`${TOKEN.slice(1)}-`)).toBe(false);
    expect(isValidLastfmToken(`${TOKEN.slice(1)}é`)).toBe(false);
    expect(isValidLastfmToken(undefined)).toBe(false);
    expect(isValidLastfmToken(42)).toBe(false);
  });

  it('reads a session, and tells a refused token from a failure', () => {
    expect(parseLastfmSession({ session: { name: 'rj', key: 'd580d57f32848f5dcf574d1ce18d78b2', subscriber: 0 } }))
      .toEqual({ kind: 'linked', username: 'rj', sessionKey: 'd580d57f32848f5dcf574d1ce18d78b2' });
    for (const error of [4, 14, 15, '15']) expect(parseLastfmSession({ error, message: 'nope' })).toEqual({ kind: 'rejected' });
    expect(parseLastfmSession({ error: 11, message: 'Service Offline' })).toEqual({ kind: 'failed' });
    expect(parseLastfmSession({ error: 26, message: 'Suspended API key' })).toEqual({ kind: 'failed' });
    expect(parseLastfmSession(null)).toEqual({ kind: 'failed' });
    expect(parseLastfmSession({ session: { name: 'rj' } })).toEqual({ kind: 'failed' });
  });
});
