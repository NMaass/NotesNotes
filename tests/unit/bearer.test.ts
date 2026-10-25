import { describe, expect, it } from 'vitest';
import { hasBearerScheme, parseBearer } from '@/lib/server/bearer';

describe('bearer header parsing', () => {
  const token = 'a'.repeat(64);
  it('reads a bearer token case-insensitively', () => {
    expect(parseBearer(`Bearer ${token}`)).toBe(token);
    expect(parseBearer(`bearer   ${token}  `)).toBe(token);
  });
  it('rejects other schemes, empty, and malformed tokens', () => {
    expect(parseBearer(null)).toBeNull();
    expect(parseBearer('')).toBeNull();
    expect(parseBearer(`Basic ${token}`)).toBeNull();
    expect(parseBearer('Bearer')).toBeNull();
    expect(parseBearer('Bearer two tokens')).toBeNull();
    expect(parseBearer('Bearer ünïcode')).toBeNull();
    expect(parseBearer(`Bearer ${'a'.repeat(600)}`)).toBeNull();
  });
  it('notices a bearer scheme even when its token is unusable', () => {
    expect(hasBearerScheme('Bearer')).toBe(true);
    expect(hasBearerScheme('Bearer ünïcode')).toBe(true);
    expect(hasBearerScheme('Basic abc')).toBe(false);
    expect(hasBearerScheme(null)).toBe(false);
  });
});
