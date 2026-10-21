import { z, ZodTypeAny } from 'zod';
import type { Role } from './auth.js';

/**
 * Registry pattern: the API holds no business logic. Each public name maps to SQL plus the minimum
 * role allowed to call it. (Fine-grained authorisation is enforced again inside the database.)
 */

type ColType = 'int' | 'text' | 'timestamp' | 'bool';
type FilterKind = 'eq' | 'gte' | 'lte' | 'fts' | 'jsonb';

interface Filter {
  column: string;
  type: ColType;
  kind?: FilterKind;
}

export interface ViewDef {
  kind: 'view';
  minRole: Role;
  from: string;
  order: string;
  filters: Record<string, Filter>;
  defaultLimit?: number;
  maxLimit?: number;
}

export interface CustomViewDef {
  kind: 'custom';
  minRole: Role;
  sql: string;
  schema: z.ZodObject<Record<string, ZodTypeAny>>;
  args: string[];                         // schema keys in $1..$n order
}

export type ReadDef = ViewDef | CustomViewDef;

const v = (from: string, order: string, filters: Record<string, Filter> = {}, minRole: Role = 'viewer', extra: Partial<ViewDef> = {}): ViewDef =>
  ({ kind: 'view', from, order, filters, minRole, ...extra });

const int = (column: string, kind: FilterKind = 'eq'): Filter => ({ column, type: 'int', kind });
const text = (column: string, kind: FilterKind = 'eq'): Filter => ({ column, type: 'text', kind });
const ts = (column: string, kind: FilterKind): Filter => ({ column, type: 'timestamp', kind });

export const views: Record<string, ReadDef> = {
  v_active_resources: v('v_active_resources', 'project_name, type, name', {
    project_id: int('project_id'), resource_id: int('resource_id'), type: text('type'), state: text('state'), source: text('source'),
  }),
  v_project_cost_mtd: v('v_project_cost_mtd', 'cost_mtd DESC, project_name', { project_id: int('project_id') }),
  v_open_alerts: v('v_open_alerts', 'fired_at DESC', { project_id: int('project_id'), resource_id: int('resource_id') }),
  v_alert_history: v('v_alert_history', 'fired_at DESC', {
    project_id: int('project_id'), resource_id: int('resource_id'), since: ts('fired_at', 'gte'),
  }),
  v_alert_rules: v('v_alert_rules', 'project_name, rule_id', { project_id: int('project_id') }),
  v_user_effective_permissions: v('v_user_effective_permissions', 'project_name, email, action, resource_type', {
    user_id: int('user_id'), project_id: int('project_id'), email: text('email'),
  }, 'viewer', { defaultLimit: 1000, maxLimit: 5000 }),
  v_projects: v('v_projects', 'name'),
  v_project_members: v('v_project_members', 'project_name, role, user_name', { project_id: int('project_id'), user_id: int('user_id') }),
  v_users: v('v_users', 'name'),
  v_roles: v('v_roles', 'role_id'),
  v_quota_usage: v('v_quota_usage', 'project_name, resource_type', { project_id: int('project_id') }),
  v_invoices: v('v_invoices', 'period_start DESC, project_name', { project_id: int('project_id'), status: text('status'), invoice_id: int('invoice_id') }),
  v_invoice_lines: v('v_invoice_lines', 'invoice_id, line_no', { invoice_id: int('invoice_id'), project_id: int('project_id') }, 'viewer', { defaultLimit: 1000 }),
  v_billing_cycles: v('v_billing_cycles', 'period_start DESC'),
  v_pricing: v('v_pricing', 'resource_type, effective_from DESC'),
  v_daily_usage: v('v_daily_usage', 'day, resource_name, metric', {
    resource_id: int('resource_id'), project_id: int('project_id'), metric: text('metric'), since: ts('day', 'gte'),
  }, 'viewer', { defaultLimit: 1000, maxLimit: 5000 }),
  v_usage_metrics: v('v_usage_metrics', 'ts DESC', {
    resource_id: int('resource_id'), metric: text('metric'), since: ts('ts', 'gte'), until: ts('ts', 'lte'),
  }, 'viewer', { defaultLimit: 500, maxLimit: 5000 }),
  v_logs: v('v_logs', 'ts DESC, log_id DESC', {
    resource_id: int('resource_id'), project_id: int('project_id'), level: text('level'),
    since: ts('ts', 'gte'), until: ts('ts', 'lte'),
    q: { column: 'message', type: 'text', kind: 'fts' },
    attrs: { column: 'attrs', type: 'text', kind: 'jsonb' },
  }, 'viewer', { defaultLimit: 200, maxLimit: 1000 }),
  v_audit_log: v('v_audit_log', 'audit_id DESC', { table_name: text('table_name'), actor_id: int('actor_id'), op: text('op'), since: ts('at', 'gte') }, 'viewer', { defaultLimit: 100 }),
  v_billing_failures: v('v_billing_failures', 'failure_id DESC', { cycle_id: int('cycle_id') }, 'admin'),
  v_stat_statements: v('v_stat_statements', 'total_ms DESC', {}, 'admin'),

  // Parameterised reads that are not plain views.
  metric_series: {
    kind: 'custom',
    minRole: 'viewer',
    sql: 'SELECT bucket, avg_value, max_value FROM fn_metric_series($1, $2, $3, $4, $5)',
    schema: z.object({
      resource_id: z.coerce.number().int(),
      metric: z.enum(['cpu_percent', 'mem_percent', 'net_kbps', 'disk_percent']),
      from: z.coerce.date().default(() => new Date(Date.now() - 24 * 3600_000)),
      to: z.coerce.date().default(() => new Date()),
      bucket: z.coerce.number().int().min(10).max(86400).default(300),
    }),
    args: ['resource_id', 'metric', 'from', 'to', 'bucket'],
  },
  latest_metrics: {
    kind: 'custom',
    minRole: 'viewer',
    sql: `SELECT DISTINCT ON (resource_id, metric) resource_id, metric, ts, value
            FROM v_usage_metrics WHERE ts > now() - interval '15 minutes'
           ORDER BY resource_id, metric, ts DESC`,
    schema: z.object({}),
    args: [],
  },
};

// ------------------------------------------------------------------------------------------------

export interface ProcedureDef {
  minRole: Role;
  sql: string;                            // $1..$n follow `args`
  schema: z.ZodObject<Record<string, ZodTypeAny>>;
  args: string[];
  returns: 'scalar' | 'rows';
}

const id = z.coerce.number().int().positive();
const name = z.string().trim().min(1).max(63);

const proc = (fn: string, minRole: Role, schema: z.ZodObject<Record<string, ZodTypeAny>>, args: string[], returns: 'scalar' | 'rows' = 'scalar'): ProcedureDef => ({
  minRole,
  schema,
  args,
  returns,
  sql: returns === 'scalar'
    ? `SELECT ${fn}(${args.map((_, i) => `$${i + 1}`).join(', ')}) AS result`
    : `SELECT * FROM ${fn}(${args.map((_, i) => `$${i + 1}`).join(', ')})`,
});

export const procedures: Record<string, ProcedureDef> = {
  sp_provision_vm: proc('sp_provision_vm', 'developer', z.object({
    project_id: id, name, vcpus: z.coerce.number().int().min(1).max(64), memory_mb: z.coerce.number().int().min(128).max(262144),
    network_id: id, image: z.string().trim().min(1).max(200).default('ubuntu:24.04'),
  }), ['project_id', 'name', 'vcpus', 'memory_mb', 'network_id', 'image']),
  sp_create_volume: proc('sp_create_volume', 'developer', z.object({
    project_id: id, name, size_gb: z.coerce.number().int(), mount_path: z.string().trim().max(200).nullish().transform((x) => x ?? null),
  }), ['project_id', 'name', 'size_gb', 'mount_path']),
  sp_create_network: proc('sp_create_network', 'developer', z.object({
    project_id: id, name, cidr: z.string().trim().regex(/^[0-9a-fA-F:.]+\/\d{1,3}$/, 'cidr must look like 10.0.0.0/24'),
  }), ['project_id', 'name', 'cidr']),
  sp_set_resource_state: proc('sp_set_resource_state', 'developer', z.object({
    resource_id: id, state: z.enum(['pending', 'running', 'stopped', 'terminated']),
  }), ['resource_id', 'state']),
  sp_terminate_resource: proc('sp_terminate_resource', 'manager', z.object({ resource_id: id }), ['resource_id']),
  sp_add_member: proc('sp_add_member', 'manager', z.object({ project_id: id, user_id: id, role: z.enum(['viewer', 'developer', 'manager', 'admin']) }), ['project_id', 'user_id', 'role']),
  sp_remove_member: proc('sp_remove_member', 'manager', z.object({ project_id: id, user_id: id }), ['project_id', 'user_id']),
  sp_set_quota: proc('sp_set_quota', 'admin', z.object({ project_id: id, type: z.enum(['compute', 'storage', 'network']), max_units: z.coerce.number().int().min(0) }), ['project_id', 'type', 'max_units']),
  sp_create_alert_rule: proc('sp_create_alert_rule', 'developer', z.object({
    project_id: id, metric: z.enum(['cpu_percent', 'mem_percent', 'net_kbps', 'disk_percent']),
    operator: z.enum(['>', '>=', '<', '<=']), threshold: z.coerce.number(), window_seconds: z.coerce.number().int().min(1),
  }), ['project_id', 'metric', 'operator', 'threshold', 'window_seconds']),
  sp_delete_alert_rule: proc('sp_delete_alert_rule', 'manager', z.object({ rule_id: id }), ['rule_id']),
  sp_create_billing_cycle: proc('sp_create_billing_cycle', 'admin', z.object({ from: z.coerce.date(), to: z.coerce.date() }), ['from', 'to']),
  sp_generate_invoices: proc('sp_generate_invoices', 'admin', z.object({ cycle_id: id }), ['cycle_id'], 'rows'),
  sp_record_payment: proc('sp_record_payment', 'manager', z.object({ invoice_id: id, amount: z.coerce.number().positive() }), ['invoice_id', 'amount']),
};
