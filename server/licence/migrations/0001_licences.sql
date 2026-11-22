-- One row per purchase. The buyer's email is kept only as a SHA-256 hash, so
-- /v1/recover can find their keys without the database holding addresses.
CREATE TABLE IF NOT EXISTS licences (
  key            TEXT PRIMARY KEY,          -- ATA-XXXX-XXXX-XXXX-XXXX
  customer       TEXT NOT NULL,             -- Stripe customer id
  email_hash     TEXT,                      -- hex SHA-256 of the lowercased email
  plan           TEXT NOT NULL,             -- monthly | yearly | lifetime
  status         TEXT NOT NULL,             -- active | past_due | canceled | refunded
  expires_at     INTEGER,                   -- epoch seconds; NULL for lifetime
  session        TEXT NOT NULL UNIQUE,      -- Checkout Session id, so a key is issued once
  subscription   TEXT,                      -- Stripe subscription id (monthly, yearly)
  payment_intent TEXT,                      -- Stripe payment intent id (lifetime)
  created_at     INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS licences_subscription ON licences (subscription);
CREATE INDEX IF NOT EXISTS licences_payment_intent ON licences (payment_intent);
CREATE INDEX IF NOT EXISTS licences_customer ON licences (customer);
CREATE INDEX IF NOT EXISTS licences_email_hash ON licences (email_hash);

-- One row per Mac a key is activated on. At most three per key.
CREATE TABLE IF NOT EXISTS instances (
  id         TEXT PRIMARY KEY,
  key        TEXT NOT NULL REFERENCES licences (key),
  name       TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS instances_key ON instances (key);
