import 'server-only';
import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { cookies, headers } from 'next/headers';
import { hasBearerScheme, parseBearer } from '@/lib/server/bearer';
import { batch, first, run, sql } from '@/lib/server/db';

export const SESSION_COOKIE = 'resonote_session';
const SESSION_TTL_DAYS = 30;
const OTP_TTL_MINUTES = 10;
const MAX_ACTIVE_CODES_PER_EMAIL = 5;
/** Wrong codes allowed per email within FAILURE_WINDOW_MINUTES before every code is locked. */
const MAX_FAILED_ATTEMPTS = 5;
const FAILURE_WINDOW_MINUTES = 10;

function sha256(value: string): string {
  return createHash('sha256').update(value).digest('hex');
}

function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

export function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizeEmail(email));
}

function isoAt(offsetMs: number): string {
  return new Date(Date.now() + offsetMs).toISOString();
}

/**
 * Issues a six-digit code for the email. When no mail provider is configured the
 * raw code is returned so local development can complete sign-in without email.
 */
function mailConfigured(): boolean {
  return Boolean(process.env.RESEND_API_KEY && process.env.AUTH_EMAIL_FROM);
}

async function sendLoginEmail(to: string, code: string): Promise<void> {
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${process.env.RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: process.env.AUTH_EMAIL_FROM,
      to,
      subject: `Your Resonote sign-in code: ${code}`,
      text: [
        `Your Resonote sign-in code is ${code}.`,
        `It expires in ${OTP_TTL_MINUTES} minutes and can be used once.`,
        '',
        "If you did not request this code, you can ignore this email — your account stays untouched.",
      ].join('\n'),
    }),
  });
  if (!response.ok) {
    const detail = (await response.text().catch(() => '')).slice(0, 160);
    throw new Error(`The sign-in email could not be sent (${response.status}). ${detail}`);
  }
}

export async function issueLoginCode(email: string): Promise<{ devCode?: string }> {
  const normalized = normalizeEmail(email);

  const active = await first<{ n: number }>(
    'select count(*) as n from otp_codes where email = ? and consumed = 0 and expires_at > ?',
    normalized, new Date().toISOString(),
  );
  if ((active?.n ?? 0) >= MAX_ACTIVE_CODES_PER_EMAIL) throw new Error('Too many codes requested. Try again in a few minutes.');

  const code = String(Math.floor(100000 + Math.random() * 900000));
  await run(
    'insert into otp_codes (id, email, code_hash, expires_at) values (?, ?, ?, ?)',
    randomUUID(), normalized, sha256(`${normalized}:${code}`), isoAt(OTP_TTL_MINUTES * 60_000),
  );

  // No provider configured: surface the code to the requester (local development only).
  if (!mailConfigured()) return { devCode: code };
  await sendLoginEmail(normalized, code);
  return {};
}

export type CodeCheck = 'ok' | 'wrong' | 'locked';

/**
 * Checks a sign-in code. Wrong guesses are counted per email: after
 * MAX_FAILED_ATTEMPTS within FAILURE_WINDOW_MINUTES every outstanding code for
 * that email is spent and further attempts answer 'locked' until the window
 * passes, so the six-digit space cannot be walked within a code's lifetime.
 * Requesting a new code does not reset the count; a correct code does.
 */
export async function consumeLoginCode(email: string, code: string): Promise<CodeCheck> {
  const normalized = normalizeEmail(email);
  const trimmed = code.trim();
  const windowStart = isoAt(-FAILURE_WINDOW_MINUTES * 60_000);
  const failures = await first<{ n: number }>(
    'select count(*) as n from login_failures where email = ? and created_at > ?',
    normalized, windowStart,
  );
  if ((failures?.n ?? 0) >= MAX_FAILED_ATTEMPTS) return 'locked';

  const row = await first<{ code_hash: string; expires_at: string }>(
    'select code_hash, expires_at from otp_codes where email = ? and consumed = 0 order by created_at desc limit 1',
    normalized,
  );
  const provided = Buffer.from(sha256(`${normalized}:${trimmed}`));
  const stored = Buffer.from(row?.code_hash ?? '');
  const matches = Boolean(row) && new Date(row!.expires_at).getTime() >= Date.now()
    && provided.length === stored.length && timingSafeEqual(provided, stored);
  if (!matches) {
    await run('insert into login_failures (id, email, created_at) values (?, ?, ?)', randomUUID(), normalized, new Date().toISOString());
    if ((failures?.n ?? 0) + 1 >= MAX_FAILED_ATTEMPTS) {
      await run('update otp_codes set consumed = 1 where email = ? and consumed = 0', normalized);
      return 'locked';
    }
    return 'wrong';
  }
  await batch([
    sql('update otp_codes set consumed = 1 where code_hash = ?', row!.code_hash),
    sql('delete from login_failures where email = ? or created_at < ?', normalized, windowStart),
  ]);
  return 'ok';
}

async function ensureUserAndProfile(email: string): Promise<{ userId: string; handle: string }> {
  const normalized = normalizeEmail(email);
  let user = await first<{ id: string }>('select id from users where email = ?', normalized);
  if (!user) {
    const userId = randomUUID();
    await run('insert into users (id, email) values (?, ?)', userId, normalized);
    user = { id: userId };
  }
  let profile = await first<{ handle: string }>('select handle from profiles where id = ?', user.id);
  if (!profile) {
    const base = slugifyHandle(normalized.split('@')[0] ?? 'listener') || 'listener';
    let handle = base;
    for (let attempt = 2; await first('select id from profiles where handle = ?', handle); attempt += 1) {
      handle = `${base}${attempt}`;
    }
    await run('insert into profiles (id, handle, display_name) values (?, ?, ?)', user.id, handle, base);
    profile = { handle };
  }
  return { userId: user.id, handle: profile.handle };
}

function slugifyHandle(value: string): string {
  return value.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 24);
}

export interface StartedSession {
  userId: string;
  handle: string;
  /** Present only for native sessions: the bearer token, shown exactly once. */
  token?: string;
  expiresAt: string;
}

/**
 * Creates a session row. Web sessions travel in an httpOnly cookie; native
 * sessions (`mode: 'native'`) return the token to the caller instead and never
 * set a cookie. Both are the same `sessions` rows, so expiry and sign-out match.
 */
export async function startSession(email: string, mode: 'cookie' | 'native' = 'cookie'): Promise<StartedSession> {
  const { userId, handle } = await ensureUserAndProfile(email);
  const token = randomBytes(32).toString('hex');
  const expiresAt = isoAt(SESSION_TTL_DAYS * 86_400_000);
  await run('insert into sessions (id, user_id, expires_at) values (?, ?, ?)', sha256(token), userId, expiresAt);
  if (mode === 'native') return { userId, handle, token, expiresAt };
  const jar = await cookies();
  jar.set(SESSION_COOKIE, token, {
    httpOnly: true,
    sameSite: 'lax',
    secure: process.env.NODE_ENV === 'production',
    path: '/',
    maxAge: SESSION_TTL_DAYS * 86_400,
  });
  return { userId, handle, expiresAt };
}

/**
 * The credential this request carries. A request that presents a bearer header
 * is judged on that token alone (an invalid one is not rescued by a cookie);
 * otherwise the session cookie is used.
 */
async function requestToken(): Promise<{ token: string | null; kind: 'bearer' | 'cookie' }> {
  const authorization = (await headers()).get('authorization');
  if (hasBearerScheme(authorization)) return { token: parseBearer(authorization), kind: 'bearer' };
  const jar = await cookies();
  return { token: jar.get(SESSION_COOKIE)?.value ?? null, kind: 'cookie' };
}

export async function currentUser(): Promise<string | null> {
  const { token } = await requestToken();
  if (!token) return null;
  const session = await first<{ user_id: string; expires_at: string }>(
    'select user_id, expires_at from sessions where id = ?',
    sha256(token),
  );
  if (!session) return null;
  if (new Date(session.expires_at).getTime() < Date.now()) {
    await run('delete from sessions where id = ?', sha256(token));
    return null;
  }
  return session.user_id;
}

export async function endSession(): Promise<void> {
  const { token, kind } = await requestToken();
  if (token) await run('delete from sessions where id = ?', sha256(token));
  if (kind === 'cookie') (await cookies()).delete(SESSION_COOKIE);
}
