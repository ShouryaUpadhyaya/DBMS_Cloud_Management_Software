import { FormEvent, useState } from 'react';
import { ApiError } from '../lib/api';
import { useAuth } from '../lib/auth';

const DEMO = [
  ['admin@crms.test', 'Admin: everything, DB Lab'],
  ['alice@crms.test', 'Manager of Web Platform'],
  ['bob@crms.test', 'Developer (Web Platform), viewer (Data Lab)'],
  ['carol@crms.test', 'Viewer of Web Platform'],
  ['dave@crms.test', 'Manager of Data Lab'],
];

export function Login() {
  const { login } = useAuth();
  const [email, setEmail] = useState('admin@crms.test');
  const [password, setPassword] = useState('password123');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    try { await login(email, password); } catch (err) { setError(err instanceof ApiError ? err.message : 'Cannot reach the API'); } finally { setBusy(false); }
  };

  return (
    <div className="grid min-h-screen place-items-center p-4">
      <div className="w-full max-w-sm">
        <div className="mb-4 flex items-center gap-2"><span className="grid h-8 w-8 place-items-center rounded bg-accent font-bold text-white dark:text-bg">C</span><div><h1 className="text-lg font-semibold leading-tight">CRMS Console</h1><p className="text-xs text-muted">Cloud Resource Management System</p></div></div>
        <form onSubmit={submit} className="card grid gap-3 p-4">
          <div><label className="label" htmlFor="email">Email</label><input id="email" className="input" type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} /></div>
          <div><label className="label" htmlFor="password">Password</label><input id="password" className="input" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} /></div>
          {error && <div role="alert" className="rounded border border-bad/40 bg-bad/10 px-2 py-1.5 text-sm text-bad">{error}</div>}
          <button className="btn btn-primary" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
        </form>
        <div className="card mt-3 text-xs">
          <div className="card-h">Seeded demo users (password123)</div>
          {DEMO.map(([e, d]) => (
            <button key={e} type="button" className="flex w-full justify-between gap-2 border-b border-line/60 px-3 py-1.5 text-left last:border-0 hover:bg-subtle" onClick={() => setEmail(e)}>
              <span className="font-medium">{e}</span><span className="text-muted">{d}</span>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
