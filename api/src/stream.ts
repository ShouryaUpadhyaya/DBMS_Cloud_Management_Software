import type { Request, Response } from 'express';
import pg from 'pg';
import { config } from './config.js';
import { withUser } from './db.js';
import type { AuthUser } from './auth.js';

interface Subscriber {
  res: Response;
  user: AuthUser;
  projects: Set<number>;
}

const subscribers = new Set<Subscriber>();
let listener: pg.Client | null = null;
let closing = false;

async function refreshProjects(s: Subscriber): Promise<void> {
  const rows = await withUser(s.user.userId, (c) => c.query<{ project_id: number }>('SELECT project_id FROM v_projects'), { readOnly: true });
  s.projects = new Set(rows.rows.map((r) => r.project_id));
}

async function startListener(): Promise<void> {
  if (listener || closing) return;
  const client = new pg.Client({ connectionString: config.databaseUrl });
  client.on('notification', (msg) => {
    if (msg.channel !== 'alerts' || !msg.payload) return;
    let payload: { project_id?: number };
    try { payload = JSON.parse(msg.payload); } catch { return; }
    for (const s of subscribers) {
      // Only deliver alerts for projects this user can see (the same rule RLS applies to reads).
      if (payload.project_id !== undefined && !s.projects.has(payload.project_id)) continue;
      s.res.write(`event: alert\ndata: ${msg.payload}\n\n`);
    }
  });
  const restart = () => {
    listener = null;
    if (!closing && subscribers.size > 0) setTimeout(() => void startListener().catch(() => undefined), 2000);
  };
  client.on('error', restart);
  client.on('end', restart);
  await client.connect();
  await client.query('LISTEN alerts');
  listener = client;
}

/** GET /api/stream: Server-Sent Events fed by LISTEN alerts (trg_metric_alert -> pg_notify). */
export async function stream(req: Request, res: Response): Promise<void> {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  const sub: Subscriber = { res, user: req.user!, projects: new Set() };
  await refreshProjects(sub);
  subscribers.add(sub);
  await startListener();
  res.write(`event: hello\ndata: ${JSON.stringify({ user: sub.user.email, projects: [...sub.projects] })}\n\n`);
  const beat = setInterval(() => res.write(': keep-alive\n\n'), 25_000);
  const refresh = setInterval(() => void refreshProjects(sub).catch(() => undefined), 60_000);
  req.on('close', () => {
    clearInterval(beat);
    clearInterval(refresh);
    subscribers.delete(sub);
    if (subscribers.size === 0 && listener) {
      const l = listener;
      listener = null;
      void l.end().catch(() => undefined);
    }
  });
}

export async function closeStream(): Promise<void> {
  closing = true;
  for (const s of subscribers) s.res.end();
  subscribers.clear();
  if (listener) await listener.end().catch(() => undefined);
  listener = null;
}
