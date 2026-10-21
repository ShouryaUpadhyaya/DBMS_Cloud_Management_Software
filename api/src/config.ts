import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

export const config = {
  port: Number(process.env.PORT ?? 4000),
  databaseUrl: process.env.DATABASE_URL ?? 'postgres://crms_app:crms_app_dev@127.0.0.1:55432/crms',
  readonlyDatabaseUrl: process.env.READONLY_DATABASE_URL ?? 'postgres://crms_readonly:crms_readonly_dev@127.0.0.1:55432/crms',
  jwtSecret: process.env.JWT_SECRET ?? 'dev-only-change-me',
  jwtTtl: process.env.JWT_TTL ?? '12h',
  queriesDir: process.env.QUERIES_DIR ?? path.resolve(here, '../../db/queries'),
  queryTimeoutMs: Number(process.env.QUERY_TIMEOUT_MS ?? 15_000),
};
