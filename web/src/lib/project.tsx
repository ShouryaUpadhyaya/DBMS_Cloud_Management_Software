import { createContext, ReactNode, useContext, useMemo, useState } from 'react';
import { useView } from './hooks';

export interface ProjectRow { project_id: number; name: string; my_role: string | null; parent_project_id: number | null }

interface ProjectState {
  projects: ProjectRow[];
  projectId: number | null;                 // null = all visible projects
  setProjectId: (id: number | null) => void;
}

const Ctx = createContext<ProjectState | null>(null);

export function ProjectProvider({ children }: { children: ReactNode }) {
  const { data } = useView<ProjectRow>('v_projects');
  const [projectId, setProjectId] = useState<number | null>(() => {
    try { const v = localStorage.getItem('crms.project'); return v ? Number(v) : null; } catch { return null; }
  });
  const value = useMemo(() => ({
    projects: data ?? [],
    projectId,
    setProjectId: (id: number | null) => {
      setProjectId(id);
      try { if (id === null) localStorage.removeItem('crms.project'); else localStorage.setItem('crms.project', String(id)); } catch { /* storage unavailable */ }
    },
  }), [data, projectId]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useProject(): ProjectState {
  const v = useContext(Ctx);
  if (!v) throw new Error('useProject outside ProjectProvider');
  return v;
}
