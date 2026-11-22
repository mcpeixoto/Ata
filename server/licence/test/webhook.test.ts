import { beforeEach, describe, expect, it } from "vitest";
import { DAY, NOW, harness, licences, lifetimeSession, resetDB, subscription, subscriptionSession } from "./helpers";

beforeEach(resetDB);

async function boughtMonthly(h: ReturnType<typeof harness>, id = "cs_test_1", sub = "sub_1") {
  h.stripe.subscriptions.set(sub, subscription(sub, "active", NOW + 30 * DAY));
  const res = await h.webhook({ type: "checkout.session.completed", data: { object: subscriptionSession(id, sub) } });
  expect(res.status).toBe(200);
  return (await licences()).find((l) => l.session === id)!;
}

describe("POST /webhook signature", () => {
  it("refuses an event signed with another secret, and stores nothing", async () => {
    const h = harness();
    const res = await h.webhook(
      { type: "checkout.session.completed", data: { object: lifetimeSession("cs_test_x", "pi_x") } },
      { secret: "whsec_attacker" },
    );
    expect(res.status).toBe(400);
    expect(await licences()).toHaveLength(0);
  });

  it("refuses an unsigned event", async () => {
    const h = harness();
    const res = await h.fetch("/webhook", { method: "POST", body: JSON.stringify({ type: "charge.refunded", data: { object: {} } }) });
    expect(res.status).toBe(400);
  });

  it("refuses a replayed event from an hour ago", async () => {
    const h = harness();
    const res = await h.webhook(
      { type: "checkout.session.completed", data: { object: lifetimeSession("cs_test_x", "pi_x") } },
      { t: NOW - 3600 },
    );
    expect(res.status).toBe(400);
  });

  it("accepts a correctly signed event", async () => {
    const h = harness();
    const res = await h.webhook({ type: "checkout.session.completed", data: { object: lifetimeSession("cs_test_x", "pi_x") } });
    expect(res.status).toBe(200);
    expect(await licences()).toHaveLength(1);
  });

  it("answers 200 to events it doesn't use, so Stripe stops retrying them", async () => {
    const h = harness();
    expect((await h.webhook({ type: "customer.created", data: { object: { id: "cus_1" } } })).status).toBe(200);
  });
});

describe("webhook events", () => {
  it("checkout.session.completed for a subscription issues an active key that expires with the period", async () => {
    const h = harness();
    const l = await boughtMonthly(h);
    expect(l).toMatchObject({ plan: "monthly", status: "active", expires_at: NOW + 30 * DAY, subscription: "sub_1", customer: "cus_cs_test_1" });
    expect(l.key).toMatch(/^ATA(-[0-9A-HJKMNP-TV-Z]{4}){4}$/);
    expect(l.email_hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("checkout.session.completed for lifetime issues a key that never expires", async () => {
    const h = harness();
    await h.webhook({ type: "checkout.session.completed", data: { object: lifetimeSession("cs_test_l", "pi_l") } });
    const [l] = await licences();
    expect(l).toMatchObject({ plan: "lifetime", status: "active", expires_at: null, payment_intent: "pi_l" });
  });

  it("issues one key per session, however often Stripe sends it", async () => {
    const h = harness();
    await boughtMonthly(h);
    await boughtMonthly(h);
    expect(await licences()).toHaveLength(1);
  });

  it("issues nothing for an unpaid session; async_payment_succeeded issues it later", async () => {
    const h = harness();
    const s = { ...lifetimeSession("cs_test_a", "pi_a"), payment_status: "unpaid" as const };
    await h.webhook({ type: "checkout.session.completed", data: { object: s } });
    expect(await licences()).toHaveLength(0);
    await h.webhook({ type: "checkout.session.async_payment_succeeded", data: { object: { ...s, payment_status: "paid" } } });
    expect(await licences()).toHaveLength(1);
  });

  it.each([
    ["active", "active"],
    ["trialing", "active"],
    ["past_due", "past_due"],
    ["unpaid", "past_due"],
    ["canceled", "canceled"],
    ["incomplete_expired", "canceled"],
  ])("customer.subscription.updated with Stripe status %s ⇒ %s", async (stripeStatus, expected) => {
    const h = harness();
    await boughtMonthly(h);
    await h.webhook({ type: "customer.subscription.updated", data: { object: subscription("sub_1", stripeStatus, NOW + 60 * DAY) } });
    const [l] = await licences();
    expect(l.status).toBe(expected);
    expect(l.expires_at).toBe(NOW + 60 * DAY);
  });

  it("customer.subscription.updated reads the period from a pre-2025 payload too", async () => {
    const h = harness();
    await boughtMonthly(h);
    await h.webhook({ type: "customer.subscription.updated", data: { object: { id: "sub_1", status: "active", current_period_end: NOW + 90 * DAY } } });
    expect((await licences())[0].expires_at).toBe(NOW + 90 * DAY);
  });

  it("customer.subscription.deleted ⇒ canceled, ending when the subscription ended", async () => {
    const h = harness();
    await boughtMonthly(h);
    await h.webhook({
      type: "customer.subscription.deleted",
      data: { object: subscription("sub_1", "canceled", NOW + 30 * DAY, { ended_at: NOW + DAY }) },
    });
    expect((await licences())[0]).toMatchObject({ status: "canceled", expires_at: NOW + DAY });
  });

  it("invoice.payment_failed ⇒ past_due, in the 2025 shape", async () => {
    const h = harness();
    await boughtMonthly(h);
    await h.webhook({
      type: "invoice.payment_failed",
      data: { object: { id: "in_1", parent: { subscription_details: { subscription: "sub_1" } } } },
    });
    expect((await licences())[0].status).toBe("past_due");
  });

  it("invoice.payment_failed ⇒ past_due, in the older shape", async () => {
    const h = harness();
    await boughtMonthly(h);
    await h.webhook({ type: "invoice.payment_failed", data: { object: { id: "in_1", subscription: "sub_1" } } });
    expect((await licences())[0].status).toBe("past_due");
  });

  it("charge.refunded in full ⇒ refunded, for lifetime", async () => {
    const h = harness();
    await h.webhook({ type: "checkout.session.completed", data: { object: lifetimeSession("cs_test_l", "pi_l") } });
    await h.webhook({ type: "charge.refunded", data: { object: { id: "ch_1", payment_intent: "pi_l", customer: "cus_cs_test_l", refunded: true } } });
    expect((await licences())[0].status).toBe("refunded");
  });

  it("charge.refunded in part changes nothing", async () => {
    const h = harness();
    await h.webhook({ type: "checkout.session.completed", data: { object: lifetimeSession("cs_test_l", "pi_l") } });
    await h.webhook({ type: "charge.refunded", data: { object: { id: "ch_1", payment_intent: "pi_l", refunded: false } } });
    expect((await licences())[0].status).toBe("active");
  });

  it("charge.refunded for a subscription's invoice refunds that customer's only key, and a later update doesn't undo it", async () => {
    const h = harness();
    await boughtMonthly(h);
    await h.webhook({ type: "charge.refunded", data: { object: { id: "ch_2", payment_intent: "pi_invoice", customer: "cus_cs_test_1", refunded: true } } });
    expect((await licences())[0].status).toBe("refunded");
    await h.webhook({ type: "customer.subscription.updated", data: { object: subscription("sub_1", "active", NOW + 60 * DAY) } });
    expect((await licences())[0].status).toBe("refunded");
  });
});
