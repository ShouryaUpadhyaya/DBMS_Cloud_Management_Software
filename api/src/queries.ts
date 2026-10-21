import fs from 'node:fs';
import path from 'node:path';
import { config } from './config.js';

export interface NamedQuery {
  name: string;
  title: string;
  concept: string;
  sql: string;
}

let cache: Map<string, NamedQuery> | null = null;

/** Named showcase queries live in db/queries/*.sql; the file name is the public name. */
export function loadQueries(dir = config.queriesDir): Map<string, NamedQuery> {
  if (cache && dir === config.queriesDir) return cache;
  const map = new Map<string, NamedQuery>();
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.sql')).sort()) {
    const sql = fs.readFileSync(path.join(dir, f), 'utf8').trim();
    const name = f.replace(/\.sql$/, '');
    map.set(name, {
      name,
      title: /^--\s*title:\s*(.+)$/m.exec(sql)?.[1].trim() ?? name,
      concept: /^--\s*concept:\s*(.+)$/m.exec(sql)?.[1].trim() ?? '',
      sql,
    });
  }
  if (dir === config.queriesDir) cache = map;
  return map;
}
