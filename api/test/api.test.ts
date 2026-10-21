import http from 'node:http';
import { AddressInfo } from 'node:net';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { closePools } from '../src/db.js';
import { closeStream } from '../src/stream.js';
import { adminDb, app, as, projectId, token } from './helpers.js';

afterAll(async () => {
  await adminDb.query("DELETE FROM resources WHERE name LIKE 'apitest-%'");
  await closeStream();
  await closePools();
  await adminDb.end();
});

describe('auth', () => {
  it('logs in with a seeded user and returns a JWT with the top role', async () => {
    const res = await request(app).post('/api/auth/login').send({ email: 'alice@crms.test', password: 'password123' });
    expect(res.status).toBe(200);
    expect(res.body.user).toMatchObject({ email: 'alice@crms.test', role: 'manager' });
    expect(res.body.token.split('.')).toHaveLength(3);
    const me = await request(app).get('/api/auth/me').set('Authorization', `Bearer ${res.body.token}`);
    expect(me.body.user.name).toBe('Alice Rivera');
  });

  it('rejects wrong passwords, unknown users and suspended users with 401', async () => {
    for (const [email, password] of [['alice@crms.test', 'nope'], ['ghost@crms.test', 'password123'], ['erin@crms.test', 'password123']]) {
      const res = await request(app).post('/api/auth/login').send({ email, password });
      expect(res.status).toBe(401);
    }
  });

  it('validates the login body with zod (400)', async () => {
    const res = await request(app).post('/api/auth/login').send({ email: 'not-an-email' });
    expect(res.status).toBe(400);
    expect(res.body.fields).toHaveProperty('email');
  });

  it('requires a token for the data endpoints (401) and rejects a forged one', async () => {
    expect((await request(app).get('/api/views/v_projects')).status).toBe(401);
    expect((await request(app).get('/api/views/v_projects').set('Authorization', 'Bearer abc.def.ghi')).status).toBe(401);
  });
});

describe('views', () => {
  it('returns rows for a view, filtered and limited', async () => {
    const res = await request(app).get('/api/views/v_active_resources?type=compute&limit=3').set(await as('admin@crms.test'));
    expect(res.status).toBe(200);
    expect(res.body.rows).toHaveLength(3);
    expect(res.body.rows.every((r: { type: string }) => r.type === 'compute')).toBe(true);
  });

  it('applies row-level security per user: carol sees only Web Platform, admin sees all', async () => {
    const carol = await request(app).get('/api/views/v_active_resources?limit=1000').set(await as('carol@crms.test'));
    expect(new Set(carol.body.rows.map((r: { project_name: string }) => r.project_name))).toEqual(new Set(['Web Platform']));
    const dave = await request(app).get('/api/views/v_active_resources?limit=1000').set(await as('dave@crms.test'));
    expect(new Set(dave.body.rows.map((r: { project_name: string }) => r.project_name))).toEqual(new Set(['Data Lab']));
    const admin = await request(app).get('/api/views/v_active_resources?limit=1000').set(await as('admin@crms.test'));
    expect(new Set(admin.body.rows.map((r: { project_name: string }) => r.project_name)).size).toBeGreaterThanOrEqual(3);
  });

  it('isolates invoices and logs too', async () => {
    const inv = await request(app).get('/api/views/v_invoices').set(await as('dave@crms.test'));
    expect(inv.body.rows.length).toBeGreaterThan(0);
    expect(inv.body.rows.every((r: { project_name: string }) => r.project_name === 'Data Lab')).toBe(true);
    const logs = await request(app).get('/api/views/v_logs?level=error&limit=50').set(await as('carol@crms.test'));
    expect(logs.body.rows.length).toBeGreaterThan(0);
    expect(logs.body.rows.every((r: { level: string }) => r.level === 'error')).toBe(true);
  });

  it('supports full-text and jsonb log filters', async () => {
    const fts = await request(app).get('/api/views/v_logs?q=redis&limit=5').set(await as('admin@crms.test'));
    expect(fts.body.rows.length).toBeGreaterThan(0);
    expect(fts.body.rows.every((r: { message: string }) => /redis/i.test(r.message))).toBe(true);
    const js = await request(app).get('/api/views/v_logs').query({ attrs: '{"status":500}', limit: 5 }).set(await as('admin@crms.test'));
    expect(js.body.rows.every((r: { attrs: { status: number } }) => r.attrs.status === 500)).toBe(true);
    const bad = await request(app).get('/api/views/v_logs').query({ attrs: '{oops' }).set(await as('admin@crms.test'));
    expect(bad.status).toBe(400);
  });

  it('serves the parameterised metric series and latest metrics', async () => {
    const r = (await adminDb.query("SELECT resource_id FROM resources WHERE name = 'web-1'")).rows[0].resource_id;
    const series = await request(app).get(`/api/views/metric_series?resource_id=${r}&metric=cpu_percent&bucket=600`).set(await as('carol@crms.test'));
    expect(series.status).toBe(200);
    expect(series.body.rows.length).toBeGreaterThan(100);
    expect(series.body.rows[0]).toHaveProperty('avg_value');
    const hidden = (await adminDb.query("SELECT resource_id FROM resources WHERE name = 'etl-1'")).rows[0].resource_id;
    const other = await request(app).get(`/api/views/metric_series?resource_id=${hidden}&metric=cpu_percent`).set(await as('carol@crms.test'));
    expect(other.body.rows).toHaveLength(0);            // RLS: metrics of another project are invisible
    const bad = await request(app).get(`/api/views/metric_series?resource_id=${r}&metric=bogus`).set(await as('carol@crms.test'));
    expect(bad.status).toBe(400);
  });

  it('404 for unknown views, 400 for unknown or invalid parameters, 403 for role-gated views', async () => {
    const h = await as('carol@crms.test');
    expect((await request(app).get('/api/views/pg_shadow').set(h)).status).toBe(404);
    expect((await request(app).get('/api/views/constructor').set(h)).status).toBe(404);
    expect((await request(app).get('/api/views/v_projects?bogus=1').set(h)).status).toBe(400);
    expect((await request(app).get('/api/views/v_projects?limit=-5').set(h)).status).toBe(400);
    expect((await request(app).get('/api/views/v_stat_statements').set(h)).status).toBe(403);
    expect((await request(app).get('/api/views/v_stat_statements').set(await as('admin@crms.test'))).status).toBe(200);
  });

  it('resists SQL injection through filter values (parameterised)', async () => {
    const res = await request(app).get('/api/views/v_active_resources').query({ type: "compute' OR '1'='1" }).set(await as('admin@crms.test'));
    expect(res.status).toBe(200);
    expect(res.body.rows).toHaveLength(0);
  });

  it('audit log: admin sees everything, carol only her own actions', async () => {
    const admin = await request(app).get('/api/views/v_audit_log?limit=5').set(await as('admin@crms.test'));
    expect(admin.body.rows.length).toBe(5);
    const carol = await request(app).get('/api/views/v_audit_log').set(await as('carol@crms.test'));
    expect(carol.body.rows).toHaveLength(0);
  });
});

describe('procedures', () => {
  it('provisions and terminates a volume as a manager; the audit trail records the actor', async () => {
    const wp = await projectId('Web Platform');
    const h = await as('alice@crms.test');
    const created = await request(app).post('/api/procedures/sp_create_volume').set(h).send({ project_id: wp, name: 'apitest-vol', size_gb: 5 });
    expect(created.status).toBe(200);
    const rid = created.body.result;
    const view = await request(app).get(`/api/views/v_active_resources?resource_id=${rid}`).set(h);
    expect(view.body.rows[0]).toMatchObject({ name: 'apitest-vol', size_gb: 5, state: 'running' });
    const audit = await request(app).get('/api/views/v_audit_log?table_name=resources&limit=1').set(h);
    expect(audit.body.rows[0].actor_name).toBe('Alice Rivera');
    const term = await request(app).post('/api/procedures/sp_terminate_resource').set(h).send({ resource_id: rid });
    expect(term.status).toBe(200);
    const again = await request(app).post('/api/procedures/sp_terminate_resource').set(h).send({ resource_id: rid });
    expect(again.status).toBe(400);
    expect(again.body.error).toMatch(/already terminated/);
  });

  it('maps RAISE EXCEPTION (P0001) to 400 with the message unchanged', async () => {
    const wp = await projectId('Web Platform');
    const net = (await adminDb.query("SELECT resource_id FROM resources WHERE name = 'web-net'")).rows[0].resource_id;
    const res = await request(app).post('/api/procedures/sp_provision_vm').set(await as('alice@crms.test'))
      .send({ project_id: wp, name: 'apitest-vm', vcpus: 1, memory_mb: 512, network_id: net });
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Quota exceeded: 6 of 6 VMs used');
  });

  it('maps unique violations (23505) to 409 with a field error', async () => {
    const wp = await projectId('Web Platform');
    const h = await as('alice@crms.test');
    const res = await request(app).post('/api/procedures/sp_create_volume').set(h).send({ project_id: wp, name: 'pgdata', size_gb: 1 });
    expect(res.status).toBe(409);
    expect(res.body.field).toBe('name');
  });

  it('maps check violations (23514) to 409 with a field error', async () => {
    const wp = await projectId('Web Platform');
    const res = await request(app).post('/api/procedures/sp_create_volume').set(await as('alice@crms.test')).send({ project_id: wp, name: 'apitest-zero', size_gb: 0 });
    expect(res.status).toBe(409);
    expect(res.body.field).toBe('size_gb');
  });

  it('maps exclusion violations (23P01) to 409', async () => {
    const seeded = (await adminDb.query('SELECT lower(period) AS lo FROM billing_cycles ORDER BY cycle_id LIMIT 1')).rows[0].lo as Date;
    const res = await request(app).post('/api/procedures/sp_create_billing_cycle').set(await as('admin@crms.test'))
      .send({ from: new Date(seeded.getTime() + 86400_000).toISOString(), to: new Date(seeded.getTime() + 2 * 86400_000).toISOString() });
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('23P01');
  });

  it('enforces permissions in the database: a viewer is refused (403), a developer cannot terminate', async () => {
    const wp = await projectId('Web Platform');
    const viewer = await request(app).post('/api/procedures/sp_create_volume').set(await as('carol@crms.test')).send({ project_id: wp, name: 'apitest-x', size_gb: 1 });
    expect(viewer.status).toBe(403);
    const dev = await request(app).post('/api/procedures/sp_terminate_resource').set(await as('bob@crms.test')).send({ resource_id: 1 });
    expect(dev.status).toBe(403);
  });

  it('a developer of another project cannot touch Web Platform (permission is per project)', async () => {
    const wp = await projectId('Web Platform');
    const res = await request(app).post('/api/procedures/sp_create_volume').set(await as('dave@crms.test')).send({ project_id: wp, name: 'apitest-y', size_gb: 1 });
    expect(res.status).toBe(403);
  });

  it('validates input with zod (400) and returns 404 for unknown procedures', async () => {
    const h = await as('alice@crms.test');
    const bad = await request(app).post('/api/procedures/sp_create_volume').set(h).send({ project_id: 'abc', size_gb: 1 });
    expect(bad.status).toBe(400);
    expect(bad.body.fields).toHaveProperty('project_id');
    expect(bad.body.fields).toHaveProperty('name');
    expect((await request(app).post('/api/procedures/sp_drop_everything').set(h).send({})).status).toBe(404);
    expect((await request(app).post('/api/procedures/sp_provision_vm_unsafe').set(h).send({})).status).toBe(404);
  });

  it('generate_invoices reports per-project outcomes (savepoint isolation) and is admin only', async () => {
    const denied = await request(app).post('/api/procedures/sp_generate_invoices').set(await as('alice@crms.test')).send({ cycle_id: 1 });
    expect(denied.status).toBe(403);
    const res = await request(app).post('/api/procedures/sp_generate_invoices').set(await as('admin@crms.test')).send({ cycle_id: 1 });
    expect(res.status).toBe(200);
    expect(res.body.rows.length).toBeGreaterThan(0);
    expect(res.body.rows.every((r: { outcome: string }) => r.outcome === 'failed')).toBe(true);   // already invoiced by the seed
    await adminDb.query("DELETE FROM billing_failures WHERE cycle_id = 1 AND at > now() - interval '1 minute'");
  });

  it('rejects malformed JSON with 400', async () => {
    const res = await request(app).post('/api/procedures/sp_create_volume').set(await as('alice@crms.test')).set('Content-Type', 'application/json').send('{bad');
    expect(res.status).toBe(400);
  });
});

describe('DB Lab queries', () => {
  it('lists the ten named queries for admins only', async () => {
    const admin = await request(app).get('/api/queries').set(await as('admin@crms.test'));
    expect(admin.body.map((q: { name: string }) => q.name)).toEqual(expect.arrayContaining([
      'top3_costliest_projects', 'mom_cost_change', 'idle_resources', 'mem_percentiles', 'inherited_permissions',
      'project_tree_cost', 'missed_heartbeats', 'cpu_anomalies', 'errors_per_hour', 'projects_without_invoice']));
    expect(admin.body).toHaveLength(10);
    expect((await request(app).get('/api/queries').set(await as('alice@crms.test'))).status).toBe(403);
  });

  it('returns SQL text, rows and an EXPLAIN (ANALYZE, FORMAT JSON) plan', async () => {
    const res = await request(app).get('/api/queries/top3_costliest_projects').set(await as('admin@crms.test'));
    expect(res.status).toBe(200);
    expect(res.body.sql).toMatch(/rank\(\) OVER/i);
    expect(res.body.rows.length).toBeGreaterThan(0);
    expect(res.body.columns).toEqual(['project', 'billed', 'rnk']);
    expect(res.body.plan[0].Plan).toHaveProperty('Node Type');
    expect(res.body.plan[0]).toHaveProperty('Execution Time');
  });

  it('runs every named query end to end', async () => {
    const h = await as('admin@crms.test');
    const list = await request(app).get('/api/queries').set(h);
    for (const q of list.body as { name: string }[]) {
      const res = await request(app).get(`/api/queries/${q.name}`).set(h);
      expect(res.status, q.name).toBe(200);
      expect(res.body.rows.length, q.name).toBeGreaterThan(0);
    }
  });

  it('404 for unknown queries and refuses path tricks', async () => {
    const h = await as('admin@crms.test');
    expect((await request(app).get('/api/queries/nope').set(h)).status).toBe(404);
    expect((await request(app).get('/api/queries/..%2F..%2Fetc%2Fpasswd').set(h)).status).toBe(404);
  });
});

describe('alerts stream (SSE over LISTEN/NOTIFY)', () => {
  let server: http.Server;
  let base: string;
  beforeAll(async () => {
    server = http.createServer(app);
    await new Promise<void>((r) => server.listen(0, r));
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  afterAll(async () => { server.closeAllConnections?.(); await new Promise((r) => server.close(r)); });

  function listen(tok: string, onData: (chunk: string) => void): Promise<http.ClientRequest> {
    return new Promise((resolve, reject) => {
      const req = http.get(`${base}/api/stream?token=${tok}`, (res) => {
        expect(res.headers['content-type']).toMatch(/text\/event-stream/);
        res.setEncoding('utf8');
        res.on('data', onData);
        resolve(req);
      });
      req.on('error', reject);
    });
  }
  const until = async (cond: () => boolean, ms = 8000) => { const t = Date.now(); while (!cond() && Date.now() - t < ms) await new Promise((r) => setTimeout(r, 50)); };

  it('requires a token', async () => {
    const res = await request(app).get('/api/stream');
    expect(res.status).toBe(401);
  });

  it('pushes a fired alert to members of the project and not to outsiders', async () => {
    let carolBuf = ''; let daveBuf = '';
    const rc = await listen(await token('carol@crms.test'), (c) => { carolBuf += c; });
    const rd = await listen(await token('dave@crms.test'), (c) => { daveBuf += c; });
    await until(() => carolBuf.includes('event: hello') && daveBuf.includes('event: hello'));
    // ingest as the maintenance role: a CPU breach on worker-1 (Web Platform rule: avg > 85 over 300 s)
    const ts = new Date(Date.now() + 25 * 86400_000).toISOString();
    await adminDb.query('SELECT sp_ingest_metrics($1::jsonb)', [JSON.stringify({ metrics: [{ external_id: 'mock-worker-1', ts, metric: 'cpu_percent', value: 99 }] })]);
    try {
      await until(() => carolBuf.includes('event: alert'));
      expect(carolBuf).toContain('event: alert');
      expect(carolBuf).toMatch(/"type"\s*:\s*"fired"/);
      await new Promise((r) => setTimeout(r, 300));
      expect(daveBuf).not.toContain('event: alert');
    } finally {
      rc.destroy(); rd.destroy();
      await adminDb.query("DELETE FROM alert_events WHERE fired_at > now() + interval '24 days'");
      await adminDb.query("DELETE FROM usage_metrics WHERE ts > now() + interval '24 days'");
    }
  });
});

describe('misc', () => {
  it('health endpoint reports the database', async () => {
    const res = await request(app).get('/api/health');
    expect(res.body).toEqual({ status: 'ok', db: true });
  });
  it('unknown api routes are 404 JSON', async () => {
    const res = await request(app).get('/api/nothing-here');
    expect(res.status).toBe(404);
    expect(res.body.error).toBeDefined();
  });
  it('lists the registry for the caller role', async () => {
    const res = await request(app).get('/api/procedures').set(await as('carol@crms.test'));
    expect(res.body).toHaveLength(0);                              // a viewer may call none
    const admin = await request(app).get('/api/procedures').set(await as('admin@crms.test'));
    expect(admin.body.length).toBe(13);
  });
});
