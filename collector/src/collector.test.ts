import { describe, expect, it } from 'vitest';
import { cpuPercent, detectLevel, memPercent, parseLogStream } from './docker.js';
import { MockSource } from './mock.js';

function lcg(seed: number) { let s = seed; return () => (s = (s * 1664525 + 1013904223) % 4294967296) / 4294967296; }

describe('MockSource', () => {
  it('simulates 8 containers, 2 volumes and 2 networks with the seed external ids', async () => {
    const s = await new MockSource({ random: lcg(1) }).sample(new Date('2026-01-01T12:00:00Z'));
    expect(s.resources.filter((r) => r.type === 'compute')).toHaveLength(8);
    expect(s.resources.filter((r) => r.type === 'storage')).toHaveLength(2);
    expect(s.resources.filter((r) => r.type === 'network')).toHaveLength(2);
    expect(s.resources.every((r) => r.external_id.startsWith('mock-'))).toBe(true);
    expect(s.node.hostname).toBe('crms-local');
  });

  it('emits cpu/mem/net for running containers only, all within valid ranges', async () => {
    const s = await new MockSource({ random: lcg(2) }).sample(new Date());
    const cache = s.metrics.filter((m) => m.external_id === 'mock-cache-1');
    expect(cache).toHaveLength(0);                               // stopped
    const web = s.metrics.filter((m) => m.external_id === 'mock-web-1').map((m) => m.metric).sort();
    expect(web).toEqual(['cpu_percent', 'mem_percent', 'net_kbps']);
    for (const m of s.metrics) {
      expect(m.value).toBeGreaterThanOrEqual(0);
      if (m.metric !== 'net_kbps') expect(m.value).toBeLessThanOrEqual(100);
    }
  });

  it('produces sustained incidents and log lines over many ticks', async () => {
    const src = new MockSource({ random: lcg(3), incidentProbability: 0.05 });
    let hot = 0; let logs = 0; let errors = 0;
    for (let i = 0; i < 100; i++) {
      const s = await src.sample(new Date(Date.UTC(2026, 0, 1, 0, 0, i * 30)));
      hot += s.metrics.filter((m) => m.metric === 'cpu_percent' && m.value > 90).length;
      logs += s.logs.length;
      errors += s.logs.filter((l) => l.level === 'error').length;
    }
    expect(hot).toBeGreaterThan(10);
    expect(logs).toBeGreaterThan(100);
    expect(errors).toBeGreaterThan(0);
  });
});

describe('docker helpers', () => {
  it('computes cpu and memory percentages like `docker stats`', () => {
    const stats = {
      cpu_stats: { cpu_usage: { total_usage: 2_000_000 }, system_cpu_usage: 20_000_000, online_cpus: 4 },
      precpu_stats: { cpu_usage: { total_usage: 1_000_000 }, system_cpu_usage: 10_000_000 },
      memory_stats: { usage: 300, limit: 1000, stats: { inactive_file: 100 } },
    };
    expect(cpuPercent(stats)).toBeCloseTo(40, 5);              // 10% of host x 4 cpus
    expect(memPercent(stats)).toBeCloseTo(20, 5);              // (300-100)/1000
  });

  it('returns 0 instead of NaN when the first sample has no delta', () => {
    const z = { cpu_stats: { cpu_usage: { total_usage: 5 } }, precpu_stats: { cpu_usage: { total_usage: 5 } }, memory_stats: {} };
    expect(cpuPercent(z)).toBe(0);
    expect(memPercent(z)).toBe(0);
  });

  it('demultiplexes framed log streams', () => {
    const frame = (type: number, text: string) => {
      const body = Buffer.from(text);
      const h = Buffer.alloc(8); h[0] = type; h.writeUInt32BE(body.length, 4);
      return Buffer.concat([h, body]);
    };
    const buf = Buffer.concat([
      frame(1, '2026-01-01T00:00:00.000000000Z hello world\n'),
      frame(2, '2026-01-01T00:00:01.000000000Z ERROR boom\n'),
    ]);
    const lines = parseLogStream(buf);
    expect(lines).toHaveLength(2);
    expect(lines[0]).toMatchObject({ stream: 'stdout', message: 'hello world' });
    expect(lines[1]).toMatchObject({ stream: 'stderr', message: 'ERROR boom' });
  });

  it('parses raw (tty) streams and detects levels', () => {
    expect(parseLogStream(Buffer.from('2026-01-01T00:00:00Z plain line\n'))[0].message).toBe('plain line');
    expect(detectLevel('Unhandled exception in handler', 'stdout')).toBe('error');
    expect(detectLevel('WARNING: disk almost full', 'stdout')).toBe('warn');
    expect(detectLevel('listening on :80', 'stderr')).toBe('warn');
    expect(detectLevel('listening on :80', 'stdout')).toBe('info');
  });
});
