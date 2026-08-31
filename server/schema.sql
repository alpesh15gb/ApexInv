-- Apex Books sync server schema (dbplan.md §3.6, VPS edition).
-- Applied idempotently by the API on startup (see internal/store).
-- Postgres 16+.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── Accounts ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email         TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,               -- argon2id
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

-- ── Business data relay (dbplan §3.6) ───────────────────────────────────
-- One jsonb row per synced business row. The client pushes full row
-- payloads; the server is schema-agnostic apart from a small set of typed
-- columns it inspects (invoice_number collision handling).
CREATE TABLE IF NOT EXISTS records (
  company_id        UUID NOT NULL,
  table_name        TEXT NOT NULL,
  row_pk            TEXT NOT NULL,
  data              JSONB NOT NULL,
  updated_at        TIMESTAMPTZ NOT NULL,           -- client LWW key
  server_updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  origin_device     TEXT,
  PRIMARY KEY (company_id, table_name, row_pk)
);

CREATE TABLE IF NOT EXISTS tombstones (
  company_id        UUID NOT NULL,
  table_name        TEXT NOT NULL,
  row_pk            TEXT NOT NULL,
  client_changed_at TIMESTAMPTZ,                -- deleting device's LWW key
  server_updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (company_id, table_name, row_pk)
);
-- Pre-lwwAt deployments created tombstones without the client stamp.
ALTER TABLE tombstones ADD COLUMN IF NOT EXISTS client_changed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_records_server_updated
  ON records (company_id, table_name, server_updated_at);
CREATE INDEX IF NOT EXISTS idx_tombstones_server_updated
  ON tombstones (company_id, table_name, server_updated_at);
-- Invoice-number uniqueness per company+type, enforced via the typed
-- columns the server reads out of data->>'invoice_number'. Uniqueness of
-- active rows is advisory here and arbitrated in code (later arrival gets
-- reassigned); the index just makes the check cheap.
CREATE INDEX IF NOT EXISTS idx_records_invoice_number
  ON records (company_id, table_name, (data->>'type'), (data->>'invoice_number'))
  WHERE table_name = 'invoices' AND data->>'invoice_number' IS NOT NULL;
