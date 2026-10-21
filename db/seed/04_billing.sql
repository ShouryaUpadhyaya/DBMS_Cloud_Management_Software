-- Seed 4: invoice the two previous calendar months, record some payments.
SELECT set_config('crms.user_id', (SELECT user_id::text FROM users WHERE email = 'admin@crms.test'), false);

SELECT sp_create_billing_cycle(date_trunc('month', now()) - interval '2 months', date_trunc('month', now()) - interval '1 month');
SELECT sp_create_billing_cycle(date_trunc('month', now()) - interval '1 month', date_trunc('month', now()));
SELECT * FROM sp_generate_invoices((SELECT cycle_id FROM billing_cycles ORDER BY lower(period) LIMIT 1));
SELECT * FROM sp_generate_invoices((SELECT cycle_id FROM billing_cycles ORDER BY lower(period) DESC LIMIT 1));

-- Fully pay the older invoices; partially pay one of the newer ones.
SELECT sp_record_payment(i.invoice_id, i.total)
  FROM invoices i JOIN billing_cycles c USING (cycle_id)
 WHERE lower(c.period) = (SELECT min(lower(period)) FROM billing_cycles) AND i.total > 0;
SELECT sp_record_payment(i.invoice_id, round(i.total / 2, 2))
  FROM invoices i JOIN projects p USING (project_id)
 WHERE p.name = 'Data Lab' AND i.cycle_id = (SELECT cycle_id FROM billing_cycles ORDER BY lower(period) DESC LIMIT 1);
