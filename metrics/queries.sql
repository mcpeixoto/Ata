-- Run them all with ./report.sh. One at a time:
-- npx wrangler d1 execute ata-metrics --remote --command "SELECT ..."

-- Active installs per app: today, last 7 days, last 30 days, ever.
SELECT app,
  COUNT(DISTINCT CASE WHEN day = date('now') THEN id END)             AS dau,
  COUNT(DISTINCT CASE WHEN day > date('now', '-7 days') THEN id END)  AS wau,
  COUNT(DISTINCT CASE WHEN day > date('now', '-30 days') THEN id END) AS mau,
  COUNT(DISTINCT id)                                                  AS installs_ever
FROM pings GROUP BY app ORDER BY mau DESC, app;

-- Active installs in the last 30 days by app, platform and version.
SELECT app, platform, version, COUNT(DISTINCT id) AS installs
FROM pings WHERE day > date('now', '-30 days')
GROUP BY app, platform, version ORDER BY app, installs DESC;

-- By app and country, last 30 days.
SELECT app, COALESCE(country, '??') AS country, COUNT(DISTINCT id) AS installs
FROM pings WHERE day > date('now', '-30 days')
GROUP BY app, country ORDER BY app, installs DESC;

-- Ata: meetings and minutes recorded per week.
SELECT strftime('%Y-W%W', day) AS week, platform,
       SUM(meetings) AS meetings, SUM(minutes) AS minutes, COUNT(DISTINCT id) AS installs
FROM pings WHERE app = 'ata' GROUP BY week, platform ORDER BY week DESC LIMIT 26;

-- Every other app: each counter's weekly total.
SELECT p.app, strftime('%Y-W%W', p.day) AS week, c.key AS counter, SUM(c.value) AS total,
       COUNT(DISTINCT p.id) AS installs
FROM pings p, json_each(p.counts) c
GROUP BY p.app, week, c.key ORDER BY week DESC, p.app, c.key LIMIT 200;

-- OS versions by app, last 30 days.
SELECT app, platform, os, COUNT(DISTINCT id) AS installs
FROM pings WHERE day > date('now', '-30 days')
GROUP BY app, platform, os ORDER BY app, installs DESC;
