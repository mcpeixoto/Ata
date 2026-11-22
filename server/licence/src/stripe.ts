// The few Stripe calls the Worker makes, behind an interface so tests can stand
// in for Stripe. The secret key lives only in this Worker, never in the app.

/** Pinned so webhook payloads and API responses keep one shape. The setup script registers the webhook with the same version. */
export const STRIPE_API_VERSION = "2025-03-31.basil";

export interface CheckoutSession {
  id: string;
  mode: "payment" | "subscription" | "setup";
  status: "open" | "complete" | "expired" | null;
  payment_status: "paid" | "unpaid" | "no_payment_required";
  customer: string | null;
  customer_details?: { email?: string | null } | null;
  subscription?: string | null;
  payment_intent?: string | null;
  metadata?: Record<string, string> | null;
}

export interface Subscription {
  id: string;
  status: string;
  cancel_at_period_end?: boolean;
  ended_at?: number | null;
  /** Before API 2025-03-31 the period sat on the subscription; since, on each item. */
  current_period_end?: number;
  items?: { data: { current_period_end?: number }[] };
}

export interface CheckoutParams {
  mode: "payment" | "subscription";
  price: string;
  plan: string;
  successURL: string;
  cancelURL: string;
  automaticTax: boolean;
}

export interface StripeApi {
  createCheckoutSession(p: CheckoutParams): Promise<{ url: string }>;
  getCheckoutSession(id: string): Promise<CheckoutSession>;
  getSubscription(id: string): Promise<Subscription>;
  createPortalSession(customer: string, returnURL: string, configuration?: string): Promise<{ url: string }>;
}

/** Stripe's form encoding: nested keys as `a[b][c]`, arrays as `a[0]`. */
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

export class StripeError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

export function stripeClient(secretKey: string, fetcher: typeof fetch = fetch): StripeApi {
  async function call<T>(method: "GET" | "POST", path: string, body?: Record<string, unknown>): Promise<T> {
    const res = await fetcher(`https://api.stripe.com/v1${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${secretKey}`,
        "Stripe-Version": STRIPE_API_VERSION,
        ...(body ? { "Content-Type": "application/x-www-form-urlencoded" } : {}),
      },
      body: body ? formEncode(body) : undefined,
    });
    const json = (await res.json()) as T & { error?: { message?: string } };
    if (!res.ok) throw new StripeError(res.status, json.error?.message ?? `Stripe ${res.status}`);
    return json;
  }

  return {
    createCheckoutSession: (p) =>
      call("POST", "/checkout/sessions", {
        mode: p.mode,
        line_items: [{ price: p.price, quantity: 1 }],
        success_url: p.successURL,
        cancel_url: p.cancelURL,
        allow_promotion_codes: true,
        // Subscriptions always make a customer; Stripe refuses the flag there.
        customer_creation: p.mode === "payment" ? "always" : undefined,
        automatic_tax: p.automaticTax ? { enabled: true } : undefined,
        metadata: { plan: p.plan },
        subscription_data: p.mode === "subscription" ? { metadata: { plan: p.plan } } : undefined,
        payment_intent_data: p.mode === "payment" ? { metadata: { plan: p.plan } } : undefined,
      }),
    getCheckoutSession: (id) => call("GET", `/checkout/sessions/${encodeURIComponent(id)}`),
    getSubscription: (id) => call("GET", `/subscriptions/${encodeURIComponent(id)}`),
    createPortalSession: (customer, returnURL, configuration) =>
      call("POST", "/billing_portal/sessions", { customer, return_url: returnURL, configuration: configuration || undefined }),
  };
}

/** The end of the paid period, wherever this API version keeps it. */
export function periodEnd(sub: Subscription): number | null {
  const fromItems = sub.items?.data
    .map((i) => i.current_period_end)
    .filter((n): n is number => typeof n === "number");
  if (fromItems && fromItems.length) return Math.max(...fromItems);
  return typeof sub.current_period_end === "number" ? sub.current_period_end : null;
}

const encoder = new TextEncoder();

function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function hmacSHA256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
}

/** A `Stripe-Signature` header for `payload`, as Stripe would send it. Used by tests. */
export async function signStripePayload(payload: string, secret: string, timestamp: number): Promise<string> {
  return `t=${timestamp},v1=${await hmacSHA256Hex(secret, `${timestamp}.${payload}`)}`;
}

function constantTimeEqual(a: string, b: string): boolean {
  const x = encoder.encode(a);
  const y = encoder.encode(b);
  if (x.byteLength !== y.byteLength) return false;
  return crypto.subtle.timingSafeEqual(x, y);
}

/**
 * Stripe's webhook scheme: the header is `t=<unix seconds>,v1=<hex>[,v1=<hex>…]`
 * (several v1 entries while a secret is being rolled; v0 is a test-mode legacy
 * scheme and is ignored). Each v1 is HMAC-SHA256, keyed with the whole
 * `whsec_…` string, over `<t>.<raw body>`. A timestamp more than `tolerance`
 * seconds away from now is refused, so a captured request can't be replayed.
 */
export async function verifyStripeSignature(
  payload: string,
  header: string | null,
  secret: string,
  now = Math.floor(Date.now() / 1000),
  tolerance = 300,
): Promise<boolean> {
  if (!header || !secret) return false;
  let t: number | null = null;
  const v1: string[] = [];
  for (const part of header.split(",")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    const k = part.slice(0, i).trim();
    const v = part.slice(i + 1).trim();
    if (k === "t" && /^\d+$/.test(v)) t = Number(v);
    else if (k === "v1") v1.push(v);
  }
  if (t === null || v1.length === 0) return false;
  if (Math.abs(now - t) > tolerance) return false;
  const expected = await hmacSHA256Hex(secret, `${t}.${payload}`);
  return v1.some((sig) => constantTimeEqual(sig, expected));
}
