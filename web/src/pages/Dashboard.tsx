import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { Link, useNavigate } from 'react-router-dom';
import { Page } from '../components/Layout';
import { DataTable } from '../components/DataTable';
import { Badge, Card, PageHeader, stateTone, Tile, UsageBar } from '../components/ui';
import { useView } from '../lib/hooks';
import { useProject } from '../lib/project';
import { ago, metricLabel, money, num } from '../lib/format';

interface Res { resource_id: number; name: string; type: string; state: string; project_name: string; vcpus: number | null; size_gb: number | null }
interface Cost { project_id: number; project_name: string; cost_mtd: string }
interface Alert { event_id: number; resource_name: string; project_name: string; metric: string; peak_value: number; fired_at: string }
interface Quota { project_id: number; project_name: string; resource_type: string; max_units: number; used_units: number }
interface Latest { resource_id: number; metric: string; value: number }

export function Dashboard() {
  const { projectId } = useProject();
  const nav = useNavigate();
  const p = projectId ? { project_id: projectId } : undefined;
  const res = useView<Res>('v_active_resources', { ...p, limit: 1000 }, { refresh: 30 });
  const alerts = useView<Alert>('v_open_alerts', p, { refresh: 30 });
  const cost = useView<Cost>('v_project_cost_mtd', p);
  const quotas = useView<Quota>('v_quota_usage', p);
  const latest = useView<Latest>('latest_metrics', undefined, { refresh: 30 });

  const rows = res.data ?? [];
  const running = rows.filter((r) => r.state === 'running').length;
  const stopped = rows.filter((r) => r.state === 'stopped').length;
  const total = (cost.data ?? []).reduce((a, c) => a + Number(c.cost_mtd), 0);
  const cpuByRes = new Map((latest.data ?? []).filter((m) => m.metric === 'cpu_percent').map((m) => [m.resource_id, m.value]));
  const hot = rows.filter((r) => (cpuByRes.get(r.resource_id) ?? 0) > 80).length;

  return (
    <Page>
      <PageHeader title="Dashboard" subtitle="Live overview of your cloud resources, spend and alerts" />
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
        <Tile label="Running" value={running} sub={`${rows.length} active resources`} tone="ok" />
        <Tile label="Stopped" value={stopped} tone={stopped ? 'warn' : undefined} sub="instances" />
        <Tile label="Open alerts" value={alerts.data?.length ?? '—'} tone={alerts.data?.length ? 'bad' : 'ok'} sub={alerts.data?.length ? 'need attention' : 'all clear'} />
        <Tile label="Hot instances" value={hot} tone={hot ? 'warn' : undefined} sub="CPU above 80%" />
        <Tile label="Cost month to date" value={money(total)} sub="from allocations × pricing" />
      </div>

      <div className="mt-3 grid gap-3 lg:grid-cols-3">
        <Card title="Cost month to date by project" className="lg:col-span-2">
          <div className="h-56 p-2" role="img" aria-label="Bar chart of month-to-date cost per project">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={(cost.data ?? []).map((c) => ({ name: c.project_name, cost: Number(c.cost_mtd) }))} margin={{ left: -10, right: 8, top: 8 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="#8c98aa33" />
                <XAxis dataKey="name" tick={{ fontSize: 11, fill: '#8c98aa' }} />
                <YAxis tick={{ fontSize: 11, fill: '#8c98aa' }} tickFormatter={(v) => `$${v}`} />
                <Tooltip formatter={(v: number) => money(v)} contentStyle={{ fontSize: 12 }} />
                <Bar dataKey="cost" fill="#2563eb" radius={[3, 3, 0, 0]} isAnimationActive={false} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </Card>
        <Card title="Quota usage">
          <div className="grid gap-2 p-3">
            {(quotas.data ?? []).length === 0 && <p className="text-xs text-muted">No quotas</p>}
            {(quotas.data ?? []).map((q) => (
              <div key={`${q.project_id}-${q.resource_type}`}>
                <div className="flex justify-between text-xs"><span>{q.project_name} · {q.resource_type}</span><span className="tabular-nums text-muted">{q.used_units} / {q.max_units}{q.resource_type === 'storage' ? ' GB' : ''}</span></div>
                <UsageBar used={q.used_units} max={q.max_units} />
              </div>
            ))}
          </div>
        </Card>
      </div>

      <div className="mt-3 grid gap-3 lg:grid-cols-2">
        <Card title="Open alerts" actions={<Link className="text-accent" to="/alerts">All alerts →</Link>}>
          <DataTable rows={alerts.data} loading={alerts.isLoading} empty="No open alerts" pageSize={6} columns={[
            { key: 'resource_name', header: 'Resource' },
            { key: 'metric', header: 'Metric', render: (a: Alert) => metricLabel(a.metric) },
            { key: 'peak_value', header: 'Peak', align: 'right', render: (a: Alert) => num(a.peak_value) },
            { key: 'fired_at', header: 'Fired', render: (a: Alert) => ago(a.fired_at) },
          ]} />
        </Card>
        <Card title="Resources" actions={<Link className="text-accent" to="/resources">All resources →</Link>}>
          <DataTable rows={rows} loading={res.isLoading} pageSize={6} onRowClick={(r) => nav(`/resources/${r.resource_id}`)} columns={[
            { key: 'name', header: 'Name' },
            { key: 'type', header: 'Type' },
            { key: 'project_name', header: 'Project' },
            { key: 'state', header: 'State', render: (r: Res) => <Badge tone={stateTone(r.state)}>{r.state}</Badge> },
            { key: 'cpu', header: 'CPU', align: 'right', value: (r: Res) => cpuByRes.get(r.resource_id) ?? -1, render: (r: Res) => (cpuByRes.has(r.resource_id) ? `${num(cpuByRes.get(r.resource_id))}%` : '—') },
          ]} />
        </Card>
      </div>
    </Page>
  );
}
