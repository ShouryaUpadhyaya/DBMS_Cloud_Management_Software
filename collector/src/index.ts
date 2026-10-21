import pg from 'pg';
import { DockerClient, DockerSource } from './docker.js';
import { MockSource } from './mock.js';
import { Sample, Source } from './types.js';

const mode = (process.env.COLLECTOR_MODE ?? 'mock') as 'mock' | 'docker';
const intervalMs = Number(process.env.COLLECTOR_INTERVAL_SECONDS ?? 30) * 1000;
const once = process.env.COLLECTOR_ONCE === '1';
const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) throw new Error('DATABASE_URL is required');

function makeSource(): Source {
  if (mode === 'mock') return new MockSource();
  if (mode === 'docker') {
    const host = process.env.DOCKER_HOST;
    if (!host) throw new Error('COLLECTOR_MODE=docker needs DOCKER_HOST (tcp:// address of a read-only socket proxy)');
    return new DockerSource(new DockerClient(host));
  }
  throw new Error(`unknown COLLECTOR_MODE "${mode}" (use mock or docker)`);
}

/** Pushes one sample through the two ingestion procedures; the collector role can call nothing else. */
export async function push(pool: pg.Pool, s: Sample): Promise<{ metrics: unknown; logs: unknown }> {
  const metricsPayload = { node: s.node, full_snapshot: true, resources: s.resources, metrics: s.metrics };
  const m = await pool.query('SELECT sp_ingest_metrics($1::jsonb) AS r', [JSON.stringify(metricsPayload)]);
  const l = await pool.query('SELECT sp_ingest_logs($1::jsonb) AS r', [JSON.stringify({ logs: s.logs })]);
  return { metrics: m.rows[0].r, logs: l.rows[0].r };
}

async function main(): Promise<void> {
  const pool = new pg.Pool({ connectionString: databaseUrl, max: 2 });
  const source = makeSource();
  let stopping = false;
  const stop = () => { stopping = true; };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  console.log(`collector started: mode=${mode} interval=${intervalMs / 1000}s`);

  do {
    const started = Date.now();
    try {
      const sample = await source.sample(new Date());
      const result = await push(pool, sample);
      console.log(`${new Date().toISOString()} ingested`, JSON.stringify(result));
    } catch (err) {
      // Never crash the loop: the database may not be migrated yet, or Docker may be briefly unreachable.
      console.error(`${new Date().toISOString()} tick failed:`, (err as Error).message);
      if (once) process.exitCode = 1;
    }
    if (once || stopping) break;
    const wait = Math.max(1000, intervalMs - (Date.now() - started));
    await new Promise<void>((resolve) => {
      const t = setTimeout(resolve, wait);
      process.once('SIGTERM', () => { clearTimeout(t); resolve(); });
    });
  } while (!stopping);
  await pool.end();
}

main().catch((err) => { console.error(err); process.exit(1); });
