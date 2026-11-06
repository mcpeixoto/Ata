-- One row per install per UTC day. A second ping the same day adds its counts.
CREATE TABLE IF NOT EXISTS pings (
  id       TEXT NOT NULL,     -- random, made by the app for this alone
  day      TEXT NOT NULL,     -- yyyy-mm-dd, UTC
  platform TEXT NOT NULL,     -- mac | ios
  version  TEXT NOT NULL,
  build    TEXT NOT NULL,
  os       TEXT NOT NULL,
  locale   TEXT NOT NULL,
  country  TEXT,              -- from the connection; the IP itself is never stored
  meetings INTEGER NOT NULL DEFAULT 0,
  minutes  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id, day)
);
CREATE INDEX IF NOT EXISTS pings_day ON pings (day);
