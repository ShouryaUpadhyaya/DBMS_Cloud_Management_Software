-- title: Missed heartbeats (running, but silent for 5 minutes)
-- concept: anti-join with NOT EXISTS; LATERAL fetches the last time each silent resource was seen
SELECT r.resource_id, r.name, rt.name AS type, last_seen.ts AS last_seen
  FROM resources r
  JOIN resource_types rt ON rt.type_id = r.type_id
  LEFT JOIN LATERAL (SELECT max(um.ts) AS ts FROM usage_metrics um
                      WHERE um.resource_id = r.resource_id AND um.ts > now() - interval '30 days') last_seen ON true
 WHERE r.state = 'running'
   AND r.type_id = 1                      -- instances report heartbeats; volumes/networks are passive
   AND NOT EXISTS (SELECT 1 FROM usage_metrics um
                    WHERE um.resource_id = r.resource_id AND um.ts > now() - interval '5 minutes')
 ORDER BY last_seen.ts NULLS FIRST;
