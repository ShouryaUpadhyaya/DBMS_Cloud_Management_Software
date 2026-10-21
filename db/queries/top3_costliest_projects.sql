-- title: Top 3 costliest projects
-- concept: RANK() window function over aggregated invoice totals (ties share a rank)
SELECT project, billed, rnk
  FROM (SELECT p.name AS project,
               sum(i.total) AS billed,
               rank() OVER (ORDER BY sum(i.total) DESC) AS rnk
          FROM invoices i
          JOIN projects p USING (project_id)
         GROUP BY p.name) ranked
 WHERE rnk <= 3
 ORDER BY rnk, project;
