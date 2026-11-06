-- Run them all with ./report.sh. One at a time:
-- npx wrangler d1 execute ata-metrics --remote --command "SELECT ..."

-- Active installs: today, last 7 days, last 30 days, ever.
SELECT
  (SELECT COUNT(DISTINCT id) FROM pings WHERE day = date('now'))              AS dau,
  (SELECT COUNT(DISTINCT id) FROM pings WHERE day > date('now', '-7 days'))   AS wau,
  (SELECT COUNT(DISTINCT id) FROM pings WHERE day > date('now', '-30 days'))  AS mau,
  (SELECT COUNT(DISTINCT id) FROM pings)                                      AS installs_ever;

-- Active installs in the last 30 days by platform and version.
SELECT platform, version, COUNT(DISTINCT id) AS installs
FROM pings WHERE day > date('now', '-30 days')
GROUP BY platform, version ORDER BY installs DESC;

-- By country, last 30 days.
SELECT COALESCE(country, '??') AS country, COUNT(DISTINCT id) AS installs
FROM pings WHERE day > date('now', '-30 days')
GROUP BY country ORDER BY installs DESC;

-- Meetings and minutes recorded per week.
SELECT strftime('%Y-W%W', day) AS week, platform,
       SUM(meetings) AS meetings, SUM(minutes) AS minutes, COUNT(DISTINCT id) AS installs
FROM pings GROUP BY week, platform ORDER BY week DESC LIMIT 26;

-- OS versions, last 30 days.
SELECT platform, os, COUNT(DISTINCT id) AS installs
FROM pings WHERE day > date('now', '-30 days')
GROUP BY platform, os ORDER BY installs DESC;
