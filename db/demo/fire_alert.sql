-- Fires a live CPU alert on api-1 (Web Platform rule: cpu_percent > 85 averaged over 300 s).
-- 48 samples at 98% over the last 4 minutes push the window average over the threshold; the
-- trigger opens an alert_event and pg_notify('alerts') reaches the UI toast and the Alerts page.
-- It resolves by itself once the collector's normal samples pull the average back down.
SELECT sp_ingest_metrics(jsonb_build_object('metrics', (
  SELECT jsonb_agg(jsonb_build_object('external_id', 'mock-api-1', 'ts', now() - make_interval(secs => 5 * g),
                                      'metric', 'cpu_percent', 'value', 98))
    FROM generate_series(0, 47) g))) AS ingested;
