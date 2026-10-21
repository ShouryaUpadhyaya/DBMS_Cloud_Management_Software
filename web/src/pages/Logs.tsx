import { useState } from 'react';
import { Page } from '../components/Layout';
import { DataTable } from '../components/DataTable';
import { Badge, Card, ErrorBox, levelTone, PageHeader } from '../components/ui';
import { useView } from '../lib/hooks';
import { useProject } from '../lib/project';
import { dateTime } from '../lib/format';
import { Res } from './Resources';

interface Log { log_id: number; resource_id: number; resource_name: string; ts: string; level: string; message: string; attrs: Record<string, unknown> }

const RANGES = [{ h: 1, l: 'Last hour' }, { h: 24, l: 'Last 24 hours' }, { h: 168, l: 'Last 7 days' }, { h: 720, l: 'Last 30 days' }];

export function Logs() {
  const { projectId } = useProject();
  const [resource, setResource] = useState('');
  const [level, setLevel] = useState('');
  const [q, setQ] = useState('');
  const [attrs, setAttrs] = useState('');
  const [hours, setHours] = useState(24);
  const [limit, setLimit] = useState(200);
  const [open, setOpen] = useState<number | null>(null);
  const since = new Date(Math.floor((Date.now() - hours * 3600_000) / 60_000) * 60_000).toISOString();
  const resources = useView<Res>('v_active_resources', { project_id: projectId ?? undefined, type: 'compute', limit: 1000 });
  const logs = useView<Log>('v_logs', { project_id: projectId ?? undefined, resource_id: resource, level, q, attrs, since, limit }, { refresh: 30 });

  return (
    <Page>
      <PageHeader title="Logs explorer" subtitle="Full-text search (GIN on to_tsvector) and jsonb containment (GIN on attrs) over partitioned log_entries" />
      <Card>
        <div className="grid gap-2 border-b border-line p-3 sm:grid-cols-2 lg:grid-cols-5">
          <div><label className="label" htmlFor="lq">Search message</label><input id="lq" className="input" placeholder="redis, timeout…" value={q} onChange={(e) => setQ(e.target.value)} /></div>
          <div><label className="label" htmlFor="lattrs">attrs contains (JSON)</label><input id="lattrs" className="input mono" placeholder='{"status": 500}' value={attrs} onChange={(e) => setAttrs(e.target.value)} /></div>
          <div><label className="label" htmlFor="lres">Resource</label>
            <select id="lres" className="input" value={resource} onChange={(e) => setResource(e.target.value)}><option value="">All</option>{(resources.data ?? []).map((r) => <option key={r.resource_id} value={r.resource_id}>{r.name}</option>)}</select></div>
          <div><label className="label" htmlFor="llvl">Level</label>
            <select id="llvl" className="input" value={level} onChange={(e) => setLevel(e.target.value)}><option value="">All</option><option>error</option><option>warn</option><option>info</option><option>debug</option></select></div>
          <div><label className="label" htmlFor="lrange">Time range</label>
            <select id="lrange" className="input" value={hours} onChange={(e) => setHours(Number(e.target.value))}>{RANGES.map((r) => <option key={r.h} value={r.h}>{r.l}</option>)}</select></div>
        </div>
        <ErrorBox error={logs.error} />
        <DataTable rows={logs.data} loading={logs.isLoading} rowKey={(l) => l.log_id} pageSize={25} empty="No log lines match" onRowClick={(l) => setOpen(open === l.log_id ? null : l.log_id)}
          isExpanded={(l) => open === l.log_id} expanded={(l) => <pre className="mono overflow-x-auto p-3">{JSON.stringify(l.attrs, null, 2)}</pre>}
          columns={[
            { key: 'ts', header: 'Time', render: (l: Log) => dateTime(l.ts) },
            { key: 'level', header: 'Level', render: (l: Log) => <Badge tone={levelTone(l.level)}>{l.level}</Badge> },
            { key: 'resource_name', header: 'Resource' },
            { key: 'message', header: 'Message', className: 'whitespace-normal' },
          ]} />
        <div className="flex items-center justify-between border-t border-line px-3 py-2 text-xs text-muted">
          <span>Showing up to {limit} newest lines · click a row for its attrs</span>
          {(logs.data?.length ?? 0) >= limit && <button className="btn" onClick={() => setLimit(limit + 200)}>Load more</button>}
        </div>
      </Card>
    </Page>
  );
}
