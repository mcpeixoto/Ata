# ata-metrics

The server behind the anonymous daily count in Ata (`Sources/Ata/Metrics.swift`)
and the maintainer's other apps: Polaris, Dr. Expenses, MealMind, Almanac, Cabin
and DeepHealth. A Cloudflare Worker that accepts one JSON ping and stores it in D1,
one row per app per install per UTC day. It stays in this repo, under its first
name, because Ata 3.4.0 is already in the field pointing at it. It reads the country Cloudflare derives from the connection;
the IP address is never read, stored or logged, and request logs are off.

The app sends exactly:

```json
{"id": "<random UUID>", "platform": "mac", "version": "2.9.0", "build": "123",
 "os": "26.1", "locale": "pt-PT", "meetings": 2, "minutes": 45}
```

Ata 4.0 may also send two optional fields. `funnel` is a handful of named
counters (0–10000), for example `{"onboardingStep": 4, "paywallShown.limit": 1}`.
`onboardingStep` is the furthest step reached, so a second ping the same day
keeps the higher one; every other counter adds. `campaign` is the Apple Search
Ads campaign id, or `organic`. A key that is not one of those, or a value past
the cap, is refused with the rest of the ping.

That shape, with no `app`, is Ata's and always will be. Every other app sends:

```json
{"app": "polaris", "id": "<random UUID>", "platform": "ios", "version": "1.4.0",
 "build": "88", "os": "26.1", "locale": "en-GB", "counts": {"plans": 2}}
```

`app` must be one of `APPS` in `src/index.ts`. `counts` holds up to eight named
integers (0–10000), how many times something happened, never what. A second ping
the same day adds to the first, counter by counter.

Any other field, a missing required one, or free text is refused with 400.

## Numbers

```bash
./report.sh
```

Per app: installs active today / this week / this month, by version, by country,
by OS; Ata's meetings and minutes per week; every other app's counters per week;
Ata's daily funnel (installs, onboarded, paywall by trigger, trial, paid) by
version and campaign.

Name each Apple Search Ads campaign for its one ad set. The attribution API
returns `campaignId`, not the campaign's name, so the daily view stays readable
only when that id means one ad set.

A new app: add its id to `APPS`, deploy, and point its `MetricsURL` here.

## Develop

```bash
npm ci
npm test                                   # tsc + vitest in workerd
npx wrangler d1 migrations apply ata-metrics --remote
npx wrangler deploy
```

Deployed at `https://ata-metrics.miguelpeixoto457.workers.dev/v1/ping`, the
`AtaMetricsURL` in both Info.plists. A fork without that key sends nothing.
