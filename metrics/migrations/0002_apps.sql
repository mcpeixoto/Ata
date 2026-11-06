-- The same Worker now counts every app, not only Ata. SQLite cannot change a
-- primary key in place, so the table is rebuilt with `app` in front of it.
-- Every existing row came from Ata, and Ata 3.4.0 keeps sending no `app`.
CREATE TABLE pings_v2 (
  app      TEXT NOT NULL DEFAULT 'ata',  -- allowlisted in src/index.ts
  id       TEXT NOT NULL,
  day      TEXT NOT NULL,
  platform TEXT NOT NULL,
  version  TEXT NOT NULL,
  build    TEXT NOT NULL,
  os       TEXT NOT NULL,
  locale   TEXT NOT NULL,
  country  TEXT,
  meetings INTEGER NOT NULL DEFAULT 0,   -- Ata only
  minutes  INTEGER NOT NULL DEFAULT 0,   -- Ata only
  counts   TEXT NOT NULL DEFAULT '{}',   -- every other app: {"name": n, ...}
  PRIMARY KEY (app, id, day)
);

INSERT INTO pings_v2 (app, id, day, platform, version, build, os, locale, country, meetings, minutes)
SELECT 'ata', id, day, platform, version, build, os, locale, country, meetings, minutes FROM pings;

DROP TABLE pings;
ALTER TABLE pings_v2 RENAME TO pings;
CREATE INDEX pings_app_day ON pings (app, day);
