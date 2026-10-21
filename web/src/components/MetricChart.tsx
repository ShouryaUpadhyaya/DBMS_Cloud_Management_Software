import { CartesianGrid, Area, AreaChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { useView } from '../lib/hooks';
import { metricLabel, metricUnit, num } from '../lib/format';
import { Spinner } from './ui';

export const bucketFor = (hours: number): number => (hours <= 1 ? 30 : hours <= 6 ? 60 : hours <= 24 ? 300 : hours <= 168 ? 1800 : 7200);

const isDark = () => document.documentElement.classList.contains('dark');
const COLORS: Record<string, [string, string]> = {
  cpu_percent: ['#2563eb', '#60a5fa'], mem_percent: ['#7c3aed', '#a78bfa'], net_kbps: ['#0d9488', '#2dd4bf'], disk_percent: ['#c2410c', '#fb923c'],
};

interface Point { bucket: string; avg_value: number; max_value: number }

/** Time-series for one resource/metric from the downsampling function fn_metric_series. */
export function MetricChart({ resourceId, metric, hours = 24, height = 160, title }: { resourceId: number; metric: string; hours?: number; height?: number; title?: string }) {
  const from = new Date(Math.floor((Date.now() - hours * 3600_000) / 60_000) * 60_000).toISOString();
  const { data, isLoading, error } = useView<Point>('metric_series', { resource_id: resourceId, metric, from, bucket: bucketFor(hours) }, { refresh: 30 });
  const color = (COLORS[metric] ?? COLORS.cpu_percent)[isDark() ? 1 : 0];
  const unit = metricUnit(metric);
  const short = hours <= 24;
  const fmt = (v: string) => new Date(v).toLocaleString(undefined, short ? { hour: '2-digit', minute: '2-digit' } : { month: 'short', day: 'numeric', hour: '2-digit' });
  const last = data && data.length ? data[data.length - 1].avg_value : null;

  return (
    <div>
      <div className="mb-1 flex items-baseline justify-between text-xs">
        <span className="font-medium">{title ?? metricLabel(metric)}</span>
        <span className="tabular-nums text-muted">{last !== null ? `${num(last, 1)} ${unit}` : ''}</span>
      </div>
      {isLoading ? <Spinner /> : error ? <p className="text-xs text-bad">{(error as Error).message}</p> : !data || data.length === 0 ? (
        <p className="py-6 text-center text-xs text-muted">No data in this range</p>
      ) : (
        <div role="img" aria-label={`${metricLabel(metric)} over the last ${hours} hours`}>
          <ResponsiveContainer width="100%" height={height}>
            <AreaChart data={data} margin={{ top: 4, right: 4, bottom: 0, left: -18 }}>
              <defs>
                <linearGradient id={`g-${resourceId}-${metric}`} x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor={color} stopOpacity={0.35} />
                  <stop offset="100%" stopColor={color} stopOpacity={0.02} />
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" stroke={isDark() ? '#30384488' : '#dadfe788'} />
              <XAxis dataKey="bucket" tickFormatter={fmt} tick={{ fontSize: 10, fill: '#8c98aa' }} minTickGap={40} />
              <YAxis tick={{ fontSize: 10, fill: '#8c98aa' }} domain={unit === '%' ? [0, 100] : [0, 'auto']} />
              <Tooltip labelFormatter={(v) => new Date(String(v)).toLocaleString()} formatter={(v: number) => [`${num(v, 2)} ${unit}`, 'avg']}
                       contentStyle={{ fontSize: 12, background: isDark() ? '#151b23' : '#fff', border: '1px solid #8c98aa55' }} />
              <Area type="monotone" dataKey="avg_value" stroke={color} strokeWidth={1.5} fill={`url(#g-${resourceId}-${metric})`} isAnimationActive={false} />
            </AreaChart>
          </ResponsiveContainer>
        </div>
      )}
    </div>
  );
}
