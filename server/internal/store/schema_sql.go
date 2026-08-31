package store

// embeddedSchemaSQL mirrors schema.sql for `go test` runs where the working
// directory differs from the Docker image layout. Keep in sync.
const embeddedSchemaSQL = `
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email         TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS companies (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL,
  owner_id   UUID NOT NULL REFERENCES users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS memberships (
  user_id    UUID NOT NULL REFERENCES users(id),
  company_id UUID NOT NULL REFERENCES companies(id),
  role       TEXT NOT NULL DEFAULT 'owner',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, company_id)
);

CREATE TABLE IF NOT EXISTS records (
  company_id        UUID NOT NULL,
  table_name        TEXT NOT NULL,
  row_pk            TEXT NOT NULL,
  data              JSONB NOT NULL,
  updated_at        TIMESTAMPTZ NOT NULL,
  server_updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  origin_device     TEXT,
  PRIMARY KEY (company_id, table_name, row_pk)
);

CREATE TABLE IF NOT EXISTS tombstones (
  company_id        UUID NOT NULL,
  table_name        TEXT NOT NULL,
  row_pk            TEXT NOT NULL,
  server_updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, table_name, row_pk)
);

CREATE INDEX IF NOT EXISTS idx_records_server_updated
  ON records (company_id, table_name, server_updated_at);
CREATE INDEX IF NOT EXISTS idx_tombstones_server_updated
  ON tombstones (company_id, table_name, server_updated_at);
CREATE INDEX IF NOT EXISTS idx_records_invoice_number
  ON records (company_id, table_name, (data->>'type'), (data->>'invoice_number'))
  WHERE table_name = 'invoices' AND data->>'invoice_number' IS NOT NULL;
`
