declare namespace Cloudflare {
  interface Env {
    DB: D1Database;
    STRIPE_SECRET_KEY: string;
    STRIPE_WEBHOOK_SECRET: string;
    PRICE_MONTHLY: string;
    PRICE_YEARLY: string;
    PRICE_LIFETIME: string;
    PORTAL_CONFIGURATION?: string;
    AUTOMATIC_TAX?: string;
    EMAIL_FROM?: string;
    LIMITER?: RateLimit;
    TEST_MIGRATIONS: import("@cloudflare/vitest-plugin").D1Migration[];
  }
}
