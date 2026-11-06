# ata-metrics

The server behind Ata's anonymous daily count (`Sources/Ata/Metrics.swift`). A
Cloudflare Worker that accepts one JSON ping and stores it in D1, one row per
install per UTC day. It reads the country Cloudflare derives from the connection;
the IP address is never read, stored or logged, and request logs are off.

The app sends exactly:

```json
{"id": "<random UUID>", "platform": "mac", "version": "2.9.0", "build": "123",
 "os": "26.1", "locale": "pt-PT", "meetings": 2, "minutes": 45}
```

Anything else — another field, a missing one, free text — is refused with 400.

## Numbers

```bash
./report.sh
```

Installs active today / this week / this month, by version, by country, by OS,
and meetings and minutes recorded per week.

## Develop

```bash
npm ci
npm test                                   # tsc + vitest in workerd
npx wrangler d1 migrations apply ata-metrics --remote
npx wrangler deploy
```

Deployed at `https://ata-metrics.miguelpeixoto457.workers.dev/v1/ping`, the
`AtaMetricsURL` in both Info.plists. A fork without that key sends nothing.
