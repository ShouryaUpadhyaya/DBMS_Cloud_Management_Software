import pg from 'pg';
import request from 'supertest';
import { createApp } from '../src/app.js';

export const app = createApp();

export const adminDb = new pg.Pool({
  connectionString: process.env.ADMIN_DATABASE_URL ?? 'postgres://postgres:crms_pg_dev@127.0.0.1:55432/crms',
  max: 2,
});

const tokens = new Map<string, string>();

/** Logs in through the real endpoint (sp_login + pgcrypto) and caches the JWT. */
export async function token(email: string): Promise<string> {
  const cached = tokens.get(email);
  if (cached) return cached;
  const res = await request(app).post('/api/auth/login').send({ email, password: 'password123' });
  if (res.status !== 200) throw new Error(`login failed for ${email}: ${res.status} ${JSON.stringify(res.body)}`);
  tokens.set(email, res.body.token);
  return res.body.token;
}

export const as = async (email: string) => ({ Authorization: `Bearer ${await token(email)}` });

export async function projectId(name: string): Promise<number> {
  const r = await adminDb.query('SELECT project_id FROM projects WHERE name = $1', [name]);
  return r.rows[0].project_id;
}
