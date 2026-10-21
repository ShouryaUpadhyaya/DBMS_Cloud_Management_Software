const TOKEN_KEY = 'crms.token';

export const getToken = (): string | null => {
  try { return localStorage.getItem(TOKEN_KEY); } catch { return null; }
};
export const setToken = (t: string | null): void => {
  try { if (t) localStorage.setItem(TOKEN_KEY, t); else localStorage.removeItem(TOKEN_KEY); } catch { /* storage unavailable */ }
};

/** Error with the API's structured body: field-level messages for 400/409 responses. */
export class ApiError extends Error {
  constructor(public status: number, message: string, public fields: Record<string, string> = {}, public code?: string) {
    super(message);
  }
}

let onUnauthorized: () => void = () => undefined;
export const setUnauthorizedHandler = (fn: () => void): void => { onUnauthorized = fn; };

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const token = getToken();
  const res = await fetch(path, {
    method,
    headers: { ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data: Record<string, unknown> = {};
  try { data = text ? JSON.parse(text) : {}; } catch { /* non-JSON error page */ }
  if (!res.ok) {
    if (res.status === 401 && token) onUnauthorized();
    const fields = (data.fields ?? {}) as Record<string, string>;
    const field = data.field as string | undefined;
    throw new ApiError(res.status, String(data.error ?? res.statusText), field && !fields[field] ? { ...fields, [field]: String(data.error ?? '') } : fields, data.code as string | undefined);
  }
  return data as T;
}

export type Params = Record<string, string | number | boolean | undefined | null>;

export const qs = (p: Params = {}): string => {
  const s = new URLSearchParams();
  for (const [k, v] of Object.entries(p)) if (v !== undefined && v !== null && v !== '') s.set(k, String(v));
  const out = s.toString();
  return out ? `?${out}` : '';
};

export const api = {
  login: (email: string, password: string) => request<{ token: string; user: User }>('POST', '/api/auth/login', { email, password }),
  me: () => request<{ user: User }>('GET', '/api/auth/me'),
  view: async <T = Row>(name: string, params?: Params): Promise<T[]> => (await request<{ rows: T[] }>('GET', `/api/views/${name}${qs(params)}`)).rows,
  call: <T = unknown>(name: string, body: Record<string, unknown>) => request<{ result?: T; rows?: Row[] }>('POST', `/api/procedures/${name}`, body),
  queries: () => request<QueryMeta[]>('GET', '/api/queries'),
  query: (name: string) => request<QueryResult>('GET', `/api/queries/${name}`),
};

export type Row = Record<string, unknown>;
export type Role = 'admin' | 'manager' | 'developer' | 'viewer';
export interface User { userId: number; email: string; name: string; role: Role }
export interface QueryMeta { name: string; title: string; concept: string }
export interface PlanNode {
  'Node Type': string;
  'Relation Name'?: string;
  'Index Name'?: string;
  'Actual Rows'?: number;
  'Actual Total Time'?: number;
  'Actual Loops'?: number;
  Plans?: PlanNode[];
}
export interface QueryResult extends QueryMeta {
  sql: string; columns: string[]; rows: Row[]; row_count: number; duration_ms: number;
  plan: { Plan: PlanNode; 'Execution Time'?: number; 'Planning Time'?: number }[];
}

const ROLE_ORDER: Role[] = ['viewer', 'developer', 'manager', 'admin'];
export const atLeast = (have: Role, need: Role): boolean => ROLE_ORDER.indexOf(have) >= ROLE_ORDER.indexOf(need);
