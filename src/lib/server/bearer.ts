// Pure helpers for `Authorization: Bearer <token>` (RFC 6750). Kept free of
// `server-only` so unit tests can import them directly.

const B64_TOKEN = /^[A-Za-z0-9\-._~+/]+=*$/;
const MAX_TOKEN_LENGTH = 512;

/**
 * Returns the token from an Authorization header value, or null when the header
 * is absent, uses another scheme, or carries a malformed token.
 */
export function parseBearer(header: string | null | undefined): string | null {
  if (!header) return null;
  const match = /^\s*bearer\s+(\S+)\s*$/i.exec(header);
  if (!match) return null;
  const token = match[1];
  if (token.length > MAX_TOKEN_LENGTH || !B64_TOKEN.test(token)) return null;
  return token;
}

/** Whether the request presented any bearer credential at all (valid or not). */
export function hasBearerScheme(header: string | null | undefined): boolean {
  return Boolean(header && /^\s*bearer(\s|$)/i.test(header));
}
