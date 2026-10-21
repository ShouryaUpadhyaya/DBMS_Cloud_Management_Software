import { useState } from 'react';
import { Page } from '../components/Layout';
import { DataTable } from '../components/DataTable';
import { JsonDiff } from '../components/JsonDiff';
import { Badge, Card, ErrorBox, PageHeader } from '../components/ui';
import { useView } from '../lib/hooks';
import { dateTime } from '../lib/format';

interface Audit { audit_id: number; actor_id: number | null; actor_name: string | null; table_name: string; op: string; row_pk: string; old_data: Record<string, unknown> | null; new_data: Record<string, unknown> | null; at: string }

const TABLES = ['resources', 'quotas', 'project_members', 'pricing_plans', 'invoices'];

export function Audit() {
  const [table, setTable] = useState('');
  const [op, setOp] = useState('');
  const [limit, setLimit] = useState(100);
  const [open, setOpen] = useState<number | null>(null);
  const { data, isLoading, error } = useView<Audit>('v_audit_log', { table_name: table, op, limit }, { refresh: 30 });

  return (
    <Page>
      <PageHeader title="Audit log" subtitle="Written by one generic trigger (to_jsonb(OLD/NEW)); append-only — trg_audit_immutable rejects UPDATE, DELETE and TRUNCATE. Admins see all, others their own actions." />
      <Card>
        <ErrorBox error={error} />
        <DataTable rows={data} loading={isLoading} rowKey={(a) => a.audit_id} searchable pageSize={20} onRowClick={(a) => setOpen(open === a.audit_id ? null : a.audit_id)}
          isExpanded={(a) => open === a.audit_id} expanded={(a) => <JsonDiff oldData={a.old_data} newData={a.new_data} />}
          toolbar={<>
            <select className="input w-40" aria-label="Table" value={table} onChange={(e) => setTable(e.target.value)}><option value="">All tables</option>{TABLES.map((t) => <option key={t}>{t}</option>)}</select>
            <select className="input w-32" aria-label="Operation" value={op} onChange={(e) => setOp(e.target.value)}><option value="">All ops</option><option>INSERT</option><option>UPDATE</option><option>DELETE</option></select>
          </>}
          columns={[
            { key: 'audit_id', header: '#', align: 'right' },
            { key: 'at', header: 'When', render: (a: Audit) => dateTime(a.at) },
            { key: 'actor_name', header: 'Actor', render: (a: Audit) => a.actor_name ?? <span className="text-muted">system</span> },
            { key: 'table_name', header: 'Table' },
            { key: 'op', header: 'Op', render: (a: Audit) => <Badge tone={a.op === 'INSERT' ? 'ok' : a.op === 'DELETE' ? 'bad' : 'info'}>{a.op}</Badge> },
            { key: 'row_pk', header: 'Row key', className: 'mono' },
            { key: 'changed', header: 'Changed fields', sortable: false, value: (a: Audit) => changed(a), render: (a: Audit) => <span className="text-xs text-muted">{changed(a)}</span> },
          ]} />
        <div className="flex justify-end border-t border-line px-3 py-2">{(data?.length ?? 0) >= limit && <button className="btn" onClick={() => setLimit(limit + 100)}>Load older</button>}</div>
      </Card>
    </Page>
  );
}

function changed(a: Audit): string {
  if (a.op !== 'UPDATE' || !a.old_data || !a.new_data) return a.op === 'INSERT' ? 'new row' : 'row removed';
  return Object.keys(a.new_data).filter((k) => JSON.stringify(a.old_data![k]) !== JSON.stringify(a.new_data![k]) && k !== 'updated_at').join(', ') || '—';
}
