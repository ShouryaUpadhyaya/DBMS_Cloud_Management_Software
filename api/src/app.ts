import express, { NextFunction, Request, Response } from 'express';
import { z } from 'zod';
import { atLeast, requireAuth, requireRole, signToken, Role } from './auth.js';
import { appPool, readonlyPool, withUser } from './db.js';
import { config } from './config.js';
import { HttpError, mapPgError } from './errors.js';
import { loadQueries } from './queries.js';
import { procedures, views, ViewDef } from './registry.js';
import { stream } from './stream.js';

type Handler = (req: Request, res: Response) => Promise<unknown>;
const wrap = (fn: Handler) => (req: Request, res: Response, next: NextFunction) => { fn(req, res).catch(next); };

const own = <T extends object>(o: T, k: string): boolean => Object.prototype.hasOwnProperty.call(o, k);
const notFound = (what: string, name: string) => new HttpError(404, `Unknown ${what} "${name}"`, { error: `Unknown ${what} "${name}"` });

function parseOrThrow<T extends z.ZodTypeAny>(schema: T, input: unknown): z.infer<T> {
  const r = schema.safeParse(input);
  if (!r.success) {
    const fields = Object.fromEntries(r.error.issues.map((i) => [i.path.join('.') || '_', i.message]));
    throw new HttpError(400, 'Validation failed', { error: 'Validation failed', fields, issues: r.error.issues });
  }
  return r.data;
}

function buildViewQuery(def: ViewDef, query: Record<string, unknown>): { text: string; values: unknown[] } {
  const shape: Record<string, z.ZodTypeAny> = {
    limit: z.coerce.number().int().min(1).max(def.maxLimit ?? 1000).default(def.defaultLimit ?? 200),
    offset: z.coerce.number().int().min(0).default(0),
  };
  for (const [param, f] of Object.entries(def.filters)) {
    const base = f.type === 'int' ? z.coerce.number().int() : f.type === 'timestamp' ? z.coerce.date() : f.type === 'bool' ? z.enum(['true', 'false']) : z.string().min(1).max(500);
    shape[param] = base.optional();
  }
  const input = parseOrThrow(z.object(shape).strict(), query) as Record<string, unknown>;
  const where: string[] = [];
  const values: unknown[] = [];
  for (const [param, f] of Object.entries(def.filters)) {
    const value = input[param];
    if (value === undefined) continue;
    values.push(f.kind === 'jsonb' ? parseJson(value as string) : value);
    const n = `$${values.length}`;
    switch (f.kind ?? 'eq') {
      case 'eq': where.push(`${f.column} = ${n}`); break;
      case 'gte': where.push(`${f.column} >= ${n}`); break;
      case 'lte': where.push(`${f.column} <= ${n}`); break;
      case 'fts': where.push(`to_tsvector('english', ${f.column}) @@ plainto_tsquery('english', ${n})`); break;
      case 'jsonb': where.push(`${f.column} @> ${n}::jsonb`); break;
    }
  }
  values.push(input.limit, input.offset);
  const text = `SELECT * FROM ${def.from}${where.length ? ` WHERE ${where.join(' AND ')}` : ''} ORDER BY ${def.order} LIMIT $${values.length - 1} OFFSET $${values.length}`;
  return { text, values };
}

function parseJson(raw: string): string {
  try { JSON.parse(raw); return raw; } catch { throw new HttpError(400, 'attrs must be valid JSON', { error: 'attrs must be valid JSON', fields: { attrs: 'must be valid JSON' } }); }
}

export function createApp(): express.Express {
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '100kb' }));

  app.get('/api/health', wrap(async (_req, res) => {
    const r = await appPool.query('SELECT 1 AS ok');
    res.json({ status: 'ok', db: r.rows[0].ok === 1 });
  }));

  // ---- auth: password check happens in the database (pgcrypto crypt) ------------------------
  app.post('/api/auth/login', wrap(async (req, res) => {
    const { email, password } = parseOrThrow(z.object({ email: z.string().email(), password: z.string().min(1).max(200) }), req.body);
    const r = await appPool.query<{ user_id: number; email: string; name: string; role: Role }>('SELECT * FROM sp_login($1, $2)', [email, password]);
    if (r.rowCount === 0) throw new HttpError(401, 'Invalid email or password', { error: 'Invalid email or password' });
    const u = r.rows[0];
    const user = { userId: u.user_id, email: u.email, name: u.name, role: u.role };
    res.json({ token: signToken(user), user });
  }));
  app.get('/api/auth/me', requireAuth, (req, res) => { res.json({ user: req.user }); });

  // ---- read side: views ---------------------------------------------------------------------
  app.get('/api/views', requireAuth, (req, res) => {
    res.json(Object.entries(views)
      .filter(([, d]) => atLeast(req.user!.role, d.minRole))
      .map(([name, d]) => ({ name, minRole: d.minRole, filters: d.kind === 'view' ? Object.keys(d.filters) : Object.keys(d.schema.shape) })));
  });
  app.get('/api/views/:name', requireAuth, wrap(async (req, res) => {
    const name = String(req.params.name);
    if (!own(views, name)) throw notFound('view', name);
    const def = views[name];
    requireRole(def.minRole)(req, res, (e) => { if (e) throw e; });
    if (def.kind === 'view') {
      const q = buildViewQuery(def, req.query as Record<string, unknown>);
      const r = await withUser(req.user!.userId, (c) => c.query(q.text, q.values), { readOnly: true });
      res.json({ name, rows: r.rows, count: r.rowCount });
    } else {
      const input = parseOrThrow(def.schema, req.query);
      const r = await withUser(req.user!.userId, (c) => c.query(def.sql, def.args.map((a) => (input as Record<string, unknown>)[a])), { readOnly: true });
      res.json({ name, rows: r.rows, count: r.rowCount });
    }
  }));

  // ---- write side: stored procedures --------------------------------------------------------
  app.get('/api/procedures', requireAuth, (req, res) => {
    res.json(Object.entries(procedures)
      .filter(([, d]) => atLeast(req.user!.role, d.minRole))
      .map(([name, d]) => ({ name, minRole: d.minRole, args: d.args })));
  });
  app.post('/api/procedures/:name', requireAuth, wrap(async (req, res) => {
    const name = String(req.params.name);
    if (!own(procedures, name)) throw notFound('procedure', name);
    const def = procedures[name];
    requireRole(def.minRole)(req, res, (e) => { if (e) throw e; });
    const input = parseOrThrow(def.schema, req.body ?? {}) as Record<string, unknown>;
    const r = await withUser(req.user!.userId, (c) => c.query(def.sql, def.args.map((a) => input[a])));
    if (def.returns === 'scalar') res.json({ name, result: r.rows[0]?.result ?? null });
    else res.json({ name, rows: r.rows });
  }));

  // ---- DB Lab: named showcase queries with SQL text, rows and EXPLAIN ANALYZE ----------------
  app.get('/api/queries', requireAuth, requireRole('admin'), (_req, res) => {
    res.json([...loadQueries().values()].map(({ name, title, concept }) => ({ name, title, concept })));
  });
  app.get('/api/queries/:name', requireAuth, requireRole('admin'), wrap(async (req, res) => {
    const name = String(req.params.name);
    const q = loadQueries().get(name);
    if (!q) throw notFound('query', name);
    const body = q.sql.replace(/;\s*$/, '');
    const out = await withUser(req.user!.userId, async (c) => {
      const t0 = Date.now();
      const rows = await c.query(body);
      const duration = Date.now() - t0;
      const plan = await c.query(`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${body}`);
      return { rows, duration, plan: plan.rows[0]['QUERY PLAN'] };
    }, { pool: readonlyPool, readOnly: true, timeoutMs: config.queryTimeoutMs });
    res.json({
      name, title: q.title, concept: q.concept, sql: q.sql,
      columns: out.rows.fields.map((f) => f.name), rows: out.rows.rows, row_count: out.rows.rowCount,
      duration_ms: out.duration, plan: out.plan,
    });
  }));

  // ---- alerts as Server-Sent Events -----------------------------------------------------------
  app.get('/api/stream', requireAuth, wrap(async (req, res) => { await stream(req, res); }));

  app.use('/api', (req, _res, next) => next(notFound('route', `${req.method} ${req.path}`)));

  // ---- error mapping ----------------------------------------------------------------------------
  app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
    if (err instanceof HttpError) return void res.status(err.status).json({ error: err.message, ...err.body });
    if ((err as { type?: string }).type === 'entity.parse.failed') return void res.status(400).json({ error: 'Malformed JSON body' });
    const mapped = mapPgError(err as { code?: string; message: string });
    if (mapped) return void res.status(mapped.status).json({ ...mapped.body });
    console.error('unhandled error:', err);
    res.status(500).json({ error: 'Internal server error' });
  });
  return app;
}
