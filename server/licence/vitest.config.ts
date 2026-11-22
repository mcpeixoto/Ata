import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import path from "node:path";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest(async () => ({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: await readD1Migrations(path.join(__dirname, "migrations")),
          STRIPE_SECRET_KEY: "sk_test_fake",
          STRIPE_WEBHOOK_SECRET: "whsec_test_secret",
          PRICE_MONTHLY: "price_monthly",
          PRICE_YEARLY: "price_yearly",
          PRICE_LIFETIME: "price_lifetime",
          // wrangler.toml carries the live deploy values; tests pin their own.
          AUTOMATIC_TAX: "false",
          PORTAL_CONFIGURATION: "",
          EMAIL_FROM: "licence@ata.test",
        },
      },
    })),
  ],
  test: { setupFiles: ["./test/apply-migrations.ts"] },
});
