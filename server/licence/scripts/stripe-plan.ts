// What Ata Pro for Mac needs in a Stripe account, and how to get there from what
// is already there. Pure: Stripe is reached only through the `call` it is given,
// so the CLI (stripe-setup.ts) and the tests share it. Every object is found by a
// stable handle (product id, price lookup_key, metadata, webhook URL), so running
// it twice changes nothing the second time.

export const API_VERSION = "2025-03-31.basil"; // the same as src/stripe.ts
export const PRODUCT_ID = "ata_pro_mac";
export const PRODUCT_NAME = "Ata Pro for Mac";
export const PORTAL_TAG = "ata_pro_mac";

export interface PriceSpec {
  lookup_key: string;
  /** Cents, in USD and in EUR alike. */
  amount: number;
  interval: "month" | "year" | null;
  variable: "PRICE_MONTHLY" | "PRICE_YEARLY" | "PRICE_LIFETIME";
}

export const PRICES: PriceSpec[] = [
  { lookup_key: "ata_mac_monthly", amount: 699, interval: "month", variable: "PRICE_MONTHLY" },
  { lookup_key: "ata_mac_yearly", amount: 4499, interval: "year", variable: "PRICE_YEARLY" },
  { lookup_key: "ata_mac_lifetime", amount: 9900, interval: null, variable: "PRICE_LIFETIME" },
];

/** What src/index.ts handles. */
export const WEBHOOK_EVENTS = [
  "checkout.session.completed",
  "checkout.session.async_payment_succeeded",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "invoice.payment_failed",
  "charge.refunded",
];

export interface StripeReply {
  status: number;
  body: any;
}
export type StripeCall = (method: "GET" | "POST", path: string, params?: Record<string, unknown>) => Promise<StripeReply>;

export interface Options {
  apply: boolean;
  webhookURL?: string;
  /** Called once with the signing secret of a webhook endpoint this run created. Stripe never shows it again. */
  saveWebhookSecret?: (secret: string) => Promise<void>;
}

export interface Result {
  /** What was done (apply) or would be done (dry run), one line each. */
  actions: string[];
  /** The Worker's [vars]. */
  vars: Record<string, string>;
  notes: string[];
}

/** Stripe's form encoding: `a[b]=…`, arrays as `a[0]=…`. */
export function formEncode(obj: Record<string, unknown>, prefix = ""): string {
  const parts: string[] = [];
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    const key = prefix ? `${prefix}[${k}]` : k;
    if (typeof v === "object") {
      const inner = formEncode(v as Record<string, unknown>, key);
      if (inner) parts.push(inner);
    } else {
      parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(v))}`);
    }
  }
  return parts.join("&");
}

async function must(call: StripeCall, method: "GET" | "POST", path: string, params?: Record<string, unknown>) {
  const r = await call(method, path, params);
  if (r.status < 200 || r.status >= 300) {
    throw new Error(`${method} ${path}: ${r.status} ${r.body?.error?.message ?? ""}`.trim());
  }
  return r.body;
}

export function priceMatches(p: any, spec: PriceSpec): boolean {
  return (
    p.active === true &&
    p.product === PRODUCT_ID &&
    p.currency === "usd" &&
    p.unit_amount === spec.amount &&
    p.tax_behavior === "exclusive" &&
    (spec.interval ? p.type === "recurring" && p.recurring?.interval === spec.interval && p.recurring?.interval_count === 1 : p.type === "one_time") &&
    p.currency_options?.eur?.unit_amount === spec.amount &&
    p.currency_options?.eur?.tax_behavior === "inclusive"
  );
}

export function priceParams(spec: PriceSpec, transfer: boolean): Record<string, unknown> {
  return {
    product: PRODUCT_ID,
    currency: "usd",
    unit_amount: spec.amount,
    // US prices are before sales tax, as US shoppers expect; euro prices include VAT, as EU law
    // requires for consumers. Stripe Tax, when on, adds US tax on top and takes VAT out of the euro price.
    tax_behavior: "exclusive",
    currency_options: { eur: { unit_amount: spec.amount, tax_behavior: "inclusive" } },
    recurring: spec.interval ? { interval: spec.interval, interval_count: 1 } : undefined,
    lookup_key: spec.lookup_key,
    transfer_lookup_key: transfer ? true : undefined,
    nickname: spec.lookup_key,
  };
}

export const PORTAL_PARAMS = {
  features: {
    subscription_cancel: { enabled: true, mode: "at_period_end", proration_behavior: "none" },
    payment_method_update: { enabled: true },
    invoice_history: { enabled: true },
    customer_update: { enabled: true, allowed_updates: ["email", "address", "tax_id"] },
  },
  metadata: { ata: PORTAL_TAG },
};

export async function plan(call: StripeCall, opts: Options): Promise<Result> {
  const actions: string[] = [];
  const notes: string[] = [];
  const vars: Record<string, string> = {};
  const act = async (line: string, run: () => Promise<void>) => {
    actions.push(line);
    if (opts.apply) await run();
  };

  // Checked before anything is written, so a run that would fail here changes nothing.
  const hooks: any[] = opts.webhookURL ? (await must(call, "GET", "/webhook_endpoints", { limit: 100 })).data : [];
  const hook = hooks.find((h) => h.url === opts.webhookURL);
  if (opts.webhookURL && !hook && opts.apply && !opts.saveWebhookSecret) {
    throw new Error("Creating the webhook needs --webhook-secret-file: Stripe shows its signing secret only once.");
  }

  // Product, by its fixed id.
  const product = await call("GET", `/products/${PRODUCT_ID}`);
  if (product.status === 404) {
    await act(`create product ${PRODUCT_ID} "${PRODUCT_NAME}"`, async () => {
      await must(call, "POST", "/products", { id: PRODUCT_ID, name: PRODUCT_NAME });
    });
  } else if (product.status !== 200) {
    throw new Error(`GET /products/${PRODUCT_ID}: ${product.status} ${product.body?.error?.message ?? ""}`.trim());
  } else if (product.body.name !== PRODUCT_NAME || product.body.active !== true) {
    await act(`update product ${PRODUCT_ID}: name "${PRODUCT_NAME}", active`, async () => {
      await must(call, "POST", `/products/${PRODUCT_ID}`, { name: PRODUCT_NAME, active: true });
    });
  }

  // Stripe Tax: on only when the account has it set up.
  const tax = await call("GET", "/tax/settings");
  const taxActive = tax.status === 200 && tax.body?.status === "active";
  vars.AUTOMATIC_TAX = taxActive ? "true" : "false";
  notes.push(taxActive
    ? "Stripe Tax is active: Checkout adds US sales tax on top and takes VAT out of the euro prices."
    : "Stripe Tax is not active: no tax is calculated; euro prices are tax-inclusive, dollar prices exclusive.");

  // Prices, by lookup_key.
  const listed = await must(call, "GET", "/prices", {
    lookup_keys: PRICES.map((p) => p.lookup_key),
    expand: ["data.currency_options"],
    limit: 100,
  });
  for (const spec of PRICES) {
    const existing = (listed.data as any[]).filter((p) => p.lookup_key === spec.lookup_key);
    const good = existing.find((p) => priceMatches(p, spec));
    if (good) {
      vars[spec.variable] = good.id;
      continue;
    }
    const what = `${spec.amount / 100} USD/EUR ${spec.interval ? `per ${spec.interval}` : "once"}`;
    const line = existing.length
      ? `create price ${spec.lookup_key} (${what}), moving the lookup_key off ${existing[0].id}, which differs`
      : `create price ${spec.lookup_key} (${what})`;
    vars[spec.variable] = "(created by --apply)";
    await act(line, async () => {
      const created = await must(call, "POST", "/prices", priceParams(spec, existing.length > 0));
      vars[spec.variable] = created.id;
    });
  }

  // Customer portal: cancel at period end, update the card.
  const configs = await must(call, "GET", "/billing_portal/configurations", { limit: 100 });
  const portal = (configs.data as any[]).find((c) => c.metadata?.ata === PORTAL_TAG && c.active);
  if (portal) {
    vars.PORTAL_CONFIGURATION = portal.id;
  } else {
    vars.PORTAL_CONFIGURATION = "(created by --apply)";
    await act("create customer portal configuration (cancel at period end, update card, invoices)", async () => {
      const created = await must(call, "POST", "/billing_portal/configurations", PORTAL_PARAMS);
      vars.PORTAL_CONFIGURATION = created.id;
    });
  }

  // Webhook endpoint, by URL. Only when the Worker's URL is known.
  if (!opts.webhookURL) {
    notes.push("No --webhook-url: the webhook endpoint was not checked.");
  } else {
    if (!hook) {
      await act(`create webhook ${opts.webhookURL} (${WEBHOOK_EVENTS.length} events, API ${API_VERSION})`, async () => {
        const created = await must(call, "POST", "/webhook_endpoints", {
          url: opts.webhookURL,
          enabled_events: WEBHOOK_EVENTS,
          api_version: API_VERSION,
          description: "ata-licence Worker",
          metadata: { ata: PORTAL_TAG },
        });
        await opts.saveWebhookSecret!(created.secret);
      });
    } else {
      const have = new Set<string>(hook.enabled_events);
      const same = have.size === WEBHOOK_EVENTS.length && WEBHOOK_EVENTS.every((e) => have.has(e));
      if (!same || hook.status !== "enabled") {
        await act(`update webhook ${hook.id}: events and enabled`, async () => {
          await must(call, "POST", `/webhook_endpoints/${hook.id}`, { enabled_events: WEBHOOK_EVENTS, disabled: false });
        });
      }
      if (hook.api_version && hook.api_version !== API_VERSION) {
        notes.push(`Webhook ${hook.id} is on API ${hook.api_version}, not ${API_VERSION}; the Worker reads both shapes it uses.`);
      }
      notes.push("The webhook already exists; its signing secret is the one already in STRIPE_WEBHOOK_SECRET.");
    }
  }

  return { actions, vars, notes };
}
