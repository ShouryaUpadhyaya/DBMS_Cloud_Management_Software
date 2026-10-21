/** An error that already knows its HTTP status and JSON body. */
export class HttpError extends Error {
  constructor(public status: number, message: string, public body: Record<string, unknown> = {}) {
    super(message);
  }
}

export interface PgLikeError {
  code?: string;
  message: string;
  detail?: string;
  constraint?: string;
  column?: string;
  table?: string;
}

/** Pulls the offending column out of a unique/check/exclusion violation (best effort). */
export function fieldFromPgError(e: PgLikeError): string | undefined {
  if (e.column) return e.column;
  if (e.code === '23505') {
    // Key (project_id, name)=(2, pgdata) already exists.  The last column is the one a user typed.
    const key = /Key \(([^)]+)\)=/.exec(e.detail ?? '');
    if (key) {
      const cols = key[1].split(',').map((c) => c.trim());
      return cols[cols.length - 1];
    }
  }
  const c = e.constraint;
  if (c) {
    let s = c;
    if (e.table && s.startsWith(`${e.table}_`)) s = s.slice(e.table.length + 1);
    s = s.replace(/_(key|check|excl|pkey|uq|idx)$/, '');
    if (s && s !== c) return s;
  }
  return undefined;
}

/**
 * SQLSTATE -> HTTP.
 *   P0001 (RAISE EXCEPTION)            400, message passed through as-is
 *   23505 / 23514 / 23P01              409 with a field-level error
 *   23503 FK, 23502 NOT NULL           409 / 400
 *   42501 insufficient_privilege       403
 *   22xxx invalid input                400
 */
export function mapPgError(e: PgLikeError): HttpError | null {
  switch (e.code) {
    case 'P0001':
      return new HttpError(400, e.message, { error: e.message });
    case '23505':
    case '23514':
    case '23P01': {
      const field = fieldFromPgError(e);
      const kind = e.code === '23505' ? 'already exists' : e.code === '23P01' ? 'conflicts with an existing range' : 'is not allowed';
      return new HttpError(409, e.message, {
        error: field ? `${field} ${kind}` : e.message,
        code: e.code,
        constraint: e.constraint,
        field,
        fields: field ? { [field]: e.message } : {},
      });
    }
    case '23503':
      return new HttpError(409, e.message, { error: 'Referenced row is missing or still in use', code: e.code, constraint: e.constraint });
    case '23502':
      return new HttpError(400, e.message, { error: `${e.column ?? 'a column'} is required`, field: e.column });
    case '42501':
      return new HttpError(403, e.message, { error: e.message });
    default:
      if (e.code && /^22/.test(e.code)) return new HttpError(400, e.message, { error: e.message });
      return null;
  }
}
