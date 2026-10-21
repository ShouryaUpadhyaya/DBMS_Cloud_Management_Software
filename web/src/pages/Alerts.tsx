import { Page } from '../components/Layout';
import { DataTable } from '../components/DataTable';
import { Field, ProcedureForm } from '../components/ProcedureForm';
import { Badge, Card, PageHeader } from '../components/ui';
import { atLeast } from '../lib/api';
import { useAuth } from '../lib/auth';
import { useProcedure, useView } from '../lib/hooks';
import { useProject } from '../lib/project';
import { dateTime, metricLabel, metricUnit, num } from '../lib/format';

interface Open { event_id: number; rule_id: number; resource_id: number; resource_name: string; project_name: string; metric: string; operator: string; threshold: number; fired_at: string; peak_value: number }
interface Hist extends Open { resolved_at: string | null }
interface Rule { rule_id: number; project_id: number; project_name: string; metric: string; operator: string; threshold: number; window_seconds: number }

export function Alerts() {
  const { projectId, projects } = useProject();
  const { user } = useAuth();
  const p = projectId ? { project_id: projectId } : undefined;
  const open = useView<Open>('v_open_alerts', p, { refresh: 15 });
  const hist = useView<Hist>('v_alert_history', { ...p, limit: 100 }, { refresh: 30 });
  const rules = useView<Rule>('v_alert_rules', p);
  const del = useProcedure('sp_delete_alert_rule');
  const canCreate = user && atLeast(user.role, 'developer');
  const canDelete = user && atLeast(user.role, 'manager');
  const target = projectId ?? projects[0]?.project_id;

  const fields: Field[] = [
    { name: 'project_id', label: 'Project', type: 'select', defaultValue: target, options: projects.map((x) => ({ value: x.project_id, label: x.name })) },
    { name: 'metric', label: 'Metric', type: 'select', defaultValue: 'cpu_percent', options: ['cpu_percent', 'mem_percent', 'net_kbps', 'disk_percent'].map((m) => ({ value: m, label: metricLabel(m) })) },
    { name: 'operator', label: 'Operator', type: 'select', defaultValue: '>', options: ['>', '>=', '<', '<='].map((o) => ({ value: o, label: o })) },
    { name: 'threshold', label: 'Threshold', type: 'number', defaultValue: 80, step: 1 },
    { name: 'window_seconds', label: 'Window (s)', type: 'number', defaultValue: 300, min: 1 },
  ];

  return (
    <Page>
      <PageHeader title="Alerts" subtitle="trg_metric_alert compares the windowed average with each rule, opens or resolves events and NOTIFYs the live stream" />
      <div className="grid gap-3">
        <Card title={`Open alerts (${open.data?.length ?? 0})`}>
          <DataTable rows={open.data} loading={open.isLoading} empty="No open alerts — all clear" rowKey={(a) => a.event_id} columns={[
            { key: 'resource_name', header: 'Resource' }, { key: 'project_name', header: 'Project' },
            { key: 'metric', header: 'Rule', render: (a: Open) => `${metricLabel(a.metric)} ${a.operator} ${a.threshold}${metricUnit(a.metric)}` },
            { key: 'peak_value', header: 'Peak', align: 'right', render: (a: Open) => num(a.peak_value) },
            { key: 'fired_at', header: 'Fired', render: (a: Open) => dateTime(a.fired_at) },
            { key: 'state', header: '', sortable: false, render: () => <Badge tone="bad">open</Badge> },
          ]} />
        </Card>
        <div className="grid gap-3 lg:grid-cols-2">
          <Card title="Alert rules">
            <DataTable rows={rules.data} loading={rules.isLoading} empty="No rules" pageSize={8} columns={[
              { key: 'project_name', header: 'Project' },
              { key: 'metric', header: 'Condition', render: (r: Rule) => `${metricLabel(r.metric)} ${r.operator} ${r.threshold}${metricUnit(r.metric)} over ${r.window_seconds}s` },
              { key: 'del', header: '', sortable: false, render: (r: Rule) => canDelete ? <button className="btn btn-danger" onClick={() => { if (window.confirm('Delete this rule?')) del.mutate({ rule_id: r.rule_id }); }}>Delete</button> : null },
            ]} />
            {del.error && <p className="px-3 pb-2 text-xs text-bad">{(del.error as Error).message}</p>}
          </Card>
          {canCreate && (
            <Card title="New alert rule"><div className="p-3"><ProcedureForm key={target} procedure="sp_create_alert_rule" fields={fields} submitLabel="Create rule" successMessage={() => 'Rule created'} /></div></Card>
          )}
        </div>
        <Card title="History">
          <DataTable rows={hist.data} loading={hist.isLoading} pageSize={10} rowKey={(a) => a.event_id} initialSort={{ key: 'fired_at', dir: 'desc' }} columns={[
            { key: 'resource_name', header: 'Resource' }, { key: 'metric', header: 'Metric', render: (a: Hist) => metricLabel(a.metric) },
            { key: 'fired_at', header: 'Fired', render: (a: Hist) => dateTime(a.fired_at) },
            { key: 'resolved_at', header: 'Resolved', render: (a: Hist) => (a.resolved_at ? dateTime(a.resolved_at) : <Badge tone="bad">open</Badge>) },
            { key: 'peak_value', header: 'Peak', align: 'right', render: (a: Hist) => num(a.peak_value) },
          ]} />
        </Card>
      </div>
    </Page>
  );
}
