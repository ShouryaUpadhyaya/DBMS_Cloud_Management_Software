-- 002: identity and access tables.
-- Concepts: surrogate keys, UNIQUE, CHECK, self-referencing hierarchy, M:N resolved with junction
-- tables, ternary relationship (project_members), hashed credentials.

CREATE TABLE users (
  user_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email         text NOT NULL UNIQUE CHECK (email = lower(email) AND email LIKE '%_@_%'),
  name          text NOT NULL CHECK (length(btrim(name)) > 0),
  status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended')),
  password_hash text,                                  -- pgcrypto crypt(); never the plain password
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Role hierarchy: parent_role_id is the role whose permissions this role inherits.
CREATE TABLE roles (
  role_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name           text NOT NULL UNIQUE,
  parent_role_id integer REFERENCES roles(role_id),
  CHECK (parent_role_id IS NULL OR parent_role_id <> role_id)
);

CREATE TABLE permissions (
  perm_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  action        text NOT NULL,
  resource_type text NOT NULL,
  UNIQUE (action, resource_type)
);

-- M:N between roles and permissions.
CREATE TABLE role_permissions (
  role_id integer NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
  perm_id integer NOT NULL REFERENCES permissions(perm_id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, perm_id)
);

CREATE TABLE api_keys (
  key_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    integer NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  key_hash   text NOT NULL,                            -- crypt(key, gen_salt('bf')) only
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);
