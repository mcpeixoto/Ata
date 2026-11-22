import { beforeEach, describe, expect, it } from "vitest";
import { DAY, NOW, harness, licences, lifetimeSession, resetDB, subscription, subscriptionSession } from "./helpers";

beforeEach(resetDB);

describe("GET /buy", () => {
  it.each([
    ["monthly", "subscription", "price_monthly"],
    ["yearly", "subscription", "price_yearly"],
    ["lifetime", "payment", "price_lifetime"],
  ])("%s opens a %s Checkout Session for %s", async (plan, mode, price) => {
    const h = harness();
    const res = await h.fetch(`/buy?plan=${plan}`, { redirect: "manual" });
    expect(res.status).toBe(303);
    expect(res.headers.get("Location")).toBe("https://checkout.stripe.com/c/pay/cs_test_fake");
    expect(h.stripe.checkouts).toEqual([{
      mode, price, plan,
      successURL: "https://licence.test/thanks?session_id={CHECKOUT_SESSION_ID}",
      cancelURL: "https://licence.test/cancel",
      automaticTax: false,
    }]);
  });

  it("refuses an unknown plan", async () => {
    const h = harness();
    expect((await h.fetch("/buy?plan=forever")).status).toBe(400);
    expect(h.stripe.checkouts).toHaveLength(0);
  });
});

describe("GET /thanks", () => {
  it("shows the key and an Activate in Ata link, even before the webhook lands, and the webhook then issues no second key", async () => {
    const h = harness();
    h.stripe.subscriptions.set("sub_1", subscription("sub_1", "active", NOW + 365 * DAY));
    const session = subscriptionSession("cs_test_1", "sub_1", "yearly");
    h.stripe.sessions.set(session.id, session);

    const res = await h.fetch("/thanks?session_id=cs_test_1");
    expect(res.status).toBe(200);
    const page = await res.text();
    const [l] = await licences();
    expect(page).toContain(l.key);
    expect(page).toContain(`href="ata://licence?key=${l.key}"`);
    expect(page).toContain("Activate in Ata");
    expect(page).toContain(`/portal?key=${l.key}`);

    await h.webhook({ type: "checkout.session.completed", data: { object: session } });
    const all = await licences();
    expect(all).toHaveLength(1);
    expect(all[0].key).toBe(l.key);
    // Reloading the page shows the same key.
    expect(await (await h.fetch("/thanks?session_id=cs_test_1")).text()).toContain(l.key);
  });

  it("has no subscription link for lifetime", async () => {
    const h = harness();
    const session = lifetimeSession("cs_test_l", "pi_l");
    h.stripe.sessions.set(session.id, session);
    expect(await (await h.fetch("/thanks?session_id=cs_test_l")).text()).not.toContain("/portal");
  });

  it("waits while the payment is processing", async () => {
    const h = harness();
    h.stripe.sessions.set("cs_test_p", { ...lifetimeSession("cs_test_p", "pi_p"), payment_status: "unpaid" });
    const page = await (await h.fetch("/thanks?session_id=cs_test_p")).text();
    expect(page).toContain('http-equiv="refresh"');
    expect(await licences()).toHaveLength(0);
  });

  it("answers 404 for a session Stripe doesn't know or an id that isn't one", async () => {
    const h = harness();
    expect((await h.fetch("/thanks?session_id=cs_test_missing")).status).toBe(404);
    expect((await h.fetch("/thanks?session_id=<script>")).status).toBe(404);
  });
});

describe("GET /portal", () => {
  it("opens the Stripe customer portal for the key's customer", async () => {
    const h = harness();
    h.stripe.subscriptions.set("sub_1", subscription("sub_1", "active", NOW + 30 * DAY));
    await h.webhook({ type: "checkout.session.completed", data: { object: subscriptionSession("cs_test_1", "sub_1") } });
    const [l] = await licences();
    const res = await h.fetch(`/portal?key=${l.key}`, { redirect: "manual" });
    expect(res.status).toBe(303);
    expect(h.stripe.portals[0]).toMatchObject({ customer: "cus_cs_test_1", returnURL: "https://licence.test/done" });
  });

  it("answers 404 for an unknown key", async () => {
    const h = harness();
    expect((await h.fetch("/portal?key=ATA-0000-0000-0000-0000")).status).toBe(404);
    expect(h.stripe.portals).toHaveLength(0);
  });
});
