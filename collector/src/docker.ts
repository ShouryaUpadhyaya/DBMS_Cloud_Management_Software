import http from 'node:http';
import os from 'node:os';
import { LogLine, MetricPoint, ResourceSnapshot, Sample, Source } from './types.js';

/** Minimal Docker Engine API client over HTTP (DOCKER_HOST=tcp://host:port, e.g. a read-only socket proxy). */
export class DockerClient {
  private readonly host: string;
  private readonly port: number;

  constructor(dockerHost: string) {
    const m = /^tcp:\/\/([^:/]+):(\d+)$/.exec(dockerHost);
    if (!m) {
      throw new Error(`DOCKER_HOST must look like tcp://host:port (a socket proxy); got "${dockerHost}"`);
    }
    this.host = m[1];
    this.port = Number(m[2]);
  }

  get(path: string): Promise<Buffer> {
    return new Promise((resolve, reject) => {
      const req = http.request({ host: this.host, port: this.port, path, method: 'GET', timeout: 15_000 }, (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (c: Buffer) => chunks.push(c));
        res.on('end', () => {
          const body = Buffer.concat(chunks);
          if ((res.statusCode ?? 500) >= 400) reject(new Error(`docker ${path} -> ${res.statusCode}: ${body.toString().slice(0, 200)}`));
          else resolve(body);
        });
      });
      req.on('timeout', () => req.destroy(new Error(`docker ${path} timed out`)));
      req.on('error', reject);
      req.end();
    });
  }

  async json<T>(path: string): Promise<T> {
    return JSON.parse((await this.get(path)).toString('utf8')) as T;
  }
}

// ---- pure helpers (unit tested) -----------------------------------------------------------

export interface DockerStats {
  cpu_stats: { cpu_usage: { total_usage: number }; system_cpu_usage?: number; online_cpus?: number };
  precpu_stats: { cpu_usage: { total_usage: number }; system_cpu_usage?: number };
  memory_stats: { usage?: number; limit?: number; stats?: Record<string, number> };
  networks?: Record<string, { rx_bytes: number; tx_bytes: number }>;
}

export function cpuPercent(s: DockerStats): number {
  const cpuDelta = s.cpu_stats.cpu_usage.total_usage - s.precpu_stats.cpu_usage.total_usage;
  const sysDelta = (s.cpu_stats.system_cpu_usage ?? 0) - (s.precpu_stats.system_cpu_usage ?? 0);
  if (cpuDelta <= 0 || sysDelta <= 0) return 0;
  return Math.min(100, (cpuDelta / sysDelta) * (s.cpu_stats.online_cpus ?? 1) * 100);
}

export function memPercent(s: DockerStats): number {
  const limit = s.memory_stats.limit ?? 0;
  if (!limit) return 0;
  const cache = s.memory_stats.stats?.inactive_file ?? s.memory_stats.stats?.cache ?? 0;
  return Math.min(100, Math.max(0, ((s.memory_stats.usage ?? 0) - cache) / limit * 100));
}

export function netBytes(s: DockerStats): number {
  return Object.values(s.networks ?? {}).reduce((acc, n) => acc + n.rx_bytes + n.tx_bytes, 0);
}

/** Demultiplexes Docker's log stream (8-byte frame headers) into text lines with their timestamps. */
export function parseLogStream(buf: Buffer): { stream: 'stdout' | 'stderr'; ts: string; message: string }[] {
  const out: { stream: 'stdout' | 'stderr'; ts: string; message: string }[] = [];
  let off = 0;
  const looksFramed = buf.length >= 8 && (buf[0] === 1 || buf[0] === 2) && buf[1] === 0 && buf[2] === 0 && buf[3] === 0;
  const pushText = (stream: 'stdout' | 'stderr', text: string) => {
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      const sp = line.indexOf(' ');
      const maybeTs = sp > 0 ? line.slice(0, sp) : '';
      const valid = /^\d{4}-\d{2}-\d{2}T/.test(maybeTs);
      out.push({ stream, ts: valid ? maybeTs : new Date().toISOString(), message: valid ? line.slice(sp + 1) : line });
    }
  };
  if (!looksFramed) {            // TTY containers send a raw stream
    pushText('stdout', buf.toString('utf8'));
    return out;
  }
  while (off + 8 <= buf.length) {
    const stream = buf[off] === 2 ? 'stderr' : 'stdout';
    const size = buf.readUInt32BE(off + 4);
    pushText(stream, buf.subarray(off + 8, off + 8 + size).toString('utf8'));
    off += 8 + size;
  }
  return out;
}

export function detectLevel(message: string, stream: 'stdout' | 'stderr'): LogLine['level'] {
  const m = message.toLowerCase();
  if (/\b(error|err|fatal|panic|exception|fail(ed)?)\b/.test(m)) return 'error';
  if (/\b(warn|warning)\b/.test(m)) return 'warn';
  if (/\bdebug\b/.test(m)) return 'debug';
  return stream === 'stderr' ? 'warn' : 'info';
}

// ---- source -------------------------------------------------------------------------------

interface ContainerSummary { Id: string; Names: string[]; Image: string; State: string; Labels?: Record<string, string> }
interface ContainerInspect { HostConfig: { NanoCpus?: number; Memory?: number }; Config: { Image: string } }
interface NetworkSummary { Id: string; Name: string; Driver: string; IPAM?: { Config?: { Subnet?: string }[] }; Labels?: Record<string, string> }
interface VolumeList { Volumes: { Name: string; Mountpoint: string; Labels?: Record<string, string> | null }[] | null }

export class DockerSource implements Source {
  private lastNet = new Map<string, { bytes: number; at: number }>();
  private lastLogAt = new Map<string, number>();

  constructor(private readonly docker: DockerClient, private readonly region = process.env.COLLECTOR_REGION ?? 'local') {}

  async sample(now: Date): Promise<Sample> {
    const ts = now.toISOString();
    const resources: ResourceSnapshot[] = [];
    const metrics: MetricPoint[] = [];
    const logs: LogLine[] = [];

    const networks = await this.docker.json<NetworkSummary[]>('/networks');
    for (const n of networks) {
      const subnet = n.IPAM?.Config?.find((c) => c.Subnet && !c.Subnet.includes(':'))?.Subnet;
      if (!subnet) continue;                                   // host/none or IPv6-only
      resources.push({ external_id: n.Id, type: 'network', name: n.Name, state: 'running', project: n.Labels?.['crms.project'], cidr: subnet });
    }

    const vols = await this.docker.json<VolumeList>('/volumes');
    for (const v of vols.Volumes ?? []) {
      resources.push({
        external_id: `volume:${v.Name}`, type: 'storage', name: v.Name, state: 'running', project: v.Labels?.['crms.project'],
        size_gb: 1, mount_path: v.Mountpoint,
      });
    }

    const containers = await this.docker.json<ContainerSummary[]>('/containers/json?all=1');
    for (const c of containers) {
      const name = (c.Names[0] ?? c.Id.slice(0, 12)).replace(/^\//, '');
      const running = c.State === 'running';
      let vcpus = 1;
      let memoryMb = 512;
      try {
        const info = await this.docker.json<ContainerInspect>(`/containers/${c.Id}/json`);
        if (info.HostConfig.NanoCpus) vcpus = Math.max(1, Math.round(info.HostConfig.NanoCpus / 1e9));
        if (info.HostConfig.Memory) memoryMb = Math.max(1, Math.round(info.HostConfig.Memory / 1048576));
      } catch { /* inspect is best effort */ }
      resources.push({
        external_id: c.Id, type: 'compute', name, state: running ? 'running' : 'stopped', project: c.Labels?.['crms.project'],
        vcpus, memory_mb: memoryMb, image: c.Image,
      });
      if (!running) continue;

      try {
        const stats = await this.docker.json<DockerStats>(`/containers/${c.Id}/stats?stream=false`);
        metrics.push(
          { external_id: c.Id, ts, metric: 'cpu_percent', value: round(cpuPercent(stats)) },
          { external_id: c.Id, ts, metric: 'mem_percent', value: round(memPercent(stats)) },
        );
        const bytes = netBytes(stats);
        const prev = this.lastNet.get(c.Id);
        if (prev && now.getTime() > prev.at && bytes >= prev.bytes) {
          const kbps = ((bytes - prev.bytes) * 8) / 1000 / ((now.getTime() - prev.at) / 1000);
          metrics.push({ external_id: c.Id, ts, metric: 'net_kbps', value: round(kbps) });
        }
        this.lastNet.set(c.Id, { bytes, at: now.getTime() });
      } catch { /* container may have stopped between list and stats */ }

      try {
        const since = Math.floor((this.lastLogAt.get(c.Id) ?? now.getTime() - 60_000) / 1000);
        const raw = await this.docker.get(`/containers/${c.Id}/logs?stdout=1&stderr=1&timestamps=1&since=${since}&tail=200`);
        this.lastLogAt.set(c.Id, now.getTime());
        for (const l of parseLogStream(raw)) {
          logs.push({ external_id: c.Id, ts: l.ts, level: detectLevel(l.message, l.stream), message: l.message, attrs: { container: name, stream: l.stream } });
        }
      } catch { /* logs unavailable (e.g. log driver none) */ }
    }
    return { node: { hostname: os.hostname(), region: this.region }, resources, metrics, logs };
  }
}

function round(v: number): number { return Math.round(v * 100) / 100; }
