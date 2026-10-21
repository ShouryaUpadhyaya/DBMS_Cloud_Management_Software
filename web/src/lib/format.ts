export const money = (v: unknown): string => {
  const n = Number(v);
  return Number.isFinite(n) ? n.toLocaleString(undefined, { style: 'currency', currency: 'USD', minimumFractionDigits: 2 }) : '—';
};

export const num = (v: unknown, digits = 1): string => {
  const n = Number(v);
  return Number.isFinite(n) ? n.toLocaleString(undefined, { maximumFractionDigits: digits }) : '—';
};

export const dateTime = (v: unknown): string => {
  if (!v) return '—';
  const d = new Date(String(v));
  return Number.isNaN(d.getTime()) ? String(v) : d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'medium' });
};

export const shortDate = (v: unknown): string => {
  if (!v) return '—';
  const d = new Date(String(v));
  return Number.isNaN(d.getTime()) ? String(v) : d.toLocaleDateString(undefined, { dateStyle: 'medium' });
};

export const ago = (v: unknown, now = Date.now()): string => {
  if (!v) return '—';
  const s = Math.max(0, Math.round((now - new Date(String(v)).getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
};

export const metricUnit = (m: string): string => (m === 'net_kbps' ? 'kbps' : '%');
export const metricLabel = (m: string): string =>
  ({ cpu_percent: 'CPU', mem_percent: 'Memory', net_kbps: 'Network', disk_percent: 'Disk' } as Record<string, string>)[m] ?? m;

export interface JsonChange { key: string; kind: 'added' | 'removed' | 'changed' | 'same'; before?: unknown; after?: unknown }

/** Key-level diff of two audit images (old_data/new_data). */
export function diffJson(before: Record<string, unknown> | null | undefined, after: Record<string, unknown> | null | undefined): JsonChange[] {
  const b = before ?? {};
  const a = after ?? {};
  const keys = [...new Set([...Object.keys(b), ...Object.keys(a)])].sort();
  return keys.map((key) => {
    const inB = key in b;
    const inA = key in a;
    if (inB && !inA) return { key, kind: 'removed' as const, before: b[key] };
    if (!inB && inA) return { key, kind: 'added' as const, after: a[key] };
    return JSON.stringify(b[key]) === JSON.stringify(a[key])
      ? { key, kind: 'same' as const, before: b[key], after: a[key] }
      : { key, kind: 'changed' as const, before: b[key], after: a[key] };
  });
}
