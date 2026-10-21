import { diffJson } from '../lib/format';

const show = (v: unknown) => (typeof v === 'string' ? v : JSON.stringify(v));

/** Side-by-side key diff of an audit row's old_data and new_data. */
export function JsonDiff({ oldData, newData, showSame = false }: { oldData: Record<string, unknown> | null; newData: Record<string, unknown> | null; showSame?: boolean }) {
  const rows = diffJson(oldData, newData).filter((r) => showSame || r.kind !== 'same');
  if (rows.length === 0) return <p className="px-3 py-2 text-xs text-muted">No differences</p>;
  return (
    <table className="mono w-full" aria-label="JSON diff">
      <thead><tr><th className="th w-1/4">Field</th><th className="th">Before</th><th className="th">After</th></tr></thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.key}>
            <td className="td font-semibold">{r.key}</td>
            <td className={`td whitespace-pre-wrap break-all ${r.kind === 'removed' || r.kind === 'changed' ? 'bg-bad/10 text-bad' : 'text-muted'}`}>
              {r.kind === 'added' ? '' : `${r.kind === 'changed' || r.kind === 'removed' ? '− ' : ''}${show(r.before)}`}
            </td>
            <td className={`td whitespace-pre-wrap break-all ${r.kind === 'added' || r.kind === 'changed' ? 'bg-ok/10 text-ok' : 'text-muted'}`}>
              {r.kind === 'removed' ? '' : `${r.kind === 'changed' || r.kind === 'added' ? '+ ' : ''}${show(r.after)}`}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
