export type ResourceKind = 'compute' | 'storage' | 'network';

export interface ResourceSnapshot {
  external_id: string;
  type: ResourceKind;
  name: string;
  state: 'running' | 'stopped';
  project?: string;
  vcpus?: number;
  memory_mb?: number;
  image?: string;
  size_gb?: number;
  mount_path?: string;
  cidr?: string;
}

export interface MetricPoint {
  external_id: string;
  ts: string;
  metric: 'cpu_percent' | 'mem_percent' | 'net_kbps' | 'disk_percent';
  value: number;
}

export interface LogLine {
  external_id: string;
  ts: string;
  level: 'debug' | 'info' | 'warn' | 'error';
  message: string;
  attrs: Record<string, unknown>;
}

export interface Sample {
  node: { hostname: string; region: string };
  resources: ResourceSnapshot[];
  metrics: MetricPoint[];
  logs: LogLine[];
}

/** A source produces one sample per tick; mock and docker modes implement it. */
export interface Source {
  sample(now: Date): Promise<Sample>;
}
