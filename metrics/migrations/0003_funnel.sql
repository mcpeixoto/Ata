-- Optional funnel counters and the Search Ads campaign id on each ping.
-- onboardingStep is how far setup got, so a second ping the same day keeps
-- the higher step. Every other counter is a tally and adds.
ALTER TABLE pings ADD COLUMN funnel TEXT NOT NULL DEFAULT '{}';
ALTER TABLE pings ADD COLUMN campaign TEXT;

-- One row per stage per UTC day, platform, version and campaign.
-- installs / onboarded count devices. Paywall, trial and paid sum events.
-- A device with no campaign is '(none)'. The app only pings after onboarding
-- has finished, so "installs" here are devices that checked in, not App Store
-- installs — that drop-off stays in App Store Connect.
CREATE VIEW funnel_daily AS
SELECT day, platform, version, COALESCE(campaign, '(none)') AS campaign,
       'installs' AS stage, '' AS detail, COUNT(DISTINCT id) AS n
FROM pings
WHERE app = 'ata'
GROUP BY day, platform, version, COALESCE(campaign, '(none)')

UNION ALL

SELECT day, platform, version, COALESCE(campaign, '(none)'),
       'onboarded', '',
       COUNT(DISTINCT id)
FROM pings
WHERE app = 'ata' AND json_type(funnel, '$.onboardingStep') IS NOT NULL
GROUP BY day, platform, version, COALESCE(campaign, '(none)')

UNION ALL

SELECT p.day, p.platform, p.version, COALESCE(p.campaign, '(none)'),
       'paywall', substr(c.key, 14),
       SUM(c.value)
FROM pings p, json_each(p.funnel) c
WHERE p.app = 'ata' AND c.key LIKE 'paywallShown.%'
GROUP BY p.day, p.platform, p.version, COALESCE(p.campaign, '(none)'), c.key

UNION ALL

SELECT p.day, p.platform, p.version, COALESCE(p.campaign, '(none)'),
       'trial', '',
       SUM(c.value)
FROM pings p, json_each(p.funnel) c
WHERE p.app = 'ata' AND c.key = 'trialStarted'
GROUP BY p.day, p.platform, p.version, COALESCE(p.campaign, '(none)')

UNION ALL

SELECT p.day, p.platform, p.version, COALESCE(p.campaign, '(none)'),
       'paid', substr(c.key, 11),
       SUM(c.value)
FROM pings p, json_each(p.funnel) c
WHERE p.app = 'ata' AND c.key LIKE 'purchased.%'
GROUP BY p.day, p.platform, p.version, COALESCE(p.campaign, '(none)'), c.key;
