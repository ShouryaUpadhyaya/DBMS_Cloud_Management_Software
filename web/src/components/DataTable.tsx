import { ReactNode, useMemo, useState } from 'react';
import { Spinner } from './ui';

export interface Column<T> {
  key: string;
  header: string;
  render?: (row: T) => ReactNode;
  value?: (row: T) => string | number | null | undefined;     // sort + search value; defaults to row[key]
  align?: 'left' | 'right';
  sortable?: boolean;
  className?: string;
}

interface Props<T> {
  columns: Column<T>[];
  rows: T[] | undefined;
  loading?: boolean;
  rowKey?: (row: T, i: number) => string | number;
  onRowClick?: (row: T) => void;
  empty?: string;
  searchable?: boolean;
  initialSort?: { key: string; dir: 'asc' | 'desc' };
  pageSize?: number;
  toolbar?: ReactNode;
  expanded?: (row: T) => ReactNode;          // optional detail row
  isExpanded?: (row: T) => boolean;
}

/** Generic sortable, searchable, paginated table used by every screen. */
export function DataTable<T extends object>({
  columns, rows, loading, rowKey, onRowClick, empty = 'No rows', searchable, initialSort, pageSize = 50, toolbar, expanded, isExpanded,
}: Props<T>) {
  const [sort, setSort] = useState(initialSort ?? null);
  const [q, setQ] = useState('');
  const [page, setPage] = useState(0);

  const val = (c: Column<T>, r: T) => (c.value ? c.value(r) : ((r as Record<string, unknown>)[c.key] as string | number | null | undefined));

  const shown = useMemo(() => {
    let out = rows ?? [];
    if (q.trim()) {
      const needle = q.toLowerCase();
      out = out.filter((r) => columns.some((c) => String(val(c, r) ?? '').toLowerCase().includes(needle)));
    }
    if (sort) {
      const col = columns.find((c) => c.key === sort.key);
      if (col) {
        out = [...out].sort((a, b) => {
          const x = val(col, a); const y = val(col, b);
          const cmp = typeof x === 'number' && typeof y === 'number' ? x - y : String(x ?? '').localeCompare(String(y ?? ''), undefined, { numeric: true });
          return sort.dir === 'asc' ? cmp : -cmp;
        });
      }
    }
    return out;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, q, sort, columns]);

  const pages = Math.max(1, Math.ceil(shown.length / pageSize));
  const cur = Math.min(page, pages - 1);
  const slice = shown.slice(cur * pageSize, cur * pageSize + pageSize);

  const toggle = (c: Column<T>) => {
    if (c.sortable === false) return;
    setSort((s) => (s?.key === c.key ? { key: c.key, dir: s.dir === 'asc' ? 'desc' : 'asc' } : { key: c.key, dir: 'asc' }));
  };

  return (
    <div>
      {(searchable || toolbar) && (
        <div className="flex flex-wrap items-center gap-2 border-b border-line px-3 py-2">
          {searchable && <input className="input max-w-xs" placeholder="Filter rows…" aria-label="Filter rows" value={q} onChange={(e) => { setQ(e.target.value); setPage(0); }} />}
          {toolbar}
          <span className="ml-auto text-xs text-muted">{shown.length} row{shown.length === 1 ? '' : 's'}</span>
        </div>
      )}
      <div className="overflow-x-auto">
        <table className="w-full border-collapse">
          <thead>
            <tr>
              {columns.map((c) => (
                <th key={c.key} scope="col" className={`th ${c.align === 'right' ? 'text-right' : ''} ${c.sortable === false ? '' : 'cursor-pointer select-none'}`}
                    aria-sort={sort?.key === c.key ? (sort.dir === 'asc' ? 'ascending' : 'descending') : undefined} onClick={() => toggle(c)}>
                  {c.header}{sort?.key === c.key ? (sort.dir === 'asc' ? ' ▲' : ' ▼') : ''}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {loading && !rows ? (
              <tr><td className="td" colSpan={columns.length}><Spinner /></td></tr>
            ) : slice.length === 0 ? (
              <tr><td className="td text-muted" colSpan={columns.length}>{empty}</td></tr>
            ) : slice.map((r, i) => (
              <RowGroup key={rowKey ? rowKey(r, i) : i}>
                <tr className={onRowClick ? 'cursor-pointer hover:bg-subtle' : ''} onClick={onRowClick ? () => onRowClick(r) : undefined}>
                  {columns.map((c) => (
                    <td key={c.key} className={`td ${c.align === 'right' ? 'text-right tabular-nums' : ''} ${c.className ?? ''}`}>
                      {c.render ? c.render(r) : String(val(c, r) ?? '—')}
                    </td>
                  ))}
                </tr>
                {expanded && isExpanded?.(r) && <tr><td className="border-b border-line bg-subtle/50 p-0" colSpan={columns.length}>{expanded(r)}</td></tr>}
              </RowGroup>
            ))}
          </tbody>
        </table>
      </div>
      {pages > 1 && (
        <div className="flex items-center justify-end gap-2 border-t border-line px-3 py-1.5 text-xs">
          <button className="btn" disabled={cur === 0} onClick={() => setPage(cur - 1)}>Prev</button>
          <span>Page {cur + 1} / {pages}</span>
          <button className="btn" disabled={cur >= pages - 1} onClick={() => setPage(cur + 1)}>Next</button>
        </div>
      )}
    </div>
  );
}

function RowGroup({ children }: { children: ReactNode }) { return <>{children}</>; }
