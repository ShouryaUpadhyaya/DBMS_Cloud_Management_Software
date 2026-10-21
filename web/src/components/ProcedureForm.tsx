import { FormEvent, ReactNode, useState } from 'react';
import { ApiError } from '../lib/api';
import { useProcedure } from '../lib/hooks';

export interface Field {
  name: string;
  label: string;
  type?: 'text' | 'number' | 'select' | 'datetime' | 'hidden';
  options?: { value: string | number; label: string }[];
  defaultValue?: string | number;
  placeholder?: string;
  help?: string;
  min?: number;
  max?: number;
  step?: number;
  optional?: boolean;
  width?: string;
}

interface Props {
  procedure: string;
  fields: Field[];
  submitLabel: string;
  /** values merged into the request (e.g. ids chosen elsewhere on the page) */
  fixed?: Record<string, unknown>;
  confirm?: string;
  danger?: boolean;
  inline?: boolean;
  onSuccess?: (result: { result?: unknown; rows?: Record<string, unknown>[] }) => void;
  successMessage?: (result: { result?: unknown; rows?: Record<string, unknown>[] }) => ReactNode;
}

/**
 * Generic form for any registry procedure. The API's field-level errors (zod 400, constraint 409)
 * are shown under the matching input; other errors (e.g. "Quota exceeded: 6 of 6 VMs used") appear as a banner.
 */
export function ProcedureForm({ procedure, fields, submitLabel, fixed = {}, confirm, danger, inline, onSuccess, successMessage }: Props) {
  const mutation = useProcedure(procedure);
  const [values, setValues] = useState<Record<string, string>>(() => Object.fromEntries(fields.map((f) => [f.name, String(f.defaultValue ?? '')])));
  const [ok, setOk] = useState<ReactNode>(null);
  const err = mutation.error as ApiError | null;
  const fieldErrors = err instanceof ApiError ? err.fields : {};
  const bannerError = err && !Object.keys(fieldErrors).some((k) => fields.some((f) => f.name === k)) ? err.message : null;

  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (confirm && !window.confirm(confirm)) return;
    setOk(null);
    const body: Record<string, unknown> = { ...fixed };
    for (const f of fields) {
      const raw = values[f.name];
      if (raw === '' && f.optional) continue;
      body[f.name] = f.type === 'number' ? (raw === '' ? undefined : Number(raw)) : raw;
    }
    mutation.mutate(body, {
      onSuccess: (r) => { setOk(successMessage ? successMessage(r) : 'Done'); onSuccess?.(r); },
    });
  };

  return (
    <form onSubmit={submit} className={inline ? 'flex flex-wrap items-end gap-2' : 'grid gap-3'} noValidate>
      {fields.filter((f) => f.type !== 'hidden').map((f) => {
        const id = `${procedure}-${f.name}`;
        const e = fieldErrors[f.name];
        return (
          <div key={f.name} className={f.width}>
            <label className="label" htmlFor={id}>{f.label}</label>
            {f.type === 'select' ? (
              <select id={id} className="input" value={values[f.name]} onChange={(ev) => setValues({ ...values, [f.name]: ev.target.value })} aria-invalid={!!e}>
                {(f.optional ? [{ value: '', label: '—' }] : []).concat((f.options ?? []) as never[]).map((o: { value: string | number; label: string }) => <option key={String(o.value)} value={o.value}>{o.label}</option>)}
              </select>
            ) : (
              <input id={id} className={`input ${e ? 'border-bad' : ''}`} type={f.type === 'number' ? 'number' : f.type === 'datetime' ? 'datetime-local' : 'text'}
                     value={values[f.name]} placeholder={f.placeholder} min={f.min} max={f.max} step={f.step}
                     onChange={(ev) => setValues({ ...values, [f.name]: ev.target.value })} aria-invalid={!!e} aria-describedby={e ? `${id}-err` : undefined} />
            )}
            {f.help && !e && <p className="mt-0.5 text-xs text-muted">{f.help}</p>}
            {e && <p id={`${id}-err`} className="mt-0.5 text-xs text-bad">{e}</p>}
          </div>
        );
      })}
      <div className="flex items-center gap-3">
        <button type="submit" className={`btn ${danger ? 'btn-danger' : 'btn-primary'}`} disabled={mutation.isPending}>{mutation.isPending ? 'Working…' : submitLabel}</button>
        {ok && <span className="text-xs text-ok" role="status">{ok}</span>}
      </div>
      {bannerError && <div role="alert" className="w-full rounded border border-bad/40 bg-bad/10 px-3 py-2 text-sm text-bad">{bannerError}</div>}
    </form>
  );
}
