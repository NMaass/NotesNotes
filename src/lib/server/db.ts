import 'server-only';
import { getCloudflareContext } from '@opennextjs/cloudflare';

export type BoundStatement = {
  first: <T = Record<string, unknown>>() => Promise<T | null>;
  all: <T = Record<string, unknown>>() => Promise<{ results: T[] }>;
  run: () => Promise<{ success: boolean; meta?: { changes?: number } }>;
};

export type Database = {
  prepare: (sql: string) => {
    bind: (...values: unknown[]) => BoundStatement;
  };
  batch: (statements: BoundStatement[]) => Promise<Array<{ results?: unknown[]; meta?: { changes?: number } }>>;
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

/** One SQL statement and its bindings, for `batch`. */
export interface Statement { sql: string; values: unknown[] }

export function sql(text: string, ...values: unknown[]): Statement {
  return { sql: text, values };
}

/**
 * Runs the statements as one D1 batch: they execute in order inside a single
 * transaction, so a multi-row write either lands completely or not at all.
 */
export async function batch(statements: Statement[]): Promise<Array<{ meta?: { changes?: number } }>> {
  if (!statements.length) return [];
  const db = await requireDb();
  return db.batch(statements.map((statement) => db.prepare(statement.sql).bind(...statement.values)));
}

/** Expands `in (...)` placeholders for a list of bindings. */
export function placeholders(values: unknown[]): string {
  return values.map(() => '?').join(',');
}

// D1 caps a single query at 100 bound parameters.
const IN_CHUNK = 90;

/**
 * `select ... where x in (...)` for any number of ids: de-duplicates them and
 * splits the list into D1-sized chunks that run concurrently.
 */
export async function allIn<T = Record<string, unknown>>(build: (list: string) => string, ids: Iterable<string>, ...prefix: unknown[]): Promise<T[]> {
  const unique = [...new Set(ids)].filter(Boolean);
  if (!unique.length) return [];
  const chunks: string[][] = [];
  for (let index = 0; index < unique.length; index += IN_CHUNK) chunks.push(unique.slice(index, index + IN_CHUNK));
  const results = await Promise.all(chunks.map((chunk) => all<T>(build(placeholders(chunk)), ...prefix, ...chunk)));
  return results.flat();
}
