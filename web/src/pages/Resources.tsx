import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Page } from '../components/Layout';
import { DataTable } from '../components/DataTable';
import { Badge, Card, ErrorBox, PageHeader, stateTone } from '../components/ui';
import { atLeast } from '../lib/api';
import { useAuth } from '../lib/auth';
import { useProcedure, useView } from '../lib/hooks';
import { useProject } from '../lib/project';

export interface Res {
  resource_id: number; project_id: number; project_name: string; type: string; name: string; state: string; source: string;
  node: string | null; vcpus: number | null; memory_mb: number | null; image: string | null; size_gb: number | null; mount_path: string | null;
  cidr: string | null; ips: string | null; created_at: string; external_id: string | null;
}

export const spec = (r: Res): string =>
  r.type === 'compute' ? `${r.vcpus} vCPU · ${r.memory_mb} MB${r.image ? ` · ${r.image}` : ''}` : r.type === 'storage' ? `${r.size_gb} GB${r.mount_path ? ` · ${r.mount_path}` : ''}` : (r.cidr ?? '');

export function Resources() {
  const { projectId } = useProject();
  const { user } = useAuth();
  const nav = useNavigate();
  const [type, setType] = useState('');
  const [state, setState] = useState('');
  const { data, isLoading, error } = useView<Res>('v_active_resources', { project_id: projectId ?? undefined, type, state, limit: 1000 }, { refresh: 30 });
  const setStateProc = useProcedure('sp_set_resource_state');
  const canOperate = user && atLeast(user.role, 'developer');

  return (
    <Page>
      <PageHeader title="Resources" subtitle="Compute instances, volumes and networks (v_active_resources joins the supertype with every subtype)"
        actions={canOperate && <Link className="btn btn-primary" to="/launch">＋ Launch resource</Link>} />
      <Card>
        <ErrorBox error={error ?? setStateProc.error} />
        <DataTable rows={data} loading={isLoading} searchable rowKey={(r) => r.resource_id} onRowClick={(r) => nav(`/resources/${r.resource_id}`)}
          initialSort={{ key: 'project_name', dir: 'asc' }}
          toolbar={<>
            <select className="input w-32" aria-label="Type" value={type} onChange={(e) => setType(e.target.value)}><option value="">All types</option><option>compute</option><option>storage</option><option>network</option></select>
            <select className="input w-32" aria-label="State" value={state} onChange={(e) => setState(e.target.value)}><option value="">All states</option><option>running</option><option>stopped</option><option>pending</option></select>
          </>}
          columns={[
            { key: 'name', header: 'Name', render: (r: Res) => <span className="font-medium">{r.name}</span> },
            { key: 'type', header: 'Type' },
            { key: 'project_name', header: 'Project' },
            { key: 'state', header: 'State', render: (r: Res) => <Badge tone={stateTone(r.state)}>{r.state}</Badge> },
            { key: 'spec', header: 'Spec', value: spec },
            { key: 'ips', header: 'IP', className: 'mono' },
            { key: 'source', header: 'Source', render: (r: Res) => <Badge>{r.source}</Badge> },
            { key: 'node', header: 'Node' },
            { key: 'actions', header: '', sortable: false, render: (r: Res) => r.type === 'compute' && canOperate ? (
              <button className="btn" onClick={(e) => { e.stopPropagation(); setStateProc.mutate({ resource_id: r.resource_id, state: r.state === 'running' ? 'stopped' : 'running' }); }}>
                {r.state === 'running' ? 'Stop' : 'Start'}
              </button>) : null },
          ]} />
      </Card>
    </Page>
  );
}
