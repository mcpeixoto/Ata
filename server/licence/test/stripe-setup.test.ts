import { describe, expect, it } from "vitest";
import { PRICES, PRODUCT_ID, WEBHOOK_EVENTS, plan, type StripeCall } from "../scripts/stripe-plan";

/** An in-memory Stripe account, enough for the setup script. */
function account(opts: { tax?: boolean } = {}) {
  const products = new Map<string, any>();
  const prices: any[] = [];
  const portals: any[] = [];
  const hooks: any[] = [];
  const posts: { path: string; params: any }[] = [];
  let n = 0;

  const call: StripeCall = async (method, path, params = {}) => {
    const p = params as any;
    if (method === "POST") posts.push({ path, params: p });
    if (method === "GET" && path === `/products/${PRODUCT_ID}`) {
      const prod = products.get(PRODUCT_ID);
      return prod ? { status: 200, body: prod } : { status: 404, body: { error: { message: "No such product" } } };
    }
    if (method === "POST" && path === "/products") {
      products.set(p.id, { id: p.id, name: p.name, active: true });
      return { status: 200, body: products.get(p.id) };
    }
    if (method === "GET" && path === "/tax/settings") return { status: 200, body: { status: opts.tax ? "active" : "pending" } };
    if (method === "GET" && path === "/prices") {
      return { status: 200, body: { data: prices.filter((x) => p.lookup_keys.includes(x.lookup_key)) } };
    }
    if (method === "POST" && path === "/prices") {
      if (p.transfer_lookup_key) for (const x of prices) if (x.lookup_key === p.lookup_key) x.lookup_key = null;
      const price = {
        id: `price_${++n}`, active: true, product: p.product, currency: p.currency, unit_amount: p.unit_amount,
        tax_behavior: p.tax_behavior, lookup_key: p.lookup_key,
        type: p.recurring ? "recurring" : "one_time", recurring: p.recurring ?? null,
        currency_options: { eur: { unit_amount: p.currency_options.eur.unit_amount, tax_behavior: p.currency_options.eur.tax_behavior } },
      };
      prices.push(price);
      return { status: 200, body: price };
    }
    if (method === "GET" && path === "/billing_portal/configurations") return { status: 200, body: { data: portals } };
    if (method === "POST" && path === "/billing_portal/configurations") {
      const c = { id: `bpc_${++n}`, active: true, ...p };
      portals.push(c);
      return { status: 200, body: c };
    }
    if (method === "GET" && path === "/webhook_endpoints") return { status: 200, body: { data: hooks } };
    if (method === "POST" && path === "/webhook_endpoints") {
      const h = { id: `we_${++n}`, status: "enabled", secret: "whsec_new", ...p };
      hooks.push(h);
      return { status: 200, body: h };
    }
    return { status: 400, body: { error: { message: `unexpected ${method} ${path}` } } };
  };
  return { call, products, prices, portals, hooks, posts };
}

const URL = "https://ata-licence.example.workers.dev/webhook";

describe("stripe-setup", () => {
  it("dry run reads and writes nothing", async () => {
    const a = account();
    const r = await plan(a.call, { apply: false, webhookURL: URL });
    expect(a.posts).toHaveLength(0);
    expect(r.actions).toHaveLength(6); // product, 3 prices, portal, webhook
  });

  it("apply creates the product, three prices in USD and EUR, the portal and the webhook", async () => {
    const a = account();
    const secrets: string[] = [];
    const r = await plan(a.call, { apply: true, webhookURL: URL, saveWebhookSecret: async (s) => void secrets.push(s) });

    expect(a.products.get(PRODUCT_ID)).toMatchObject({ name: "Ata Pro for Mac" });
    expect(a.prices.map((p) => [p.lookup_key, p.unit_amount, p.currency_options.eur.unit_amount, p.recurring?.interval ?? null]))
      .toEqual([["ata_mac_monthly", 699, 699, "month"], ["ata_mac_yearly", 4499, 4499, "year"], ["ata_mac_lifetime", 9900, 9900, null]]);
    expect(a.prices.every((p) => p.tax_behavior === "exclusive" && p.currency_options.eur.tax_behavior === "inclusive")).toBe(true);
    expect(a.portals[0].features).toMatchObject({ subscription_cancel: { enabled: true, mode: "at_period_end" }, payment_method_update: { enabled: true } });
    expect(a.hooks[0]).toMatchObject({ url: URL, enabled_events: WEBHOOK_EVENTS });
    expect(secrets).toEqual(["whsec_new"]);
    expect(r.vars).toEqual({
      AUTOMATIC_TAX: "false",
      PRICE_MONTHLY: a.prices[0].id,
      PRICE_YEARLY: a.prices[1].id,
      PRICE_LIFETIME: a.prices[2].id,
      PORTAL_CONFIGURATION: a.portals[0].id,
    });
  });

  it("a second run changes nothing and reports the same ids", async () => {
    const a = account();
    const first = await plan(a.call, { apply: true, webhookURL: URL, saveWebhookSecret: async () => {} });
    const posts = a.posts.length;
    const second = await plan(a.call, { apply: true, webhookURL: URL });
    expect(a.posts.length).toBe(posts);
    expect(second.actions).toEqual([]);
    expect(second.vars).toEqual(first.vars);
  });

  it("replaces a price whose amount changed, moving its lookup_key", async () => {
    const a = account();
    await plan(a.call, { apply: true });
    a.prices[0].unit_amount = 599;
    const r = await plan(a.call, { apply: true });
    expect(r.actions).toHaveLength(1);
    expect(a.posts.at(-1)).toMatchObject({ path: "/prices", params: { lookup_key: "ata_mac_monthly", transfer_lookup_key: true, unit_amount: 699 } });
    expect(r.vars.PRICE_MONTHLY).toBe(a.prices.at(-1).id);
  });

  it("turns automatic tax on only when Stripe Tax is active", async () => {
    expect((await plan(account({ tax: true }).call, { apply: false })).vars.AUTOMATIC_TAX).toBe("true");
    expect((await plan(account().call, { apply: false })).vars.AUTOMATIC_TAX).toBe("false");
  });

  it("won't create a webhook it can't keep the secret of", async () => {
    const a = account();
    await expect(plan(a.call, { apply: true, webhookURL: URL })).rejects.toThrow(/webhook-secret-file/);
    expect(a.posts).toHaveLength(0);
  });

  it("matches the plan's prices", () => {
    expect(PRICES.map((p) => p.amount)).toEqual([699, 4499, 9900]);
  });
});
