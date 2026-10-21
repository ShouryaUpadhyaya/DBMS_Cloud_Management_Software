# Normalization

Every table is analysed against its functional dependencies (FDs). A table is in **BCNF** when the left side of
every non-trivial FD is a superkey. Where the schema deliberately steps outside that, the reason is given.

## Summary

| Table | Key | Key FDs | Normal form |
|---|---|---|---|
| `users` | `user_id`; also `email` | `user_id → email, name, status, password_hash, …`; `email → user_id` | BCNF |
| `roles` | `role_id`; also `name` | `role_id → name, parent_role_id` | BCNF |
| `permissions` | `perm_id`; also `(action, resource_type)` | `perm_id → action, resource_type` | BCNF |
| `role_permissions` | `(role_id, perm_id)` | none beyond the key (all-key) | BCNF |
| `project_members` | `(project_id, user_id)` | `(project_id, user_id) → role_id` | BCNF |
| `api_keys` | `key_id` | `key_id → user_id, key_hash, created_at, revoked_at` | BCNF |
| `projects` | `project_id`; also `name` | `project_id → name, owner_id, parent_project_id` | BCNF |
| `quotas` | `(project_id, resource_type_id)` | `→ max_units` | BCNF |
| `nodes` | `node_id`; also `hostname` | `node_id → hostname, region` | BCNF |
| `resource_types` | `type_id`; also `name` | `type_id → name, unit` | BCNF |
| `resources` | `resource_id`; also `external_id` | `resource_id → project_id, type_id, node_id, name, external_id, state, source, …` | BCNF |
| `compute_instances` | `resource_id` | `resource_id → vcpus, memory_mb, image` | BCNF |
| `storage_volumes` | `resource_id` | `resource_id → size_gb, mount_path` | BCNF |
| `networks` | `resource_id` | `resource_id → cidr` | BCNF |
| `network_attachments` | `(resource_id, network_id)`; also `(network_id, ip)` | `(resource_id, network_id) → ip`; `(network_id, ip) → resource_id` | BCNF (two candidate keys) |
| `pricing_plans` | `plan_id` | `plan_id → type_id, unit_price, effective_from, effective_to` | BCNF |
| `allocations` | `allocation_id` | `allocation_id → resource_id, project_id, period` | BCNF |
| `billing_cycles` | `cycle_id` | `cycle_id → period` | BCNF |
| `invoices` | `invoice_id`; also `(project_id, cycle_id)` | `invoice_id → project_id, cycle_id, total, status` | BCNF, `total` derived (see below) |
| `invoice_line_items` | `(invoice_id, line_no)` | `→ resource_id, units, unit_price, amount` | 3NF by design, see below |
| `payments` | `payment_id` | `→ invoice_id, amount, paid_at` | BCNF |
| `usage_metrics` | `(resource_id, metric, ts)` | `→ value` | BCNF |
| `log_entries` | `(log_id, ts)` | `→ resource_id, level, message, attrs` | BCNF (`attrs` is a single jsonb value) |
| `alert_rules` | `rule_id` | `→ project_id, metric, operator, threshold, window_seconds` | BCNF |
| `alert_events` | `event_id` | `→ rule_id, resource_id, fired_at, resolved_at, peak_value` | BCNF |
| `audit_log` | `audit_id` | `→ all columns` | BCNF (images stored as jsonb snapshots) |

## Decisions worth explaining

**1NF.** Every column is atomic. The two `jsonb` columns (`log_entries.attrs`, `audit_log.old_data/new_data`)
are treated as single opaque values: the database never decomposes them in constraints. They exist because the
shape varies per log line / audited table, which is exactly the case where a document column beats an
entity-attribute-value table.

**Pricing split out of `resources` (BCNF).** If each resource row carried its price, then
`(type_id, period) → unit_price` would be an FD whose left side is not a key of `resources`: a BCNF violation, and an
update anomaly (changing the price of "compute" would touch every compute row). Pricing therefore lives in
`pricing_plans(type_id, effective_from, effective_to, unit_price)`, and the `EXCLUDE USING gist` constraint guarantees
the dependency is functional: no two plans of one type overlap in time, so a (type, instant) pair determines at
most one price.

**Supertype / subtype instead of one wide `resources` table.** One table with `vcpus, memory_mb, size_gb, cidr, …`
would leave most columns NULL for any given row and could not state "a compute row must have `vcpus`". The subtype
tables hold only the attributes that exist for that type (each depends on `resource_id` alone), and:

- *disjoint*: each subtype carries a constant `type_id` and a composite FK `(resource_id, type_id) → resources`, so a
  resource cannot appear in two subtype tables;
- *total*: a deferred constraint trigger checks at COMMIT that the matching subtype row exists.

`type_id` is therefore stored twice (in `resources` and in each subtype). That duplication is the price of the
composite FK; the `CHECK (type_id = 1)` keeps the copies from diverging.

**`project_members` as a ternary relationship.** `role_id` depends on the *pair* `(project_id, user_id)`; it is a
function of neither column alone, so the table is in 2NF/BCNF with the composite key. Splitting it into two binary
tables would lose the information of which role applies where.

**`network_attachments` has two candidate keys.** `(resource_id, network_id)` (a VM is attached to a network once)
and `(network_id, ip)` (an address is held by one VM). Both determine the whole row, so BCNF holds.

**Deliberate denormalization 1: `invoice_line_items.unit_price` and `amount`.** In pure 3NF the unit price would be
looked up from `pricing_plans`, and `amount = units × unit_price` is derivable. The line stores both on purpose: an
invoice is a *historical document*. If the price list changes next month, last month's invoice must not change.
This is a temporal/legal requirement, not a convenience. The test `t_billing.sql` proves it by changing the
price and checking the invoice is untouched. `line_no` is a per-invoice sequence (weak entity), and one resource can
appear on several lines when its allocation spans a price change.

**Deliberate denormalization 2: `invoices.total`.** It equals `SUM(invoice_line_items.amount)`. It is stored
(1) so listing and filtering invoices does not aggregate line items, and (2) so the audit trigger records a
total that cannot silently drift. `sp_generate_invoices` writes it in the same transaction as the lines, and the
billing test asserts `total = SUM(lines)`.

**Derived data kept in separate objects.** `usage_rollup_daily` (a table, written by `sp_rollup_and_retention`
before raw partitions are dropped) and `mv_daily_usage` (a materialized view) are aggregates of `usage_metrics`.
They are summaries, not part of the base design, so they do not weaken the normal form of the base tables.

**`audit_log` stores snapshots.** `old_data` / `new_data` repeat values from the audited tables on purpose: an
audit trail must keep the value *as it was*, even after the source row is changed or deleted. `actor_id` has no
foreign key for the same reason.

**Surrogate keys.** Natural candidates (`email`, `hostname`, `name`) are kept as `UNIQUE` but not used as foreign
keys, so renaming an email does not cascade through the schema.
