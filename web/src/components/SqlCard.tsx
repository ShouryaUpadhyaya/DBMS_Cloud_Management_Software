import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { api, PlanNode, QueryMeta } from '../lib/api';
import { Card, ErrorBox, Spinner } from './ui';
import { DataTable } from './DataTable';

const KEYWORDS = /\b(SELECT|FROM|WHERE|GROUP BY|ORDER BY|HAVING|JOIN|LEFT JOIN|ON|AS|WITH|RECURSIVE|UNION ALL|OVER|PARTITION BY|WINDOW|LIMIT|AND|OR|NOT|EXISTS|IN|FILTER|WITHIN GROUP|LATERAL|ROWS BETWEEN|PRECEDING|AND|USING|CASE|WHEN|THEN|ELSE|END|DESC|ASC|NULLS FIRST|IS NULL|BETWEEN|interval)\b/g;

/** Tiny syntax highlighter: comments, strings, keywords. */
function Sql({ text }: { text: string }) {
  return (
    <pre className="mono overflow-x-auto bg-subtle p-3 leading-relaxed" aria-label="SQL text">
      {text.split('\n').map((line, i) => {
        if (line.trim().startsWith('--')) return <div key={i} className="text-muted">{line}</div>;
        const parts = line.split(/('[^']*')/g);
        return (
          <div key={i}>
            {parts.map((p, j) => p.startsWith("'") ? <span key={j} className="text-ok">{p}</span>
              : p.split(KEYWORDS).map((t, k) => (k % 2 === 1 ? <span key={`${j}-${k}`} className="font-semibold text-accent">{t}</span> : t)))}
          </div>
        );
      })}
    </pre>
  );
}

function PlanTree({ node, depth = 0 }: { node: PlanNode; depth?: number }) {
  const rel = node['Relation Name'] ? ` on ${node['Relation Name']}` : '';
  const idx = node['Index Name'] ? ` using ${node['Index Name']}` : '';
  return (
    <>
      <div className="mono whitespace-pre" style={{ paddingLeft: depth * 16 }}>
        <span className="font-semibold">{node['Node Type']}</span>{rel}{idx}
        <span className="text-muted">  rows={node['Actual Rows'] ?? '?'} time={node['Actual Total Time'] ?? '?'}ms{node['Actual Loops'] && node['Actual Loops'] > 1 ? ` loops=${node['Actual Loops']}` : ''}</span>
      </div>
      {(node.Plans ?? []).map((c, i) => <PlanTree key={i} node={c} depth={depth + 1} />)}
    </>
  );
}

/** DB Lab card: SQL text, the result table and the EXPLAIN (ANALYZE) plan for one named query. */
export function SqlCard({ meta }: { meta: QueryMeta }) {
  const [open, setOpen] = useState(false);
  const [tab, setTab] = useState<'rows' | 'plan'>('rows');
  const { data, isFetching, error, refetch } = useQuery({ queryKey: ['query', meta.name], queryFn: () => api.query(meta.name), enabled: open, staleTime: 60_000 });

  return (
    <Card title={meta.title} actions={<button className="btn" onClick={() => { if (open) void refetch(); else setOpen(true); }}>{open ? 'Re-run' : 'Run'}</button>}>
      <p className="border-b border-line px-3 py-1.5 text-xs text-muted"><span className="font-medium text-fg">{meta.name}</span> · {meta.concept}</p>
      {!open ? <p className="px-3 py-3 text-xs text-muted">Press Run to execute as the read-only role and capture EXPLAIN (ANALYZE, FORMAT JSON).</p> : (
        <>
          {isFetching && !data && <Spinner label="Running" />}
          <ErrorBox error={error} />
          {data && (
            <>
              <Sql text={data.sql} />
              <div className="flex items-center gap-2 border-y border-line px-3 py-1 text-xs">
                <button className={`btn ${tab === 'rows' ? 'btn-primary' : ''}`} onClick={() => setTab('rows')}>Result ({data.row_count})</button>
                <button className={`btn ${tab === 'plan' ? 'btn-primary' : ''}`} onClick={() => setTab('plan')}>Plan</button>
                <span className="ml-auto text-muted">run {data.duration_ms} ms · execution {data.plan[0]?.['Execution Time'] ?? '?'} ms · planning {data.plan[0]?.['Planning Time'] ?? '?'} ms</span>
              </div>
              {tab === 'rows' ? (
                <DataTable rows={data.rows} columns={data.columns.map((c) => ({ key: c, header: c, render: (r: Record<string, unknown>) => cell(r[c]) }))} pageSize={15} />
              ) : (
                <div className="max-h-96 overflow-auto p-3">{data.plan[0] && <PlanTree node={data.plan[0].Plan} />}</div>
              )}
            </>
          )}
        </>
      )}
    </Card>
  );
}

const cell = (v: unknown) => (v === null || v === undefined ? '—' : typeof v === 'object' ? JSON.stringify(v) : String(v));
