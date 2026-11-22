import { SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { DAY, NOW, harness, licences, lifetimeSession, resetDB, subscription, subscriptionSession } from "./helpers";

beforeEach(resetDB);

type H = ReturnType<typeof harness>;

async function buyMonthly(h: H, email = "buyer@example.com") {
  h.stripe.subscriptions.set("sub_1", subscription("sub_1", "active", NOW + 30 * DAY));
  await h.webhook({ type: "checkout.session.completed", data: { object: subscriptionSession("cs_test_1", "sub_1", "monthly", email) } });
  return (await licences())[0].key as string;
}

async function buyLifetime(h: H) {
  await h.webhook({ type: "checkout.session.completed", data: { object: lifetimeSession("cs_test_l", "pi_l") } });
  return (await licences())[0].key as string;
}

const activate = (h: H, key: string, name = "Miguel's MacBook Pro") => h.post("/v1/activate", { key, instance_name: name });

describe("/v1/activate", () => {
  it("activates and answers the agreed shape", async () => {
    const h = harness();
    const key = await buyMonthly(h);
    const res = await activate(h, key);
    expect(res.status).toBe(200);
    const body = await res.json<Record<string, unknown>>();
    expect(body).toEqual({
      ok: true,
      instance_id: expect.stringMatching(/^[0-9a-f-]{36}$/),
      status: "active",
      plan: "monthly",
      // Whole seconds: Swift's ISO8601DateFormatter refuses fractions by default.
      expires_at: new Date((NOW + 30 * DAY) * 1000).toISOString().replace(".000Z", "Z"),
    });
  });

  it("refuses a fourth Mac, and takes one again after a deactivation", async () => {
    const h = harness();
    const key = await buyMonthly(h);
    const ids: string[] = [];
    for (const n of ["one", "two", "three"]) {
      const res = await activate(h, key, n);
      expect(res.status).toBe(200);
      ids.push((await res.json<{ instance_id: string }>()).instance_id);
    }
    const fourth = await activate(h, key, "four");
    expect(fourth.status).toBe(409);
    expect(await fourth.json()).toMatchObject({ ok: false, error: "too_many_instances" });

    const off = await h.post("/v1/deactivate", { key, instance_id: ids[0] });
    expect(off.status).toBe(200);
    expect((await activate(h, key, "four")).status).toBe(200);
  });

  it("takes the key however it's typed", async () => {
    const h = harness();
    const key = await buyMonthly(h);
    expect((await activate(h, key.toLowerCase().replace(/-/g, " "))).status).toBe(200);
  });

  it("refuses a refunded key", async () => {
    const h = harness();
    const key = await buyLifetime(h);
    await h.webhook({ type: "charge.refunded", data: { object: { payment_intent: "pi_l", refunded: true } } });
    const res = await activate(h, key);
    expect(res.status).toBe(403);
    expect(await res.json()).toMatchObject({ ok: false, status: "refunded" });
  });

  it("answers 404 for a key that was never sold and 400 for one that can't be a key", async () => {
    const h = harness();
    expect((await activate(h, "ATA-0000-0000-0000-0000")).status).toBe(404);
    expect((await activate(h, "hello")).status).toBe(400);
    expect((await h.post("/v1/activate", "not json")).status).toBe(400);
    expect((await h.fetch("/v1/activate")).status).toBe(405);
  });
});

describe("/v1/validate", () => {
  it("still unlocks while past_due", async () => {
    const h = harness();
    const key = await buyMonthly(h);
    const { instance_id } = await (await activate(h, key)).json<{ instance_id: string }>();
    await h.webhook({ type: "invoice.payment_failed", data: { object: { subscription: "sub_1" } } });
    expect(await (await h.post("/v1/validate", { key, instance_id })).json()).toMatchObject({ ok: true, status: "past_due", instance_id });
  });

  it("says canceled once a subscription cancelled at period end is past that end", async () => {
    const h = harness();
    const key = await buyMonthly(h);
    const { instance_id } = await (await activate(h, key)).json<{ instance_id: string }>();
    // Cancelled in the portal: Stripe keeps it active until the period ends.
    await h.webhook({
      type: "customer.subscription.updated",
      data: { object: subscription("sub_1", "active", NOW + 30 * DAY, { cancel_at_period_end: true }) },
    });

    h.clock.now = NOW + 29 * DAY;
    expect(await (await h.post("/v1/validate", { key, instance_id })).json()).toMatchObject({ ok: true, status: "active" });

    h.clock.now = NOW + 34 * DAY;
    expect(await (await h.post("/v1/validate", { key, instance_id })).json()).toMatchObject({ ok: false, status: "canceled" });
  });

  it("says canceled after customer.subscription.deleted", async () => {
    const h = harness();
    const key = await buyMonthly(h);
    const { instance_id } = await (await activate(h, key)).json<{ instance_id: string }>();
    await h.webhook({ type: "customer.subscription.deleted", data: { object: subscription("sub_1", "canceled", NOW + 30 * DAY, { ended_at: NOW }) } });
    expect(await (await h.post("/v1/validate", { key, instance_id })).json()).toMatchObject({ ok: false, status: "canceled" });
  });

  it("lifetime never expires", async () => {
    const h = harness();
    const key = await buyLifetime(h);
    const { instance_id } = await (await activate(h, key)).json<{ instance_id: string }>();
    h.clock.now = NOW + 100 * 365 * DAY;
    expect(await (await h.post("/v1/validate", { key, instance_id })).json())
      .toEqual({ ok: true, instance_id, status: "active", plan: "lifetime", expires_at: null });
  });

  it("refuses an instance of another key or one that was deactivated", async () => {
    const h = harness();
    const key = await buyMonthly(h);
    const { instance_id } = await (await activate(h, key)).json<{ instance_id: string }>();
    await h.post("/v1/deactivate", { key, instance_id });
    expect((await h.post("/v1/validate", { key, instance_id })).status).toBe(404);
    expect((await h.post("/v1/validate", { key, instance_id: "x" })).status).toBe(400);
  });
});

describe("/v1/recover", () => {
  it("always answers 200 with the same body, sold or not", async () => {
    const h = harness();
    await buyMonthly(h, "buyer@example.com");
    const bodies = [
      { email: "buyer@example.com" },
      { email: "stranger@example.com" },
      { email: "not an email" },
      {},
      "not json",
    ];
    for (const b of bodies) {
      const res = await h.post("/v1/recover", b);
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ ok: true });
    }
    expect((await h.fetch("/v1/recover")).status).toBe(200);
  });

  it("emails the keys to the address that bought them, and nothing to anyone else", async () => {
    const h = harness();
    const key = await buyMonthly(h, "Buyer@Example.com");
    await h.post("/v1/recover", { email: "stranger@example.com" });
    expect(h.mails).toHaveLength(0);
    await h.post("/v1/recover", { email: " buyer@example.com " });
    expect(h.mails).toHaveLength(1);
    expect(h.mails[0].to).toBe("buyer@example.com");
    expect(h.mails[0].text).toContain(key);
    expect(h.mails[0].html).toContain(key);
  });

  it("doesn't send keys that no longer unlock", async () => {
    const h = harness();
    await buyLifetime(h);
    await h.webhook({ type: "charge.refunded", data: { object: { payment_intent: "pi_l", refunded: true } } });
    await h.post("/v1/recover", { email: "buyer@example.com" });
    expect(h.mails).toHaveLength(0);
  });

  it("stores no email address, only its hash", async () => {
    const h = harness();
    await buyMonthly(h, "buyer@example.com");
    expect(JSON.stringify(await licences())).not.toContain("buyer@example.com");
  });
});

describe("rate limit", () => {
  it("allows 10 requests a minute per IP on /v1/*", async () => {
    const hit = (ip: string) =>
      SELF.fetch("https://licence.test/v1/recover", {
        method: "POST",
        body: JSON.stringify({ email: "nobody@example.com" }),
        headers: { "CF-Connecting-IP": ip },
      });
    for (let i = 0; i < 10; i++) expect((await hit("203.0.113.7")).status).toBe(200);
    expect((await hit("203.0.113.7")).status).toBe(429);
    expect((await hit("203.0.113.8")).status).toBe(200);
  });
});
