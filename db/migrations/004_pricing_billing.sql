-- 004: pricing, allocations and billing.
-- Concepts: range types, EXCLUDE (temporal no-overlap), weak entity
-- (invoice_line_items), deliberate denormalisation (frozen price), composite keys.

CREATE TABLE pricing_plans (
  plan_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  type_id        integer NOT NULL REFERENCES resource_types(type_id),
  unit_price     numeric(12,6) NOT NULL CHECK (unit_price >= 0),
  effective_from timestamptz NOT NULL,
  effective_to   timestamptz,                          -- NULL = open ended
  CHECK (effective_to IS NULL OR effective_to > effective_from),
  -- BCNF: (type_id, period) -> unit_price, so price lives here and not on resources.
  EXCLUDE USING gist (type_id WITH =, tstzrange(effective_from, effective_to) WITH &&)
);

-- Who is billed for a resource during which time range.
CREATE TABLE allocations (
  allocation_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  resource_id   integer NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
  project_id    integer NOT NULL REFERENCES projects(project_id),
  period        tstzrange NOT NULL CHECK (NOT isempty(period)),
  EXCLUDE USING gist (resource_id WITH =, period WITH &&)
);

CREATE TABLE billing_cycles (
  cycle_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  period   tstzrange NOT NULL CHECK (NOT isempty(period) AND NOT lower_inf(period) AND NOT upper_inf(period)),
  EXCLUDE USING gist (period WITH &&)
);

CREATE TABLE invoices (
  invoice_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id integer NOT NULL REFERENCES projects(project_id),
  cycle_id   integer NOT NULL REFERENCES billing_cycles(cycle_id),
  total      numeric(14,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
  status     text NOT NULL DEFAULT 'issued' CHECK (status IN ('draft', 'issued', 'paid', 'void')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (project_id, cycle_id)
);

-- Weak entity: identified by (invoice_id, line_no). unit_price is frozen on purpose so a later
-- price change never rewrites history (intentional denormalisation, not a 3NF slip).
CREATE TABLE invoice_line_items (
  invoice_id  integer NOT NULL REFERENCES invoices(invoice_id) ON DELETE CASCADE,
  line_no     integer NOT NULL CHECK (line_no > 0),
  resource_id integer NOT NULL REFERENCES resources(resource_id),
  units       numeric(14,4) NOT NULL CHECK (units >= 0),
  unit_price  numeric(12,6) NOT NULL CHECK (unit_price >= 0),
  amount      numeric(14,2) NOT NULL CHECK (amount >= 0),
  PRIMARY KEY (invoice_id, line_no)
);

CREATE TABLE payments (
  payment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  invoice_id integer NOT NULL REFERENCES invoices(invoice_id),
  amount     numeric(14,2) NOT NULL CHECK (amount > 0),
  paid_at    timestamptz NOT NULL DEFAULT now()
);

-- Per-project failures recorded by sp_generate_invoices.
CREATE TABLE billing_failures (
  failure_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cycle_id   integer NOT NULL REFERENCES billing_cycles(cycle_id),
  project_id integer NOT NULL REFERENCES projects(project_id),
  sqlstate   text NOT NULL,
  message    text NOT NULL,
  at         timestamptz NOT NULL DEFAULT now()
);
