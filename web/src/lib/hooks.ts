import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { api, getToken, Params, Row } from './api';

/** Reads a registry view; refetches on an interval when `refresh` seconds is given. */
export function useView<T = Row>(name: string, params?: Params, opts: { refresh?: number; enabled?: boolean } = {}) {
  return useQuery({
    queryKey: ['view', name, params ?? {}],
    queryFn: () => api.view<T>(name, params),
    refetchInterval: opts.refresh ? opts.refresh * 1000 : false,
    enabled: opts.enabled ?? true,
  });
}

/** Calls a stored procedure through the registry and invalidates every cached view afterwards. */
export function useProcedure<T = unknown>(name: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Record<string, unknown>) => api.call<T>(name, body),
    onSuccess: () => { void qc.invalidateQueries({ queryKey: ['view'] }); },
  });
}

export interface LiveAlert { type: 'fired' | 'resolved'; rule_id: number; project_id: number; resource_id: number; metric: string; value: number; at: string }

/** Server-Sent Events from /api/stream (LISTEN alerts). EventSource cannot send headers, so the token rides in the query. */
export function useAlertStream(onAlert?: (a: LiveAlert) => void): { connected: boolean; last: LiveAlert | null } {
  const qc = useQueryClient();
  const [connected, setConnected] = useState(false);
  const [last, setLast] = useState<LiveAlert | null>(null);
  useEffect(() => {
    const token = getToken();
    if (!token) return;
    const es = new EventSource(`/api/stream?token=${encodeURIComponent(token)}`);
    es.addEventListener('hello', () => setConnected(true));
    es.addEventListener('alert', (e) => {
      const a = JSON.parse((e as MessageEvent<string>).data) as LiveAlert;
      setLast(a);
      onAlert?.(a);
      void qc.invalidateQueries({ queryKey: ['view', 'v_open_alerts'] });
      void qc.invalidateQueries({ queryKey: ['view', 'v_alert_history'] });
    });
    es.onerror = () => setConnected(false);
    return () => es.close();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [qc]);
  return { connected, last };
}

export function useTheme(): [boolean, () => void] {
  const [dark, setDark] = useState(() => document.documentElement.classList.contains('dark'));
  const toggle = () => {
    const next = !dark;
    document.documentElement.classList.toggle('dark', next);
    try { localStorage.setItem('crms.theme', next ? 'dark' : 'light'); } catch { /* storage unavailable */ }
    setDark(next);
  };
  return [dark, toggle];
}
