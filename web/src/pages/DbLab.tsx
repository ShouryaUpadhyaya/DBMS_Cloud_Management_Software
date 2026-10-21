import { useQuery } from '@tanstack/react-query';
import { Page } from '../components/Layout';
import { DataTable } from '../components/DataTable';
import { SqlCard } from '../components/SqlCard';
import { Card, ErrorBox, PageHeader, Spinner } from '../components/ui';
import { api } from '../lib/api';
import { useAuth } from '../lib/auth';
import { useView } from '../lib/hooks';
import { atLeast } from '../lib/api';

interface Stmt { queryid: number; calls: number; total_ms: string; mean_ms: string; rows: number; query: string }

export function DbLab() {
  const { user } = useAuth();
  const allowed = !!user && atLeast(user.role, 'admin');
  const list = useQuery({ queryKey: ['queries'], queryFn: api.queries, enabled: allowed });
  const stats = useView<Stmt>('v_stat_statements', undefined, { enabled: allowed });

  if (!allowed) return <Page><PageHeader title="DB Lab" subtitle="Restricted to administrators: named queries read base tables through the read-only role." /></Page>;
  return (
    <Page>
      <PageHeader title="DB Lab" subtitle="Ten showcase queries (db/queries/*.sql) executed as crms_readonly, each with its result and EXPLAIN (ANALYZE, FORMAT JSON) plan" />
      {list.isLoading && <Spinner />}
      <ErrorBox error={list.error} />
      <div className="grid gap-3 xl:grid-cols-2">{(list.data ?? []).map((q) => <SqlCard key={q.name} meta={q} />)}</div>
      <Card title="pg_stat_statements: heaviest statements" className="mt-3">
        <DataTable rows={stats.data} loading={stats.isLoading} pageSize={8} rowKey={(s) => s.queryid} columns={[
          { key: 'calls', header: 'Calls', align: 'right' },
          { key: 'total_ms', header: 'Total ms', align: 'right', value: (s: Stmt) => Number(s.total_ms) },
          { key: 'mean_ms', header: 'Mean ms', align: 'right', value: (s: Stmt) => Number(s.mean_ms) },
          { key: 'rows', header: 'Rows', align: 'right' },
          { key: 'query', header: 'Query', className: 'mono max-w-xl truncate' },
        ]} />
      </Card>
    </Page>
  );
}
