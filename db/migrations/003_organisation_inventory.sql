-- 003: organisation and inventory.
-- Concepts: recursive project hierarchy, ternary relationship, supertype/subtype
-- (disjoint + total), ON DELETE RESTRICT, partial unique index.

CREATE TABLE projects (
  project_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name              text NOT NULL UNIQUE CHECK (length(btrim(name)) > 0),
  owner_id          integer NOT NULL REFERENCES users(user_id),
  parent_project_id integer REFERENCES projects(project_id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (parent_project_id IS NULL OR parent_project_id <> project_id)
);

-- Ternary relationship: a user holds one role in a project.
CREATE TABLE project_members (
  project_id integer NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
  user_id    integer NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  role_id    integer NOT NULL REFERENCES roles(role_id),
  PRIMARY KEY (project_id, user_id)
);

CREATE TABLE resource_types (
  type_id integer PRIMARY KEY,                         -- fixed ids: subtype tables pin to them
  name    text NOT NULL UNIQUE,
  unit    text NOT NULL
);
INSERT INTO resource_types (type_id, name, unit) VALUES
  (1, 'compute', 'vcpu-hour'),
  (2, 'storage', 'gb-hour'),
  (3, 'network', 'network-hour');

CREATE TABLE quotas (
  project_id       integer NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
  resource_type_id integer NOT NULL REFERENCES resource_types(type_id),
  max_units        integer NOT NULL CHECK (max_units >= 0),   -- VMs, GB or networks
  PRIMARY KEY (project_id, resource_type_id)
);

CREATE TABLE nodes (
  node_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  hostname text NOT NULL UNIQUE,
  region   text NOT NULL DEFAULT 'local'
);

-- Supertype. Disjoint: each subtype table pins type_id via a composite FK to
-- UNIQUE (resource_id, type_id). Total: constraint trigger in 007 (deferred).
CREATE TABLE resources (
  resource_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id  integer NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
  type_id     integer NOT NULL REFERENCES resource_types(type_id),
  node_id     integer REFERENCES nodes(node_id),
  name        text NOT NULL CHECK (length(btrim(name)) > 0),
  external_id text UNIQUE,                             -- docker object id for discovered resources
  state       text NOT NULL DEFAULT 'pending'
              CHECK (state IN ('pending', 'running', 'stopped', 'terminated')),
  source      text NOT NULL DEFAULT 'provisioned' CHECK (source IN ('discovered', 'provisioned')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (resource_id, type_id),
  CHECK (source = 'discovered' OR external_id IS NULL)
);
-- A name is unique per project among live resources (a terminated name may be reused).
CREATE UNIQUE INDEX resources_live_name_uq ON resources (project_id, name) WHERE state <> 'terminated';

CREATE TABLE compute_instances (
  resource_id integer PRIMARY KEY,
  type_id     integer NOT NULL DEFAULT 1 CHECK (type_id = 1),
  vcpus       integer NOT NULL CHECK (vcpus > 0),
  memory_mb   integer NOT NULL CHECK (memory_mb > 0),
  image       text NOT NULL DEFAULT 'unknown',
  FOREIGN KEY (resource_id, type_id) REFERENCES resources(resource_id, type_id) ON DELETE CASCADE
);

CREATE TABLE storage_volumes (
  resource_id integer PRIMARY KEY,
  type_id     integer NOT NULL DEFAULT 2 CHECK (type_id = 2),
  size_gb     integer NOT NULL CHECK (size_gb > 0),
  mount_path  text,
  FOREIGN KEY (resource_id, type_id) REFERENCES resources(resource_id, type_id) ON DELETE CASCADE
);

CREATE TABLE networks (
  resource_id integer PRIMARY KEY,
  type_id     integer NOT NULL DEFAULT 3 CHECK (type_id = 3),
  cidr        cidr NOT NULL,
  FOREIGN KEY (resource_id, type_id) REFERENCES resources(resource_id, type_id) ON DELETE CASCADE
);

-- Which VM sits on which network with which address; an address is unique per network.
CREATE TABLE network_attachments (
  resource_id integer NOT NULL REFERENCES compute_instances(resource_id) ON DELETE CASCADE,
  network_id  integer NOT NULL REFERENCES networks(resource_id),
  ip          inet NOT NULL,
  PRIMARY KEY (resource_id, network_id),
  UNIQUE (network_id, ip)
);
