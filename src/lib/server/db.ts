import 'server-only';
import { getCloudflareContext } from '@opennextjs/cloudflare';

export type Database = {
  prepare: (sql: string) => {
    bind: (...values: unknown[]) => {
      first: <T = Record<string, unknown>>() => Promise<T | null>;
      all: <T = Record<string, unknown>>() => Promise<{ results: T[] }>;
      run: () => Promise<{ success: boolean; meta?: { changes?: number } }>;
    };
  };
  batch: (statements: unknown[]) => Promise<unknown>;
};

let cached: Database | null | undefined;

export async function getDb(): Promise<Database | null> {
  if (cached !== undefined) return cached;
  try {
    const { env } = await getCloudflareContext({ async: true });
    const db = (env as Record<string, unknown>).DB as Database | undefined;
    cached = db ?? null;
  } catch {
    cached = null;
  }
  return cached;
}

export async function requireDb(): Promise<Database> {
  const db = await getDb();
  if (!db) throw new Error('The D1 database binding is not available in this environment.');
  return db;
}

export async function all<T = Record<string, unknown>>(sql: string, ...values: unknown[]): Promise<T[]> {
  const db = await requireDb();
  const result = await db.prepare(sql).bind(...values).all<T>();
  return result.results ?? [];
}

export async function first<T = Record<string, unknown>>(sql: string, ...values: unknown[]): Promise<T | null> {
  const db = await requireDb();
  return db.prepare(sql).bind(...values).first<T>();
}

export async function run(sql: string, ...values: unknown[]): Promise<void> {
  const db = await requireDb();
  await db.prepare(sql).bind(...values).run();
}
