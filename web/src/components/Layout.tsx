import { ReactNode, useState } from 'react';
import { NavLink, Outlet } from 'react-router-dom';
import { atLeast, Role } from '../lib/api';
import { useAuth } from '../lib/auth';
import { LiveAlert, useAlertStream, useTheme, useView } from '../lib/hooks';
import { useProject } from '../lib/project';
import { metricLabel, num } from '../lib/format';
import { Badge } from './ui';

const NAV: { to: string; label: string; min?: Role; icon: string }[] = [
  { to: '/', label: 'Dashboard', icon: '▦' },
  { to: '/resources', label: 'Resources', icon: '▣' },
  { to: '/launch', label: 'Launch', icon: '＋', min: 'developer' },
  { to: '/monitoring', label: 'Monitoring', icon: '∿' },
  { to: '/logs', label: 'Logs', icon: '≣' },
  { to: '/alerts', label: 'Alerts', icon: '△' },
  { to: '/billing', label: 'Billing', icon: '$' },
  { to: '/access', label: 'Access', icon: '⚿' },
  { to: '/audit', label: 'Audit log', icon: '☰' },
  { to: '/lab', label: 'DB Lab', icon: '⌬', min: 'admin' },
];

export function Layout() {
  const { user, logout } = useAuth();
  const { projects, projectId, setProjectId } = useProject();
  const [dark, toggleTheme] = useTheme();
  const [toast, setToast] = useState<LiveAlert | null>(null);
  const { connected } = useAlertStream((a) => { setToast(a); window.setTimeout(() => setToast(null), 8000); });
  const { data: open } = useView('v_open_alerts', undefined, { refresh: 30 });
  const [menu, setMenu] = useState(false);

  return (
    <div className="flex min-h-screen">
      <aside className={`${menu ? 'block' : 'hidden'} fixed inset-y-0 left-0 z-20 w-48 shrink-0 border-r border-line bg-panel md:static md:block`}>
        <div className="flex h-12 items-center gap-2 border-b border-line px-3 font-semibold"><span className="grid h-6 w-6 place-items-center rounded bg-accent text-xs text-white dark:text-bg">C</span>CRMS</div>
        <nav aria-label="Main" className="p-2">
          {NAV.filter((n) => !n.min || (user && atLeast(user.role, n.min))).map((n) => (
            <NavLink key={n.to} to={n.to} end={n.to === '/'} onClick={() => setMenu(false)}
                     className={({ isActive }) => `flex items-center gap-2 rounded px-2 py-1.5 text-sm ${isActive ? 'bg-accent/15 font-medium text-accent' : 'text-fg hover:bg-subtle'}`}>
              <span className="w-4 text-center text-muted" aria-hidden>{n.icon}</span>{n.label}
              {n.to === '/alerts' && open && open.length > 0 && <span className="ml-auto rounded-full bg-bad px-1.5 text-xs text-white">{open.length}</span>}
            </NavLink>
          ))}
        </nav>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-10 flex h-12 items-center gap-3 border-b border-line bg-panel px-3">
          <button className="btn md:hidden" aria-label="Toggle navigation" onClick={() => setMenu(!menu)}>☰</button>
          <label className="flex items-center gap-1 text-xs text-muted">Project
            <select className="input w-44" value={projectId ?? ''} onChange={(e) => setProjectId(e.target.value ? Number(e.target.value) : null)} aria-label="Project filter">
              <option value="">All projects</option>
              {projects.map((p) => <option key={p.project_id} value={p.project_id}>{p.name}</option>)}
            </select>
          </label>
          <span className="ml-auto flex items-center gap-3 text-xs">
            <span title={connected ? 'Receiving live alerts' : 'Live alert stream disconnected'} className={connected ? 'text-ok' : 'text-muted'}>● {connected ? 'live' : 'offline'}</span>
            <button className="btn" onClick={toggleTheme} aria-label="Toggle dark mode">{dark ? '☀ Light' : '☾ Dark'}</button>
            <span className="hidden text-right leading-tight sm:block"><span className="block font-medium">{user?.name}</span><span className="text-muted">{user?.email}</span></span>
            <Badge tone="info">{user?.role}</Badge>
            <button className="btn" onClick={logout}>Sign out</button>
          </span>
        </header>
        <main className="min-w-0 flex-1 p-4"><Outlet /></main>
      </div>

      {toast && (
        <div role="alert" className="fixed bottom-4 right-4 z-30 max-w-sm rounded-md border border-line bg-panel p-3 shadow-lg">
          <div className="flex items-center gap-2"><Badge tone={toast.type === 'fired' ? 'bad' : 'ok'}>{toast.type}</Badge><span className="font-medium">{metricLabel(toast.metric)} alert</span></div>
          <p className="mt-1 text-xs text-muted">Resource #{toast.resource_id} · avg {num(toast.value)} · rule #{toast.rule_id}</p>
        </div>
      )}
    </div>
  );
}

export function Page({ children }: { children: ReactNode }) { return <div className="mx-auto max-w-7xl">{children}</div>; }
