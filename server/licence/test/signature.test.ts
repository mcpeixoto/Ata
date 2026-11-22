import { describe, expect, it } from "vitest";
import { formEncode, hmacSHA256Hex, signStripePayload, verifyStripeSignature } from "../src/stripe";
import { emailHash, newKey, normaliseKey } from "../src/keys";

const SECRET = "whsec_test_secret";
const T = 1_800_000_000;
const PAYLOAD = '{"id":"evt_1","type":"checkout.session.completed"}';

describe("HMAC-SHA256", () => {
  it("matches RFC 4231 test case 2", async () => {
    expect(await hmacSHA256Hex("Jefe", "what do ya want for nothing?"))
      .toBe("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
  });
});

describe("Stripe-Signature", () => {
  it("accepts a header Stripe would send", async () => {
    const header = await signStripePayload(PAYLOAD, SECRET, T);
    expect(header).toMatch(/^t=1800000000,v1=[0-9a-f]{64}$/);
    expect(await verifyStripeSignature(PAYLOAD, header, SECRET, T + 10)).toBe(true);
  });

  it("signs `t.payload` with the whole whsec_ string as the key", async () => {
    const v1 = await hmacSHA256Hex(SECRET, `${T}.${PAYLOAD}`);
    expect(await verifyStripeSignature(PAYLOAD, `t=${T},v1=${v1}`, SECRET, T)).toBe(true);
    const withoutPrefix = await hmacSHA256Hex("test_secret", `${T}.${PAYLOAD}`);
    expect(await verifyStripeSignature(PAYLOAD, `t=${T},v1=${withoutPrefix}`, SECRET, T)).toBe(false);
  });

  it("accepts any one of several v1 signatures, as while a secret is rolled", async () => {
    const good = (await signStripePayload(PAYLOAD, SECRET, T)).split("v1=")[1];
    const header = `t=${T},v1=${"0".repeat(64)},v1=${good},v0=deadbeef`;
    expect(await verifyStripeSignature(PAYLOAD, header, SECRET, T)).toBe(true);
  });

  it.each([
    ["no header", null],
    ["an empty header", ""],
    ["no timestamp", `v1=${"a".repeat(64)}`],
    ["no v1", `t=${T},v0=${"a".repeat(64)}`],
    ["garbage", "hello"],
  ])("refuses %s", async (_, header) => {
    expect(await verifyStripeSignature(PAYLOAD, header, SECRET, T)).toBe(false);
  });

  it("refuses another secret", async () => {
    const header = await signStripePayload(PAYLOAD, "whsec_other", T);
    expect(await verifyStripeSignature(PAYLOAD, header, SECRET, T)).toBe(false);
  });

  it("refuses a changed body", async () => {
    const header = await signStripePayload(PAYLOAD, SECRET, T);
    expect(await verifyStripeSignature(PAYLOAD.replace("evt_1", "evt_2"), header, SECRET, T)).toBe(false);
  });

  it("refuses a timestamp more than five minutes off, so a captured event can't be replayed", async () => {
    const header = await signStripePayload(PAYLOAD, SECRET, T);
    expect(await verifyStripeSignature(PAYLOAD, header, SECRET, T + 301)).toBe(false);
    expect(await verifyStripeSignature(PAYLOAD, header, SECRET, T - 301)).toBe(false);
    expect(await verifyStripeSignature(PAYLOAD, header, SECRET, T + 300)).toBe(true);
  });

  it("refuses everything when no secret is configured", async () => {
    const header = await signStripePayload(PAYLOAD, SECRET, T);
    expect(await verifyStripeSignature(PAYLOAD, header, "", T)).toBe(false);
  });
});

describe("keys", () => {
  it("are ATA-XXXX-XXXX-XXXX-XXXX in Crockford base32", () => {
    const keys = new Set(Array.from({ length: 200 }, newKey));
    expect(keys.size).toBe(200);
    for (const k of keys) expect(k).toMatch(/^ATA(-[0-9A-HJKMNP-TV-Z]{4}){4}$/);
  });

  it("normalise what a person types", () => {
    expect(normaliseKey("ata-abcd-efgh-jkmn-pqrs")).toBe("ATA-ABCD-EFGH-JKMN-PQRS");
    expect(normaliseKey(" ATA ABCD EFGH JKMN PQRS ")).toBe("ATA-ABCD-EFGH-JKMN-PQRS");
    expect(normaliseKey("ABCDEFGHJKMNPQRS")).toBe("ATA-ABCD-EFGH-JKMN-PQRS");
    expect(normaliseKey("ATA-0OIL-0000-0000-0000")).toBe("ATA-0011-0000-0000-0000");
    expect(normaliseKey("ATA-ABCD-EFGH-JKMN-PQRU")).toBeNull(); // U isn't in the alphabet
    expect(normaliseKey("ATA-ABCD")).toBeNull();
    expect(normaliseKey(42)).toBeNull();
  });

  it("hash emails case- and space-insensitively", async () => {
    expect(await emailHash(" Buyer@Example.com ")).toBe(await emailHash("buyer@example.com"));
    expect(await emailHash("buyer@example.com")).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe("formEncode", () => {
  it("nests like Stripe expects", () => {
    expect(formEncode({ mode: "payment", line_items: [{ price: "price_1", quantity: 1 }], metadata: { plan: "lifetime" }, skip: undefined }))
      .toBe("mode=payment&line_items%5B0%5D%5Bprice%5D=price_1&line_items%5B0%5D%5Bquantity%5D=1&metadata%5Bplan%5D=lifetime");
  });
});
