import { useEffect, useMemo, useState } from 'react';
import { Page } from '../components/Layout';
import { MetricChart } from '../components/MetricChart';
import { Card, PageHeader } from '../components/ui';
import { useView } from '../lib/hooks';
import { useProject } from '../lib/project';
import { metricLabel } from '../lib/format';
import { Res } from './Resources';

const METRICS = ['cpu_percent', 'mem_percent', 'net_kbps', 'disk_percent'];
const RANGES = [{ h: 1, l: '1 hour' }, { h: 6, l: '6 hours' }, { h: 24, l: '24 hours' }, { h: 168, l: '7 days' }, { h: 720, l: '30 days' }];

export function Monitoring() {
  const { projectId } = useProject();
  const [metric, setMetric] = useState('cpu_percent');
  const [hours, setHours] = useState(6);
  const [picked, setPicked] = useState<number[]>([]);
  const { data } = useView<Res>('v_active_resources', { project_id: projectId ?? undefined, limit: 1000 });
  const candidates = useMemo(() => (data ?? []).filter((r) => (metric === 'disk_percent' ? r.type === 'storage' : r.type === 'compute')), [data, metric]);

  useEffect(() => { setPicked(candidates.filter((r) => r.state === 'running').slice(0, 4).map((r) => r.resource_id)); }, [candidates.map((c) => c.resource_id).join(',')]); // eslint-disable-line react-hooks/exhaustive-deps

  const toggle = (id: number) => setPicked((p) => (p.includes(id) ? p.filter((x) => x !== id) : [...p, id]));

  return (
    <Page>
      <PageHeader title="Monitoring" subtitle="Per-minute telemetry from usage_metrics, bucketed by fn_metric_series" actions={
        <select className="input w-28" aria-label="Range" value={hours} onChange={(e) => setHours(Number(e.target.value))}>{RANGES.map((r) => <option key={r.h} value={r.h}>{r.l}</option>)}</select>} />
      <div className="mb-3 flex flex-wrap gap-1" role="tablist" aria-label="Metric">
        {METRICS.map((m) => <button key={m} role="tab" aria-selected={metric === m} className={`btn ${metric === m ? 'btn-primary' : ''}`} onClick={() => setMetric(m)}>{metricLabel(m)}</button>)}
      </div>
      <div className="grid gap-3 lg:grid-cols-4">
        <Card title="Resources">
          <ul className="max-h-[28rem] overflow-auto p-2">
            {candidates.length === 0 && <li className="p-1 text-xs text-muted">No resources report this metric</li>}
            {candidates.map((r) => (
              <li key={r.resource_id}><label className="flex cursor-pointer items-center gap-2 rounded px-1 py-1 hover:bg-subtle">
                <input type="checkbox" checked={picked.includes(r.resource_id)} onChange={() => toggle(r.resource_id)} />
                <span className="flex-1 truncate">{r.name}</span><span className="text-xs text-muted">{r.state}</span>
              </label></li>
            ))}
          </ul>
        </Card>
        <div className="grid gap-3 md:grid-cols-2 lg:col-span-3">
          {picked.length === 0 && <Card><p className="p-4 text-xs text-muted">Select a resource to chart its {metricLabel(metric)}.</p></Card>}
          {picked.map((id) => {
            const r = candidates.find((c) => c.resource_id === id);
            return <Card key={`${id}-${metric}`} title={r?.name ?? `#${id}`}><div className="p-3"><MetricChart resourceId={id} metric={metric} hours={hours} /></div></Card>;
          })}
        </div>
      </div>
    </Page>
  );
}
