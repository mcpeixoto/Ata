import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { createHandler, type Env } from "../src/index";
import type { Mail } from "../src/email";
import {
  signStripePayload,
  StripeError,
  type CheckoutParams,
  type CheckoutSession,
  type StripeApi,
  type Subscription,
} from "../src/stripe";

export const NOW = 1_800_000_000; // 2027-01-15
export const DAY = 86400;
export const SECRET = "whsec_test_secret";

/** Stands in for Stripe: holds sessions and subscriptions, records what was asked of it. */
export class FakeStripe implements StripeApi {
  sessions = new Map<string, CheckoutSession>();
  subscriptions = new Map<string, Subscription>();
  checkouts: CheckoutParams[] = [];
  portals: { customer: string; returnURL: string; configuration?: string }[] = [];

  async createCheckoutSession(p: CheckoutParams) {
    this.checkouts.push(p);
    return { url: "https://checkout.stripe.com/c/pay/cs_test_fake" };
  }
  async getCheckoutSession(id: string) {
    const s = this.sessions.get(id);
    if (!s) throw new StripeError(404, "No such checkout.session");
    return s;
  }
  async getSubscription(id: string) {
    const s = this.subscriptions.get(id);
    if (!s) throw new StripeError(404, "No such subscription");
    return s;
  }
  async createPortalSession(customer: string, returnURL: string, configuration?: string) {
    this.portals.push({ customer, returnURL, configuration });
    return { url: "https://billing.stripe.com/p/session/test_fake" };
  }
}

export function subscriptionSession(id: string, sub: string, plan = "monthly", email = "buyer@example.com"): CheckoutSession {
  return {
    id, mode: "subscription", status: "complete", payment_status: "paid", customer: `cus_${id}`,
    customer_details: { email }, subscription: sub, payment_intent: null, metadata: { plan },
  };
}

export function lifetimeSession(id: string, pi: string, email = "buyer@example.com"): CheckoutSession {
  return {
    id, mode: "payment", status: "complete", payment_status: "paid", customer: `cus_${id}`,
    customer_details: { email }, subscription: null, payment_intent: pi, metadata: { plan: "lifetime" },
  };
}

/** A subscription in the 2025-03-31 shape: the period end on the item. */
export function subscription(id: string, status: string, periodEnd: number, extra: Partial<Subscription> = {}): Subscription {
  return { id, status, items: { data: [{ current_period_end: periodEnd }] }, ...extra };
}

export function harness() {
  const stripe = new FakeStripe();
  const mails: Mail[] = [];
  const clock = { now: NOW };
  const handler = createHandler({
    stripe: () => stripe,
    email: () => ({ send: async (m: Mail) => void mails.push(m) }),
    now: () => clock.now,
  });
  // The rate limiter has its own test, through the real Worker.
  const testEnv = { ...env, LIMITER: undefined } as unknown as Env;

  async function fetch(path: string, init?: RequestInit) {
    const ctx = createExecutionContext();
    const req = new Request(`https://licence.test${path}`, init) as Parameters<NonNullable<typeof handler.fetch>>[0];
    const res = await handler.fetch!(req, testEnv, ctx);
    await waitOnExecutionContext(ctx);
    return res;
  }

  const post = (path: string, body: unknown) =>
    fetch(path, { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body) });

  async function webhook(event: { type: string; data: { object: unknown } }, opts: { secret?: string; t?: number } = {}) {
    const payload = JSON.stringify({ id: "evt_test", object: "event", ...event });
    const sig = await signStripePayload(payload, opts.secret ?? SECRET, opts.t ?? clock.now);
    return fetch("/webhook", { method: "POST", body: payload, headers: { "Stripe-Signature": sig } });
  }

  return { stripe, mails, clock, fetch, post, webhook };
}

export const licences = () =>
  env.DB.prepare("SELECT * FROM licences ORDER BY created_at, key").all<Record<string, any>>().then((r) => r.results);

export async function resetDB() {
  await env.DB.prepare("DELETE FROM instances").run();
  await env.DB.prepare("DELETE FROM licences").run();
}
