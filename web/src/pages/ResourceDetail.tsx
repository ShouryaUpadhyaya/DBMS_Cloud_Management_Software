import { useNavigate, useParams, Link } from 'react-router-dom';
import { Page } from '../components/Layout';
import { DataTable } from '../components/DataTable';
import { MetricChart } from '../components/MetricChart';
import { Badge, Card, ErrorBox, levelTone, PageHeader, Spinner, stateTone } from '../components/ui';
import { atLeast } from '../lib/api';
import { useAuth } from '../lib/auth';
import { useProcedure, useView } from '../lib/hooks';
import { dateTime, metricLabel, num, shortDate } from '../lib/format';
import { Res, spec } from './Resources';
import { useState } from 'react';

interface Log { log_id: number; ts: string; level: string; message: string }
interface Hist { event_id: number; metric: string; fired_at: string; resolved_at: string | null; peak_value: number }
interface Daily { day: string; metric: string; avg_value: number; max_value: number }

export function ResourceDetail() {
  const id = Number(useParams().id);
  const nav = useNavigate();
  const { user } = useAuth();
  const [hours, setHours] = useState(6);
  const { data, isLoading, error } = useView<Res>('v_active_resources', { resource_id: id });
  const logs = useView<Log>('v_logs', { resource_id: id, limit: 15 }, { refresh: 30 });
  const hist = useView<Hist>('v_alert_history', { resource_id: id, limit: 10 });
  const daily = useView<Daily>('v_daily_usage', { resource_id: id, metric: 'cpu_percent', limit: 60 });
  const setState = useProcedure('sp_set_resource_state');
  const terminate = useProcedure('sp_terminate_resource');
  const r = data?.[0];
  const canOperate = user && atLeast(user.role, 'developer');
  const canTerminate = user && atLeast(user.role, 'manager');

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  if (!r) return <Page><PageHeader title="Resource not found" subtitle="It may have been terminated, or you may not have access." /><Link className="btn" to="/resources">Back to resources</Link></Page>;

  const metrics = r.type === 'compute' ? ['cpu_percent', 'mem_percent', 'net_kbps'] : r.type === 'storage' ? ['disk_percent'] : [];

  return (
    <Page>
      <PageHeader title={r.name} subtitle={<><Badge tone={stateTone(r.state)}>{r.state}</Badge> {r.type} · {r.project_name} · {spec(r)}</>}
        actions={<>
          {canOperate && r.type === 'compute' && (
            <button className="btn" disabled={setState.isPending} onClick={() => setState.mutate({ resource_id: r.resource_id, state: r.state === 'running' ? 'stopped' : 'running' })}>{r.state === 'running' ? 'Stop' : 'Start'}</button>)}
          {canTerminate && (
            <button className="btn btn-danger" disabled={terminate.isPending} onClick={() => { if (window.confirm(`Terminate ${r.name}? This is final.`)) terminate.mutate({ resource_id: r.resource_id }, { onSuccess: () => nav('/resources') }); }}>Terminate</button>)}
        </>} />
      <ErrorBox error={setState.error ?? terminate.error} />

      <div className="grid gap-3 lg:grid-cols-3">
        <Card title="Details">
          <dl className="grid grid-cols-[7rem_1fr] gap-y-1 p-3 text-sm">
            {([['ID', r.resource_id], ['Project', r.project_name], ['Type', r.type], ['Source', r.source], ['Node', r.node], ['IP address', r.ips], ['Network', r.cidr], ['Image', r.image], ['Mount', r.mount_path], ['External id', r.external_id], ['Created', dateTime(r.created_at)]] as [string, unknown][])
              .filter(([, v]) => v !== null && v !== undefined && v !== '').map(([k, v]) => (<div key={k} className="contents"><dt className="text-muted">{k}</dt><dd className="break-all">{String(v)}</dd></div>))}
          </dl>
        </Card>
        <Card title="Metrics" className="lg:col-span-2" actions={
          <select className="input w-28" aria-label="Range" value={hours} onChange={(e) => setHours(Number(e.target.value))}>
            <option value={1}>1 hour</option><option value={6}>6 hours</option><option value={24}>24 hours</option><option value={168}>7 days</option><option value={720}>30 days</option>
          </select>}>
          {metrics.length === 0 ? <p className="p-3 text-xs text-muted">Networks do not emit metrics.</p> : (
            <div className="grid gap-4 p-3 md:grid-cols-2">{metrics.map((m) => <MetricChart key={m} resourceId={r.resource_id} metric={m} hours={hours} />)}</div>
          )}
        </Card>
      </div>

      <div className="mt-3 grid gap-3 lg:grid-cols-2">
        <Card title="Recent logs"><DataTable rows={logs.data} loading={logs.isLoading} pageSize={15} columns={[
          { key: 'ts', header: 'Time', render: (l: Log) => dateTime(l.ts) },
          { key: 'level', header: 'Level', render: (l: Log) => <Badge tone={levelTone(l.level)}>{l.level}</Badge> },
          { key: 'message', header: 'Message', className: 'whitespace-normal' },
        ]} empty="No logs" /></Card>
        <div className="grid gap-3">
          <Card title="Alert history"><DataTable rows={hist.data} loading={hist.isLoading} pageSize={5} empty="No alerts for this resource" columns={[
            { key: 'metric', header: 'Metric', render: (h: Hist) => metricLabel(h.metric) },
            { key: 'fired_at', header: 'Fired', render: (h: Hist) => dateTime(h.fired_at) },
            { key: 'resolved_at', header: 'State', render: (h: Hist) => (h.resolved_at ? <Badge tone="ok">resolved</Badge> : <Badge tone="bad">open</Badge>) },
            { key: 'peak_value', header: 'Peak', align: 'right', render: (h: Hist) => num(h.peak_value) },
          ]} /></Card>
          {r.type === 'compute' && (
            <Card title="Daily CPU (materialized view)"><DataTable rows={daily.data} loading={daily.isLoading} pageSize={7} initialSort={{ key: 'day', dir: 'desc' }} columns={[
              { key: 'day', header: 'Day', render: (d: Daily) => shortDate(d.day) },
              { key: 'avg_value', header: 'Avg %', align: 'right', render: (d: Daily) => num(d.avg_value) },
              { key: 'max_value', header: 'Max %', align: 'right', render: (d: Daily) => num(d.max_value) },
            ]} /></Card>
          )}
        </div>
      </div>
    </Page>
  );
}
