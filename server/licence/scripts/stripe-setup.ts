// Sets up Ata Pro for Mac in the Stripe account whose key is in STRIPE_SECRET_KEY:
// the product, the three prices (by lookup_key), the customer portal, and the
// webhook to the Worker. Safe to run again; it only adds what is missing.
//
//   STRIPE_SECRET_KEY=sk_test_… npm run stripe-setup                       # dry run: reads, changes nothing
//   STRIPE_SECRET_KEY=sk_test_… npm run stripe-setup -- --apply \
//     --webhook-url https://ata-licence.<account>.workers.dev/webhook \
//     --webhook-secret-file ~/.config/ata-licence/whsec-test                 # writes it 0600; never printed
//
// Run it once with the test key and once with the live key. The key is read only
// from the environment, never from a file in this repo, and never printed.

import { writeFile } from "node:fs/promises";
import { API_VERSION, formEncode, plan, type StripeCall } from "./stripe-plan.ts";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

async function main() {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) {
    console.error("STRIPE_SECRET_KEY is not set.");
    process.exit(2);
  }
  const apply = process.argv.includes("--apply");
  const webhookURL = arg("--webhook-url");
  const secretFile = arg("--webhook-secret-file");
  const mode = key.startsWith("sk_live_") || key.startsWith("rk_live_") ? "LIVE" : "test";

  const call: StripeCall = async (method, path, params) => {
    const encoded = params ? formEncode(params) : "";
    const url = `https://api.stripe.com/v1${path}${method === "GET" && encoded ? `?${encoded}` : ""}`;
    const res = await fetch(url, {
      method,
      headers: {
        Authorization: `Bearer ${key}`,
        "Stripe-Version": API_VERSION,
        ...(method === "POST" ? { "Content-Type": "application/x-www-form-urlencoded" } : {}),
      },
      body: method === "POST" ? encoded : undefined,
    });
    return { status: res.status, body: await res.json() };
  };

  const account = await call("GET", "/account");
  if (account.status !== 200) throw new Error(`GET /account: ${account.status} ${account.body?.error?.message ?? ""}`);
  const name = account.body.business_profile?.name ?? account.body.settings?.dashboard?.display_name ?? "(no name)";
  console.log(`Stripe account ${account.body.id} "${name}", ${mode} mode, ${apply ? "APPLYING" : "dry run"}`);

  const result = await plan(call, {
    apply,
    webhookURL,
    saveWebhookSecret: secretFile
      ? async (secret) => {
          await writeFile(secretFile, secret + "\n", { mode: 0o600 });
          console.log(`Webhook signing secret written to ${secretFile} (0600).`);
        }
      : undefined,
  });

  console.log(result.actions.length ? `\n${apply ? "Done" : "Would do"}:` : "\nNothing to change.");
  for (const a of result.actions) console.log(`  - ${a}`);
  for (const n of result.notes) console.log(`\nNote: ${n}`);
  console.log("\nWorker [vars] for wrangler.toml:");
  for (const [k, v] of Object.entries(result.vars)) console.log(`${k} = "${v}"`);
  if (!apply && result.actions.length) console.log("\nRun again with --apply to make these changes.");
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
