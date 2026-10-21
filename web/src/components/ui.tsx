import { ReactNode } from 'react';

export function Card({ title, actions, children, className = '' }: { title?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`card ${className}`}>
      {title !== undefined && <div className="card-h"><span>{title}</span><span className="flex items-center gap-2 normal-case tracking-normal">{actions}</span></div>}
      {children}
    </section>
  );
}

const TONES: Record<string, string> = {
  ok: 'bg-ok/15 text-ok', warn: 'bg-warn/15 text-warn', bad: 'bg-bad/15 text-bad', info: 'bg-accent/15 text-accent', neutral: 'bg-subtle text-muted',
};

export function Badge({ tone = 'neutral', children }: { tone?: keyof typeof TONES; children: ReactNode }) {
  return <span className={`inline-block rounded px-1.5 py-0.5 text-xs font-medium ${TONES[tone]}`}>{children}</span>;
}

export const stateTone = (s: string): keyof typeof TONES =>
  ({ running: 'ok', stopped: 'warn', pending: 'info', terminated: 'bad', paid: 'ok', issued: 'info', draft: 'neutral', void: 'bad', active: 'ok', suspended: 'bad' } as Record<string, keyof typeof TONES>)[s] ?? 'neutral';
export const levelTone = (l: string): keyof typeof TONES => ({ error: 'bad', warn: 'warn', info: 'info', debug: 'neutral' } as Record<string, keyof typeof TONES>)[l] ?? 'neutral';

export function Spinner({ label = 'Loading' }: { label?: string }) {
  return <div className="p-4 text-xs text-muted" role="status">{label}…</div>;
}

export function ErrorBox({ error }: { error: unknown }) {
  if (!error) return null;
  return <div role="alert" className="m-3 rounded border border-bad/40 bg-bad/10 px-3 py-2 text-sm text-bad">{(error as Error).message}</div>;
}

export function Tile({ label, value, sub, tone }: { label: string; value: ReactNode; sub?: ReactNode; tone?: 'ok' | 'warn' | 'bad' }) {
  const color = tone === 'bad' ? 'text-bad' : tone === 'warn' ? 'text-warn' : tone === 'ok' ? 'text-ok' : 'text-fg';
  return (
    <div className="card px-3 py-2">
      <div className="text-xs font-medium uppercase tracking-wide text-muted">{label}</div>
      <div className={`mt-0.5 text-2xl font-semibold tabular-nums ${color}`}>{value}</div>
      {sub !== undefined && <div className="text-xs text-muted">{sub}</div>}
    </div>
  );
}

export function PageHeader({ title, subtitle, actions }: { title: string; subtitle?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="mb-3 flex flex-wrap items-end justify-between gap-2">
      <div>
        <h1 className="text-lg font-semibold">{title}</h1>
        {subtitle && <p className="text-xs text-muted">{subtitle}</p>}
      </div>
      <div className="flex flex-wrap items-center gap-2">{actions}</div>
    </div>
  );
}

export function UsageBar({ used, max }: { used: number; max: number }) {
  const pct = max > 0 ? Math.min(100, (used / max) * 100) : 100;
  const tone = pct >= 100 ? 'bg-bad' : pct >= 80 ? 'bg-warn' : 'bg-ok';
  return (
    <div className="h-1.5 w-full rounded bg-subtle" role="progressbar" aria-valuenow={used} aria-valuemin={0} aria-valuemax={max}>
      <div className={`h-1.5 rounded ${tone}`} style={{ width: `${pct}%` }} />
    </div>
  );
}
