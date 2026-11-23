# ata-licence

Sells Ata Pro for Mac through Stripe and issues the licence keys the Mac app
activates (`Sources/Ata/Licence.swift`). Stripe has no licence keys, so this
Cloudflare Worker makes them (`ATA-XXXX-XXXX-XXXX-XXXX`, Crockford base32, 80
random bits) and keeps them in D1. The Stripe secret key lives only here, never in
the app. Buyers' emails are stored only as SHA-256 hashes; request logs are off.

The Mac app is open source. This is a way to pay for it, not DRM.

## For the app

JSON over HTTPS. `status` is `active`, `past_due`, `canceled` or `refunded`;
`active` and `past_due` unlock, and `ok` says so. `expires_at` is ISO 8601 in
whole seconds, `null` for lifetime.

| Call | Body | Answer |
| --- | --- | --- |
| `POST /v1/activate` | `{key, instance_name}` | `{ok, instance_id, status, plan, expires_at}`; 409 `too_many_instances` past 3 Macs, 403 when the key no longer unlocks |
| `POST /v1/validate` | `{key, instance_id}` | same shape; 404 `unknown_instance` after a deactivation |
| `POST /v1/deactivate` | `{key, instance_id}` | same shape, frees the slot |
| `POST /v1/recover` | `{email}` | always 200 `{ok: true}`; emails the keys that still unlock to that address |

Unknown key: 404 `not_found`. Malformed: 400. More than 10 `/v1/*` calls a
minute from one IP: 429.

In the browser: `GET /buy?plan=monthly|yearly|lifetime` opens Stripe Checkout;
`/thanks` shows the key, an **Activate in Ata** button (`ata://licence?key=…`) and,
for subscriptions, a link to the Stripe customer portal (`/portal?key=…`).

`POST /webhook` takes Stripe's events, signature-checked with
`STRIPE_WEBHOOK_SECRET`: `checkout.session.completed` and
`checkout.session.async_payment_succeeded` issue the key (as does `/thanks`, if it
gets there first; one key per Checkout Session either way),
`customer.subscription.updated|deleted`, `invoice.payment_failed` and a full
`charge.refunded` change its status. A subscription whose period ended more than
three days ago reads as `canceled` even before Stripe says so.

## Setup

```bash
npm install && npm test
STRIPE_SECRET_KEY=sk_test_… npm run stripe-setup              # dry run
STRIPE_SECRET_KEY=sk_test_… npm run stripe-setup -- --apply \
  --webhook-url https://<worker host>/webhook --webhook-secret-file <path outside the repo>
```

The script creates, by stable handle and only when missing, the product
`ata_pro_mac`, the prices `ata_mac_monthly` / `ata_mac_yearly` /
`ata_mac_lifetime` (USD and EUR, tax-inclusive), a customer portal
configuration and the webhook endpoint, and prints the `[vars]` for
`wrangler.toml`. Run it with the test key and with the live key.

Then: `wrangler d1 create ata-licence` (its id into `wrangler.toml`),
`wrangler d1 migrations apply ata-licence --remote`,
`wrangler secret put STRIPE_SECRET_KEY`, `wrangler secret put STRIPE_WEBHOOK_SECRET`,
`wrangler deploy`. For `/v1/recover` to send mail, set `SMTP_HOST`
(`mail-eu.smtp2go.com`), `SMTP_PORT` (`465`), `SMTP_USER` and `EMAIL_FROM`,
and `wrangler secret put SMTP_PASSWORD`. The Cloudflare Email Sending binding
also works when `EMAIL` and `EMAIL_FROM` are set. Without either, recover
answers 200 and sends nothing.
