import { LogLine, MetricPoint, ResourceSnapshot, Sample, Source } from './types.js';

// The same containers, volumes and networks as db/seed, so the live data continues the seeded history.
interface MockContainer {
  name: string;
  project: string;
  vcpus: number;
  memory_mb: number;
  image: string;
  running: boolean;
  cpuBase: number;
  cpuAmp: number;
  memBase: number;
  netBase: number;
}

const CONTAINERS: MockContainer[] = [
  { name: 'web-1', project: 'Web Platform', vcpus: 2, memory_mb: 2048, image: 'nginx:1.27', running: true, cpuBase: 28, cpuAmp: 18, memBase: 45, netBase: 400 },
  { name: 'web-2', project: 'Web Platform', vcpus: 2, memory_mb: 2048, image: 'nginx:1.27', running: true, cpuBase: 26, cpuAmp: 17, memBase: 44, netBase: 400 },
  { name: 'api-1', project: 'Web Platform', vcpus: 2, memory_mb: 4096, image: 'crms/api:latest', running: true, cpuBase: 35, cpuAmp: 22, memBase: 55, netBase: 400 },
  { name: 'worker-1', project: 'Web Platform', vcpus: 1, memory_mb: 1024, image: 'crms/worker:latest', running: true, cpuBase: 20, cpuAmp: 15, memBase: 38, netBase: 400 },
  { name: 'cache-1', project: 'Web Platform', vcpus: 1, memory_mb: 512, image: 'redis:7', running: false, cpuBase: 8, cpuAmp: 4, memBase: 30, netBase: 400 },
  { name: 'staging-web-1', project: 'Web Platform Staging', vcpus: 1, memory_mb: 1024, image: 'nginx:1.27', running: true, cpuBase: 10, cpuAmp: 6, memBase: 35, netBase: 400 },
  { name: 'etl-1', project: 'Data Lab', vcpus: 4, memory_mb: 8192, image: 'python:3.12', running: true, cpuBase: 40, cpuAmp: 35, memBase: 60, netBase: 900 },
  { name: 'notebook-1', project: 'Data Lab', vcpus: 2, memory_mb: 4096, image: 'jupyter/base:latest', running: true, cpuBase: 2, cpuAmp: 1.5, memBase: 25, netBase: 5 },
];

const VOLUMES = [
  { name: 'pgdata', project: 'Web Platform', size_gb: 100, mount: '/var/lib/postgresql', usedBase: 62 },
  { name: 'datasets', project: 'Data Lab', size_gb: 400, mount: '/data', usedBase: 70 },
];

const NETWORKS = [
  { name: 'web-net', project: 'Web Platform', cidr: '10.10.1.0/24' },
  { name: 'data-net', project: 'Data Lab', cidr: '10.10.2.0/24' },
];

const INFO_LINES = ['GET /api/items 200 served', 'POST /api/orders created order', 'health check ok', 'cache hit ratio 0.93'];
const WARN_LINES = ['slow query took over 1000 ms', 'rate limit reached for client', 'retrying upstream request'];
const ERROR_LINES = ['connection refused to redis:6379', 'upstream timed out while reading response', 'unhandled exception in request handler'];

const clamp = (v: number, lo = 0, hi = 100) => Math.max(lo, Math.min(hi, v));

export interface MockOptions {
  /** Probability per container per tick of starting a sustained CPU incident (drives alerts). */
  incidentProbability?: number;
  /** Random source, injectable for tests. */
  random?: () => number;
}

export class MockSource implements Source {
  private readonly rnd: () => number;
  private readonly incidentProbability: number;
  private incident = new Map<string, number>();       // container -> remaining ticks
  private mem = new Map<string, number>();
  private disk = new Map<string, number>();

  constructor(opts: MockOptions = {}) {
    this.rnd = opts.random ?? Math.random;
    this.incidentProbability = opts.incidentProbability ?? 0.002;
    for (const c of CONTAINERS) this.mem.set(c.name, c.memBase);
    for (const v of VOLUMES) this.disk.set(v.name, v.usedBase);
  }

  async sample(now: Date): Promise<Sample> {
    const ts = now.toISOString();
    const dayFrac = (now.getTime() / 86_400_000) % 1;
    const resources: ResourceSnapshot[] = [];
    const metrics: MetricPoint[] = [];
    const logs: LogLine[] = [];

    for (const n of NETWORKS) {
      resources.push({ external_id: `mock-${n.name}`, type: 'network', name: n.name, state: 'running', project: n.project, cidr: n.cidr });
    }
    for (const v of VOLUMES) {
      resources.push({ external_id: `mock-${v.name}`, type: 'storage', name: v.name, state: 'running', project: v.project, size_gb: v.size_gb, mount_path: v.mount });
      const used = clamp((this.disk.get(v.name) ?? v.usedBase) + this.rnd() * 0.01);
      this.disk.set(v.name, used);
      metrics.push({ external_id: `mock-${v.name}`, ts, metric: 'disk_percent', value: round(used) });
    }

    for (const c of CONTAINERS) {
      const id = `mock-${c.name}`;
      resources.push({
        external_id: id, type: 'compute', name: c.name, state: c.running ? 'running' : 'stopped', project: c.project,
        vcpus: c.vcpus, memory_mb: c.memory_mb, image: c.image,
      });
      if (!c.running) continue;

      let remaining = this.incident.get(c.name) ?? 0;
      if (remaining === 0 && this.rnd() < this.incidentProbability) remaining = 14;   // ~7 minutes at 30 s
      let cpu = c.cpuBase + c.cpuAmp * Math.sin(dayFrac * 2 * Math.PI - 1.2) + (this.rnd() - 0.5) * 6;
      if (this.rnd() < 0.02) cpu += 30 + this.rnd() * 35;                                // one-off spike
      if (remaining > 0) { cpu = 92 + this.rnd() * 7; remaining -= 1; }
      this.incident.set(c.name, remaining);

      const memPrev = this.mem.get(c.name) ?? c.memBase;
      const mem = clamp(memPrev + (this.rnd() - 0.5) * 0.8 + (c.memBase - memPrev) * 0.02);   // mean-reverting walk
      this.mem.set(c.name, mem);
      const net = Math.max(0, c.netBase * (1 + 0.6 * Math.sin(dayFrac * 2 * Math.PI - 1)) * (0.7 + this.rnd() * 0.6)) *
        (this.rnd() < 0.01 ? 4 : 1);

      metrics.push(
        { external_id: id, ts, metric: 'cpu_percent', value: round(clamp(cpu)) },
        { external_id: id, ts, metric: 'mem_percent', value: round(mem) },
        { external_id: id, ts, metric: 'net_kbps', value: round(net) },
      );

      // Log volume grows with CPU; errors cluster during incidents.
      const lines = this.rnd() < 0.5 ? 1 + Math.floor(this.rnd() * (cpu > 70 ? 4 : 2)) : 0;
      for (let i = 0; i < lines; i++) {
        const p = this.rnd();
        const errP = remaining > 0 ? 0.35 : 0.04;
        const level = p < errP ? 'error' : p < errP + 0.12 ? 'warn' : 'info';
        const pool = level === 'error' ? ERROR_LINES : level === 'warn' ? WARN_LINES : INFO_LINES;
        logs.push({
          external_id: id, ts, level, message: pool[Math.floor(this.rnd() * pool.length)],
          attrs: { container: c.name, request_id: randomId(this.rnd), latency_ms: Math.floor(this.rnd() * 900), status: level === 'error' ? 500 : level === 'warn' ? 429 : 200 },
        });
      }
    }
    return { node: { hostname: 'crms-local', region: 'local' }, resources, metrics, logs };
  }
}

function round(v: number): number { return Math.round(v * 100) / 100; }
function randomId(rnd: () => number): string {
  let s = '';
  for (let i = 0; i < 16; i++) s += Math.floor(rnd() * 16).toString(16);
  return s;
}
