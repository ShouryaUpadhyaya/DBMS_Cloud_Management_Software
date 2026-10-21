import { useMemo, useState } from 'react';
import { Page } from '../components/Layout';
import { DataTable } from '../components/DataTable';
import { Field, ProcedureForm } from '../components/ProcedureForm';
import { Badge, Card, PageHeader, UsageBar } from '../components/ui';
import { atLeast } from '../lib/api';
import { useAuth } from '../lib/auth';
import { useProcedure, useView } from '../lib/hooks';
import { useProject } from '../lib/project';

interface Member { project_id: number; project_name: string; user_id: number; user_name: string; email: string; role: string }
interface RoleRow { role_id: number; name: string; parent_name: string | null }
interface Perm { user_id: number; email: string; project_id: number; project_name: string; role: string; action: string; resource_type: string; inherited_from: string }
interface UserRow { user_id: number; name: string; email: string; status: string }
interface Quota { project_id: number; project_name: string; resource_type: string; max_units: number; used_units: number }

export function Access() {
  const { projectId, projects } = useProject();
  const { user } = useAuth();
  const p = projectId ? { project_id: projectId } : undefined;
  const members = useView<Member>('v_project_members', p);
  const roles = useView<RoleRow>('v_roles');
  const users = useView<UserRow>('v_users');
  const quotas = useView<Quota>('v_quota_usage', p);
  const perms = useView<Perm>('v_user_effective_permissions', { ...p, limit: 5000 });
  const remove = useProcedure('sp_remove_member');
  const [who, setWho] = useState('');
  const canManage = user && atLeast(user.role, 'manager');
  const isAdmin = user && atLeast(user.role, 'admin');
  const target = projectId ?? projects[0]?.project_id;

  const matrix = useMemo(() => {
    const rows = (perms.data ?? []).filter((x) => !who || x.email === who);
    const map = new Map<string, { key: string; email: string; project: string; role: string; granted: Map<string, string> }>();
    for (const r of rows) {
      const k = `${r.email}|${r.project_id}`;
      const e = map.get(k) ?? { key: k, email: r.email, project: r.project_name, role: r.role, granted: new Map() };
      e.granted.set(`${r.action}:${r.resource_type}`, r.inherited_from);
      map.set(k, e);
    }
    return [...map.values()];
  }, [perms.data, who]);
  const allPerms = useMemo(() => [...new Set((perms.data ?? []).map((x) => `${x.action}:${x.resource_type}`))].sort(), [perms.data]);

  const addFields: Field[] = [
    { name: 'project_id', label: 'Project', type: 'select', defaultValue: target, options: projects.map((x) => ({ value: x.project_id, label: x.name })) },
    { name: 'user_id', label: 'User', type: 'select', options: (users.data ?? []).filter((u) => u.status === 'active').map((u) => ({ value: u.user_id, label: `${u.name} (${u.email})` })), defaultValue: users.data?.[0]?.user_id },
    { name: 'role', label: 'Role', type: 'select', defaultValue: 'viewer', options: (roles.data ?? []).map((r) => ({ value: r.name, label: r.name })) },
  ];
  const quotaFields: Field[] = [
    { name: 'project_id', label: 'Project', type: 'select', defaultValue: target, options: projects.map((x) => ({ value: x.project_id, label: x.name })) },
    { name: 'type', label: 'Type', type: 'select', defaultValue: 'compute', options: ['compute', 'storage', 'network'].map((t) => ({ value: t, label: t })) },
    { name: 'max_units', label: 'Max units', type: 'number', min: 0, defaultValue: 10 },
  ];

  return (
    <Page>
      <PageHeader title="Access" subtitle="Roles form a hierarchy; fn_has_permission and v_user_effective_permissions walk it with a recursive CTE" />
      <div className="grid gap-3 lg:grid-cols-3">
        <Card title="Project members" className="lg:col-span-2">
          <DataTable rows={members.data} loading={members.isLoading} searchable pageSize={8} rowKey={(m) => `${m.project_id}-${m.user_id}`} columns={[
            { key: 'user_name', header: 'User', render: (m: Member) => <><span className="font-medium">{m.user_name}</span> <span className="text-muted">{m.email}</span></> , value: (m: Member) => `${m.user_name} ${m.email}` },
            { key: 'project_name', header: 'Project' },
            { key: 'role', header: 'Role', render: (m: Member) => <Badge tone={m.role === 'admin' ? 'bad' : m.role === 'manager' ? 'warn' : m.role === 'developer' ? 'info' : 'neutral'}>{m.role}</Badge> },
            { key: 'rm', header: '', sortable: false, render: (m: Member) => canManage ? <button className="btn btn-danger" onClick={() => { if (window.confirm(`Remove ${m.user_name} from ${m.project_name}?`)) remove.mutate({ project_id: m.project_id, user_id: m.user_id }); }}>Remove</button> : null },
          ]} />
          {remove.error && <p className="px-3 pb-2 text-xs text-bad" role="alert">{(remove.error as Error).message}</p>}
        </Card>
        <Card title="Role hierarchy">
          <ul className="p-3 text-sm">
            {[...(roles.data ?? [])].sort((a, b) => depth(a, roles.data ?? []) - depth(b, roles.data ?? [])).map((r) => (
              <li key={r.role_id} style={{ paddingLeft: depth(r, roles.data ?? []) * 16 }} className="py-0.5"><Badge tone="info">{r.name}</Badge>{r.parent_name && <span className="ml-2 text-xs text-muted">inherits {r.parent_name}</span>}</li>
            ))}
          </ul>
          <p className="border-t border-line px-3 py-2 text-xs text-muted">admin → manager → developer → viewer: each role also holds every permission of the role it inherits from.</p>
        </Card>
      </div>

      <div className="mt-3 grid gap-3 lg:grid-cols-2">
        {canManage && <Card title="Add or change a member"><div className="p-3"><ProcedureForm key={target} procedure="sp_add_member" fields={addFields} submitLabel="Save member" successMessage={() => 'Member saved'} /></div></Card>}
        <Card title="Quotas">
          <div className="grid gap-2 p-3">
            {(quotas.data ?? []).map((q) => (
              <div key={`${q.project_id}-${q.resource_type}`}><div className="flex justify-between text-xs"><span>{q.project_name} · {q.resource_type}</span><span className="tabular-nums text-muted">{q.used_units} / {q.max_units}</span></div><UsageBar used={q.used_units} max={q.max_units} /></div>
            ))}
          </div>
          {isAdmin && <div className="border-t border-line p-3"><ProcedureForm inline key={target} procedure="sp_set_quota" fields={quotaFields} submitLabel="Set quota" successMessage={() => 'Quota updated'} /></div>}
        </Card>
      </div>

      <Card title="Effective permissions" className="mt-3" actions={
        <select className="input w-56" aria-label="User" value={who} onChange={(e) => setWho(e.target.value)}><option value="">All visible users</option>{[...new Set((perms.data ?? []).map((x) => x.email))].map((e) => <option key={e}>{e}</option>)}</select>}>
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-xs">
            <thead><tr><th className="th">User · project</th><th className="th">Role</th>{allPerms.map((a) => <th key={a} className="th" scope="col">{a.replace(':', ' ')}</th>)}</tr></thead>
            <tbody>
              {matrix.length === 0 && <tr><td className="td text-muted" colSpan={allPerms.length + 2}>No data</td></tr>}
              {matrix.map((m) => (
                <tr key={m.key}>
                  <td className="td">{m.email} · {m.project}</td><td className="td">{m.role}</td>
                  {allPerms.map((a) => <td key={a} className="td text-center" title={m.granted.has(a) ? `via ${m.granted.get(a)}` : 'not granted'}>{m.granted.has(a) ? (m.granted.get(a) === m.role ? '●' : '○') : ''}</td>)}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="border-t border-line px-3 py-2 text-xs text-muted">● granted directly by the user's role · ○ inherited from a parent role (hover for the role)</p>
      </Card>
    </Page>
  );
}

function depth(r: RoleRow, all: RoleRow[]): number {
  let d = 0; let cur: RoleRow | undefined = r;
  while (cur?.parent_name) { d += 1; cur = all.find((x) => x.name === cur!.parent_name); }
  return d;
}
