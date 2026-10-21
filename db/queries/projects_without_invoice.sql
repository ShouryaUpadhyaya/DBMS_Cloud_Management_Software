-- title: Projects that have never been invoiced
-- concept: LEFT JOIN ... IS NULL anti-join (finds rows with no match on the right side)
SELECT p.project_id, p.name, p.created_at
  FROM projects p
  LEFT JOIN invoices i ON i.project_id = p.project_id
 WHERE i.invoice_id IS NULL
 ORDER BY p.name;
