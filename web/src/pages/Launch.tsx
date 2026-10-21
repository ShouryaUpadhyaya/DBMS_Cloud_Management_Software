import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Page } from '../components/Layout';
import { Field } from '../components/ProcedureForm';
import { Badge, Card, PageHeader, UsageBar } from '../components/ui';
import { ApiError } from '../lib/api';
import { useProcedure, useView } from '../lib/hooks';
import { useProject } from '../lib/project';
import { Res } from './Resources';

interface Quota { project_id: number; resource_type: string; max_units: number; used_units: number }
type Kind = 'vm' | 'volume' | 'network';

const KINDS: { id: Kind; title: string; blurb: string; proc: string; quota: string }[] = [
  { id: 'vm', title: 'Virtual machine', blurb: 'Compute instance with vCPUs, memory and an address on one of your networks.', proc: 'sp_provision_vm', quota: 'compute' },
  { id: 'volume', title: 'Storage volume', blurb: 'Block storage billed per GB-hour.', proc: 'sp_create_volume', quota: 'storage' },
  { id: 'network', title: 'Network', blurb: 'Private network with a CIDR block.', proc: 'sp_create_network', quota: 'network' },
];

/** Three-step wizard: pick a kind, fill parameters (quota shown live), review and submit to the stored procedure. */
export function Launch() {
  const { projects, projectId } = useProject();
  const [step, setStep] = useState(1);
  const [kind, setKind] = useState<Kind>('vm');
  const [project, setProject] = useState<number | null>(projectId);
  const [done, setDone] = useState<number | null>(null);
  const [values, setValues] = useState<Record<string, string>>({});
  const create = useProcedure<number>(KINDS.find((x) => x.id === kind)!.proc);
  const pid = project ?? projectId ?? projects[0]?.project_id ?? null;
  const k = KINDS.find((x) => x.id === kind)!;
  const quotas = useView<Quota>('v_quota_usage', pid ? { project_id: pid } : undefined, { enabled: pid !== null });
  const nets = useView<Res>('v_active_resources', { project_id: pid ?? undefined, type: 'network' }, { enabled: pid !== null });
  const q = quotas.data?.find((x) => x.resource_type === k.quota);

  const fields: Field[] = useMemo(() => {
    if (kind === 'vm') return [
      { name: 'name', label: 'Name', placeholder: 'web-3', width: 'w-full' },
      { name: 'vcpus', label: 'vCPUs', type: 'number', defaultValue: 2, min: 1, max: 64 },
      { name: 'memory_mb', label: 'Memory (MB)', type: 'number', defaultValue: 2048, min: 128, step: 128 },
      { name: 'network_id', label: 'Network', type: 'select', options: (nets.data ?? []).map((n) => ({ value: n.resource_id, label: `${n.name} (${n.cidr})` })), defaultValue: nets.data?.[0]?.resource_id, help: nets.data?.length === 0 ? 'Create a network first' : undefined },
      { name: 'image', label: 'Image', defaultValue: 'ubuntu:24.04' },
    ];
    if (kind === 'volume') return [
      { name: 'name', label: 'Name', placeholder: 'backups' },
      { name: 'size_gb', label: 'Size (GB)', type: 'number', defaultValue: 10, min: 1 },
      { name: 'mount_path', label: 'Mount path', optional: true, placeholder: '/mnt/data' },
    ];
    return [
      { name: 'name', label: 'Name', placeholder: 'app-net' },
      { name: 'cidr', label: 'CIDR', placeholder: '10.20.0.0/24', help: 'Must not overlap another network of the project' },
    ];
  }, [kind, nets.data]);

  const err = create.error;
  const fieldErrors: Record<string, string> = err instanceof ApiError ? err.fields : {};
  const hasFieldErrors = Object.keys(fieldErrors).some((f) => fields.some((x) => x.name === f));

  const submit = () => {
    const body: Record<string, unknown> = { project_id: pid };
    for (const f of fields) {
      const raw = values[f.name] ?? String(f.defaultValue ?? '');
      if (raw === '' && f.optional) continue;
      body[f.name] = f.type === 'number' || f.name === 'network_id' ? Number(raw) : raw;
    }
    create.mutate(body, { onSuccess: (r) => setDone(Number(r.result)), onError: (e) => { if (e instanceof ApiError && Object.keys(e.fields).length) setStep(2); } });
  };

  return (
    <Page>
      <PageHeader title="Launch a resource" subtitle="Calls a stored procedure: the quota row is locked, the resource, subtype, address and allocation are inserted in one transaction" />
      <ol className="mb-3 flex gap-2 text-xs" aria-label="Steps">
        {['Choose type', 'Configure', 'Review'].map((s, i) => <li key={s}><Badge tone={step === i + 1 ? 'info' : step > i + 1 ? 'ok' : 'neutral'}>{i + 1}. {s}</Badge></li>)}
      </ol>

      {step === 1 && (
        <div className="grid gap-3 md:grid-cols-3">
          {KINDS.map((x) => (
            <button key={x.id} className={`card p-4 text-left hover:border-accent ${kind === x.id ? 'border-accent ring-1 ring-accent' : ''}`} onClick={() => { setKind(x.id); setStep(2); }}>
              <div className="font-semibold">{x.title}</div><p className="mt-1 text-xs text-muted">{x.blurb}</p>
            </button>
          ))}
        </div>
      )}

      {step >= 2 && (
        <div className="grid gap-3 lg:grid-cols-3">
          <Card title={`${k.title} · ${step === 2 ? 'configure' : 'review'}`} className="lg:col-span-2">
            <div className="grid gap-3 p-3">
              <div className="max-w-xs"><label className="label" htmlFor="project">Project</label>
                <select id="project" className="input" value={pid ?? ''} disabled={step === 3} onChange={(e) => setProject(Number(e.target.value))}>
                  {projects.map((p) => <option key={p.project_id} value={p.project_id}>{p.name} ({p.my_role})</option>)}
                </select>
              </div>
              {done !== null ? (
                <div className="rounded border border-ok/40 bg-ok/10 p-3 text-ok" role="status">
                  Created resource #{done}. <Link className="underline" to={`/resources/${done}`}>Open it →</Link>{' '}
                  <button className="btn ml-2" onClick={() => { setDone(null); setValues({}); create.reset(); setStep(1); }}>Launch another</button>
                </div>
              ) : step === 2 ? (
                <>
                  <div className="grid gap-3 sm:grid-cols-2">
                    {fields.map((f) => {
                      const id = `launch-${f.name}`;
                      const val = values[f.name] ?? String(f.defaultValue ?? '');
                      const fe = fieldErrors[f.name];
                      return (
                        <div key={f.name}>
                          <label className="label" htmlFor={id}>{f.label}</label>
                          {f.type === 'select' ? (
                            <select id={id} className="input" value={val} onChange={(e) => setValues({ ...values, [f.name]: e.target.value })}>
                              {(f.options ?? []).map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                            </select>
                          ) : (
                            <input id={id} className={`input ${fe ? 'border-bad' : ''}`} type={f.type === 'number' ? 'number' : 'text'} value={val} placeholder={f.placeholder}
                                   min={f.min} max={f.max} step={f.step} aria-invalid={!!fe} onChange={(e) => setValues({ ...values, [f.name]: e.target.value })} />
                          )}
                          {fe ? <p className="mt-0.5 text-xs text-bad">{fe}</p> : f.help && <p className="mt-0.5 text-xs text-muted">{f.help}</p>}
                        </div>
                      );
                    })}
                  </div>
                  <div className="flex gap-2"><button className="btn" onClick={() => setStep(1)}>Back</button><button className="btn btn-primary" onClick={() => { create.reset(); setStep(3); }}>Review</button></div>
                </>
              ) : (
                <>
                  <table className="w-full text-sm" aria-label="Review">
                    <tbody>
                      <tr><td className="td text-muted">Project</td><td className="td">{projects.find((p) => p.project_id === pid)?.name}</td></tr>
                      {fields.map((f) => {
                        const raw = values[f.name] ?? String(f.defaultValue ?? '');
                        const label = f.type === 'select' ? f.options?.find((o) => String(o.value) === raw)?.label ?? raw : raw;
                        return <tr key={f.name}><td className="td text-muted">{f.label}</td><td className="td">{label || '—'}</td></tr>;
                      })}
                    </tbody>
                  </table>
                  {create.error && !hasFieldErrors && <div role="alert" className="rounded border border-bad/40 bg-bad/10 px-3 py-2 text-sm text-bad">{(create.error as Error).message}</div>}
                  <div className="flex gap-2">
                    <button className="btn" onClick={() => setStep(2)}>Back</button>
                    <button className="btn btn-primary" disabled={create.isPending} onClick={submit}>{create.isPending ? 'Launching…' : `Launch ${k.title.toLowerCase()}`}</button>
                  </div>
                </>
              )}
            </div>
          </Card>
          <Card title="Quota">
            <div className="p-3 text-sm">
              {q ? (<>
                <div className="mb-1 flex justify-between"><span>{k.quota}</span><span className="tabular-nums">{q.used_units} / {q.max_units}{k.quota === 'storage' ? ' GB' : ''}</span></div>
                <UsageBar used={q.used_units} max={q.max_units} />
                <p className="mt-2 text-xs text-muted">{q.used_units >= q.max_units ? 'The quota is exhausted: the procedure will refuse with “Quota exceeded”.' : 'Enforced inside the procedure with SELECT … FOR UPDATE on this quota row.'}</p>
              </>) : <p className="text-xs text-muted">No quota loaded</p>}
            </div>
          </Card>
        </div>
      )}
    </Page>
  );
}
