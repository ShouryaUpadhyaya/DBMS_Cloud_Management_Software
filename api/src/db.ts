import pg from 'pg';
import { config } from './config.js';

// bigint (count(*)) as number; dates stay strings (no timezone surprises in JSON)
pg.types.setTypeParser(20, (v) => Number(v));
pg.types.setTypeParser(1082, (v) => v);

export const appPool = new pg.Pool({ connectionString: config.databaseUrl, max: 10 });
export const readonlyPool = new pg.Pool({ connectionString: config.readonlyDatabaseUrl, max: 4 });

export interface TxOptions {
  pool?: pg.Pool;
  readOnly?: boolean;
  timeoutMs?: number;
}

export const MAX_ATTEMPTS = 3;

/** Serialization failures (40001) and deadlocks (40P01) are retried; anything else propagates. */
export async function retrying<T>(fn: () => Promise<T>, attempts = MAX_ATTEMPTS): Promise<T> {
  let last: unknown;
  for (let i = 1; i <= attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      last = err;
      const code = (err as { code?: string }).code;
      if ((code === '40001' || code === '40P01') && i < attempts) continue;
      throw err;
    }
  }
  throw last;
}

/**
 * Every request runs as:  BEGIN; SET LOCAL crms.user_id = $id; ...; COMMIT.
 * set_config(..., true) is the parameterisable form of SET LOCAL.
 */
export async function withUser<T>(userId: number | null, fn: (c: pg.PoolClient) => Promise<T>, opts: TxOptions = {}): Promise<T> {
  const pool = opts.pool ?? appPool;
  return retrying(async () => {
    const client = await pool.connect();
    try {
      await client.query(opts.readOnly ? 'BEGIN READ ONLY' : 'BEGIN');
      await client.query("SELECT set_config('crms.user_id', $1, true)", [userId === null ? '' : String(userId)]);
      if (opts.timeoutMs) await client.query(`SET LOCAL statement_timeout = ${Math.floor(opts.timeoutMs)}`);
      const result = await fn(client);
      await client.query('COMMIT');
      return result;
    } catch (err) {
      try { await client.query('ROLLBACK'); } catch { /* connection already gone */ }
      throw err;
    } finally {
      client.release();
    }
  });
}

export async function closePools(): Promise<void> {
  await Promise.all([appPool.end(), readonlyPool.end()]);
}
