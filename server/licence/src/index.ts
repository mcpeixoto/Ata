// ata-licence: sells Ata Pro for Mac through Stripe and issues and checks the
// licence keys the Mac app activates (Sources/Ata/Licence.swift). Stripe has no
// licence keys of its own, so this Worker is the only place they exist.
//
// The Mac app is open source; this is a nudge for people who want to pay, not DRM.

import { emailHash, newKey, normaliseKey } from "./keys";
import { senderFor, type EmailSender } from "./email";
import { page, thanksPage, pendingPage, messagePage } from "./pages";
import {
  periodEnd,
  stripeClient,
  verifyStripeSignature,
  type CheckoutSession,
  type StripeApi,
  type Subscription,
} from "./stripe";

export interface Env {
  DB: D1Database;
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
  PRICE_MONTHLY: string;
  PRICE_YEARLY: string;
  PRICE_LIFETIME: string;
  PORTAL_CONFIGURATION?: string;
  AUTOMATIC_TAX?: string;
  EMAIL_FROM?: string;
  EMAIL?: SendEmail;
  LIMITER?: RateLimit;
}

export const PLANS = ["monthly", "yearly", "lifetime"] as const;
export type Plan = (typeof PLANS)[number];
export type Status = "active" | "past_due" | "canceled" | "refunded";

export const MAX_INSTANCES = 3;
/** A renewal's webhook can land a little after the period ends; don't lock anyone out for that. */
export const RENEWAL_GRACE = 3 * 86400;
const MAX_BODY = 2048;
const MAX_WEBHOOK_BODY = 1024 * 1024;

export interface Licence {
  key: string;
  customer: string;
  email_hash: string | null;
  plan: Plan;
  status: Status;
  expires_at: number | null;
  session: string;
  subscription: string | null;
  payment_intent: string | null;
  created_at: number;
}

export interface Deps {
  stripe(env: Env): StripeApi;
  email(env: Env): EmailSender;
  now(): number;
}

const defaultDeps: Deps = {
  stripe: (env) => stripeClient(env.STRIPE_SECRET_KEY),
  email: (env) => senderFor(env),
  now: () => Math.floor(Date.now() / 1000),
};

const unlocks = (s: Status) => s === "active" || s === "past_due";

/** What the key is worth right now, given what Stripe last told us. */
export function effectiveStatus(l: Pick<Licence, "plan" | "status" | "expires_at">, now: number): Status {
  if (l.plan === "lifetime") return l.status;
  if (unlocks(l.status) && l.expires_at !== null && now > l.expires_at + RENEWAL_GRACE) return "canceled";
  return l.status;
}

/** Stripe's subscription status, folded into the four the app knows. */
export function mapSubscriptionStatus(s: string): Status {
  switch (s) {
    case "active":
    case "trialing":
      return "active";
    case "past_due":
    case "unpaid":
    case "incomplete":
      return "past_due";
    default:
      return "canceled"; // canceled, incomplete_expired, paused
  }
}

// Swift's ISO8601DateFormatter refuses fractional seconds by default.
const iso = (t: number | null) => (t === null ? null : new Date(t * 1000).toISOString().replace(/\.\d{3}Z$/, "Z"));

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const html = (body: string, status = 200) =>
  new Response(body, { status, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } });

const getLicence = (env: Env, key: string) =>
  env.DB.prepare("SELECT * FROM licences WHERE key = ?1").bind(key).first<Licence>();

const bySession = (env: Env, session: string) =>
  env.DB.prepare("SELECT * FROM licences WHERE session = ?1").bind(session).first<Licence>();

function planOf(session: CheckoutSession): Plan {
  const p = session.metadata?.plan;
  if (PLANS.includes(p as Plan)) return p as Plan;
  return session.mode === "payment" ? "lifetime" : "monthly";
}

/**
 * The key for a paid Checkout Session, made on first sight. Both the webhook
 * and /thanks call this, whichever comes first, and the session id makes it
 * happen once. Null while the payment hasn't gone through.
 */
export async function issueLicence(env: Env, stripe: StripeApi, session: CheckoutSession, now: number): Promise<Licence | null> {
  if (session.status !== "complete" || session.payment_status === "unpaid") return null;
  const existing = await bySession(env, session.id);
  if (existing) return existing;

  const plan = planOf(session);
  const subscription = session.subscription ?? null;
  let expires: number | null = null;
  let status: Status = "active";
  if (subscription) {
    const sub = await stripe.getSubscription(subscription);
    expires = periodEnd(sub);
    status = mapSubscriptionStatus(sub.status);
  }
  const email = session.customer_details?.email;
  await env.DB.prepare(
    `INSERT INTO licences (key, customer, email_hash, plan, status, expires_at, session, subscription, payment_intent, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
     ON CONFLICT (session) DO NOTHING`,
  )
    .bind(newKey(), session.customer ?? "", email ? await emailHash(email) : null, plan, status,
          plan === "lifetime" ? null : expires, session.id, subscription, session.payment_intent ?? null, now)
    .run();
  return bySession(env, session.id);
}

async function applySubscription(env: Env, sub: Subscription, deleted: boolean) {
  const status = deleted ? "canceled" : mapSubscriptionStatus(sub.status);
  const expires = deleted ? (sub.ended_at ?? periodEnd(sub)) : periodEnd(sub);
  // A refund is final; a later subscription event doesn't undo it.
  await env.DB.prepare(
    "UPDATE licences SET status = ?1, expires_at = COALESCE(?2, expires_at) WHERE subscription = ?3 AND status != 'refunded'",
  ).bind(status, expires, sub.id).run();
}

interface StripeEvent {
  type: string;
  data: { object: Record<string, any> };
}

async function handleEvent(env: Env, deps: Deps, event: StripeEvent) {
  const obj = event.data.object;
  switch (event.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded":
      await issueLicence(env, deps.stripe(env), obj as CheckoutSession, deps.now());
      break;
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
      await applySubscription(env, obj as Subscription, event.type === "customer.subscription.deleted");
      break;
    case "invoice.payment_failed": {
      // Before API 2025-03-31 the invoice named its subscription directly.
      const sub: string | undefined = obj.subscription ?? obj.parent?.subscription_details?.subscription;
      if (typeof sub === "string") {
        await env.DB.prepare("UPDATE licences SET status = 'past_due' WHERE subscription = ?1 AND status = 'active'").bind(sub).run();
      }
      break;
    }
    case "charge.refunded": {
      // Only a full refund takes the key away.
      if (!obj.refunded) break;
      const pi: string | undefined = typeof obj.payment_intent === "string" ? obj.payment_intent : undefined;
      let res = pi
        ? await env.DB.prepare("UPDATE licences SET status = 'refunded' WHERE payment_intent = ?1").bind(pi).run()
        : null;
      // A subscription's charge isn't tied to the checkout's payment intent; if the
      // customer bought exactly one licence, that is the one refunded.
      if ((!res || res.meta.changes === 0) && typeof obj.customer === "string") {
        const rows = await env.DB.prepare("SELECT key FROM licences WHERE customer = ?1").bind(obj.customer).all<{ key: string }>();
        if (rows.results.length === 1) {
          res = await env.DB.prepare("UPDATE licences SET status = 'refunded' WHERE key = ?1").bind(rows.results[0].key).run();
        }
      }
      break;
    }
  }
}

async function readJSON(request: Request): Promise<Record<string, unknown> | null> {
  if (request.method !== "POST") return null;
  const text = await request.text();
  if (text.length > MAX_BODY) return null;
  try {
    const v = JSON.parse(text);
    return typeof v === "object" && v !== null && !Array.isArray(v) ? v : null;
  } catch {
    return null;
  }
}

function licenceBody(l: Licence, now: number, instance: string | null) {
  const status = effectiveStatus(l, now);
  return { ok: unlocks(status), instance_id: instance, status, plan: l.plan, expires_at: iso(l.plan === "lifetime" ? null : l.expires_at) };
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,63}$/;

async function api(path: string, request: Request, env: Env, deps: Deps, ctx: ExecutionContext): Promise<Response> {
  const body = await readJSON(request);
  const now = deps.now();

  if (path === "/v1/recover") {
    // Always 200 and always the same body, whatever was sent, so nobody can learn
    // which emails bought Ata. The email goes out after the response.
    const email = typeof body?.email === "string" ? body.email.trim() : "";
    if (EMAIL.test(email)) ctx.waitUntil(sendKeys(env, deps, email, now).catch(() => {}));
    return json({ ok: true });
  }

  if (request.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  if (!body) return json({ ok: false, error: "bad_request" }, 400);

  const key = normaliseKey(body.key);
  if (!key) return json({ ok: false, error: "bad_key" }, 400);
  const licence = await getLicence(env, key);
  if (!licence) return json({ ok: false, error: "not_found" }, 404);

  switch (path) {
    case "/v1/activate": {
      const name = typeof body.instance_name === "string" ? body.instance_name.trim() : "";
      if (!name || name.length > 100) return json({ ok: false, error: "bad_request" }, 400);
      const reply = licenceBody(licence, now, null);
      if (!reply.ok) return json(reply, 403);
      const id = crypto.randomUUID();
      // Count and insert in one statement, so two Macs racing can't both be the third.
      const res = await env.DB.prepare(
        `INSERT INTO instances (id, key, name, created_at)
         SELECT ?1, ?2, ?3, ?4 WHERE (SELECT COUNT(*) FROM instances WHERE key = ?2) < ?5`,
      ).bind(id, key, name, now, MAX_INSTANCES).run();
      if (res.meta.changes === 0) return json({ ...reply, ok: false, error: "too_many_instances" }, 409);
      return json({ ...reply, instance_id: id });
    }
    case "/v1/validate": {
      const id = typeof body.instance_id === "string" && UUID.test(body.instance_id) ? body.instance_id : null;
      if (!id) return json({ ok: false, error: "bad_request" }, 400);
      const inst = await env.DB.prepare("SELECT id FROM instances WHERE id = ?1 AND key = ?2").bind(id, key).first();
      if (!inst) return json({ ok: false, error: "unknown_instance" }, 404);
      return json(licenceBody(licence, now, id));
    }
    case "/v1/deactivate": {
      const id = typeof body.instance_id === "string" && UUID.test(body.instance_id) ? body.instance_id : null;
      if (!id) return json({ ok: false, error: "bad_request" }, 400);
      await env.DB.prepare("DELETE FROM instances WHERE id = ?1 AND key = ?2").bind(id, key).run();
      return json({ ...licenceBody(licence, now, null), ok: true });
    }
  }
  return json({ ok: false, error: "not_found" }, 404);
}

async function sendKeys(env: Env, deps: Deps, email: string, now: number) {
  const rows = await env.DB.prepare("SELECT * FROM licences WHERE email_hash = ?1 ORDER BY created_at")
    .bind(await emailHash(email)).all<Licence>();
  const live = rows.results.filter((l) => unlocks(effectiveStatus(l, now)));
  if (live.length === 0) return; // Nothing to say, and nothing that could be used to spam a stranger.
  const lines = live.map((l) => `${l.key}  (${l.plan})`);
  const text = `Your Ata Pro licence ${live.length === 1 ? "key" : "keys"}:\n\n${lines.join("\n")}\n\n` +
    "Paste it into Ata on your Mac when it asks for a licence key.\n\n" +
    "You asked for this from the Ata app. If you didn't, you can ignore it.\n";
  await deps.email(env).send({
    to: email,
    subject: "Your Ata Pro licence key",
    text,
    html: page("Your Ata Pro licence", `<p>Your licence ${live.length === 1 ? "key" : "keys"}:</p>` +
      live.map((l) => `<p class="key">${l.key}</p>`).join("") +
      "<p>Paste it into Ata on your Mac when it asks for a licence key.</p>" +
      "<p class=\"muted\">You asked for this from the Ata app. If you didn't, you can ignore it.</p>"),
  });
}

async function webhook(request: Request, env: Env, deps: Deps): Promise<Response> {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  const payload = await request.text();
  if (payload.length > MAX_WEBHOOK_BODY) return new Response(null, { status: 413 });
  const ok = await verifyStripeSignature(payload, request.headers.get("Stripe-Signature"), env.STRIPE_WEBHOOK_SECRET, deps.now());
  if (!ok) return new Response("bad signature", { status: 400 });
  let event: StripeEvent;
  try {
    event = JSON.parse(payload);
  } catch {
    return new Response(null, { status: 400 });
  }
  // A throw here answers 500, and Stripe retries the event later.
  await handleEvent(env, deps, event);
  return json({ received: true });
}

function priceFor(env: Env, plan: Plan): string {
  return plan === "monthly" ? env.PRICE_MONTHLY : plan === "yearly" ? env.PRICE_YEARLY : env.PRICE_LIFETIME;
}

async function site(url: URL, env: Env, deps: Deps): Promise<Response> {
  const origin = url.origin;
  switch (url.pathname) {
    case "/buy": {
      const plan = url.searchParams.get("plan") as Plan;
      if (!PLANS.includes(plan)) return html(messagePage("Unknown plan", "Choose monthly, yearly or lifetime in Ata."), 400);
      const price = priceFor(env, plan);
      if (!price) return html(messagePage("Not on sale yet", "Ata Pro for Mac isn't on sale yet. Try again later."), 503);
      const session = await deps.stripe(env).createCheckoutSession({
        mode: plan === "lifetime" ? "payment" : "subscription",
        price,
        plan,
        successURL: `${origin}/thanks?session_id={CHECKOUT_SESSION_ID}`,
        cancelURL: `${origin}/cancel`,
        automaticTax: env.AUTOMATIC_TAX === "true",
      });
      return Response.redirect(session.url, 303);
    }
    case "/thanks": {
      const id = url.searchParams.get("session_id") ?? "";
      if (!/^cs_[A-Za-z0-9_]{1,200}$/.test(id)) return html(messagePage("Nothing here", "This link doesn't belong to a purchase."), 404);
      const stripe = deps.stripe(env);
      let session: CheckoutSession;
      try {
        session = await stripe.getCheckoutSession(id);
      } catch {
        return html(messagePage("Nothing here", "This link doesn't belong to a purchase."), 404);
      }
      const licence = await issueLicence(env, stripe, session, deps.now());
      if (!licence) return html(pendingPage());
      return html(thanksPage(licence.key, licence.plan, licence.plan !== "lifetime" ? `${origin}/portal?key=${licence.key}` : null));
    }
    case "/portal": {
      const key = normaliseKey(url.searchParams.get("key"));
      const licence = key ? await getLicence(env, key) : null;
      if (!licence || !licence.customer) return html(messagePage("Nothing here", "That licence key wasn't found."), 404);
      const portal = await deps.stripe(env).createPortalSession(licence.customer, `${origin}/done`, env.PORTAL_CONFIGURATION);
      return Response.redirect(portal.url, 303);
    }
    case "/cancel":
      return html(messagePage("Checkout cancelled", "Nothing was charged. You can close this tab."));
    case "/done":
      return html(messagePage("All set", "You can close this tab and go back to Ata."));
  }
  return html(messagePage("Nothing here", "This page doesn't exist."), 404);
}

export function createHandler(overrides: Partial<Deps> = {}): ExportedHandler<Env> {
  const deps: Deps = { ...defaultDeps, ...overrides };
  return {
    async fetch(request, env, ctx) {
      const url = new URL(request.url);
      if (url.pathname === "/webhook") return webhook(request, env, deps);
      if (url.pathname.startsWith("/v1/")) {
        if (env.LIMITER) {
          const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
          const { success } = await env.LIMITER.limit({ key: ip });
          if (!success) return json({ ok: false, error: "rate_limited" }, 429);
        }
        return api(url.pathname, request, env, deps, ctx);
      }
      if (request.method !== "GET") return new Response(null, { status: 405 });
      return site(url, env, deps);
    },
  };
}

export default createHandler() satisfies ExportedHandler<Env>;
