import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

const good = {
  id: "6f1c2a4e-1b2c-4d3e-8f9a-0b1c2d3e4f5a",
  platform: "mac",
  version: "2.9.0",
  build: "123",
  os: "26.1",
  locale: "pt-PT",
  meetings: 2,
  minutes: 45,
};

const post = (body: unknown, init: RequestInit = {}) =>
  SELF.fetch("https://metrics.test/v1/ping", {
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
    ...init,
  });

const rows = () => env.DB.prepare("SELECT * FROM pings ORDER BY day").all().then((r) => r.results);

describe("POST /v1/ping", () => {
  beforeEach(() => env.DB.prepare("DELETE FROM pings").run());

  it("stores a ping", async () => {
    const res = await post(good);
    expect(res.status).toBe(204);
    const [row] = await rows();
    expect(row).toMatchObject({ id: good.id, platform: "mac", version: "2.9.0", meetings: 2, minutes: 45 });
    expect(row.day).toBe(new Date().toISOString().slice(0, 10));
  });

  it("adds a second ping on the same day to the first", async () => {
    await post(good);
    await post({ ...good, meetings: 1, minutes: 10, version: "2.9.1" });
    const all = await rows();
    expect(all).toHaveLength(1);
    expect(all[0]).toMatchObject({ meetings: 3, minutes: 55, version: "2.9.1" });
  });

  it("keeps another day in its own row", async () => {
    await env.DB.prepare(
      "INSERT INTO pings (id, day, platform, version, build, os, locale, meetings, minutes) VALUES (?, '2026-01-01', 'mac', '2.8.0', '1', '26.0', 'en', 5, 50)",
    ).bind(good.id).run();
    await post(good);
    expect(await rows()).toHaveLength(2);
  });

  it.each([
    ["not json", "nope"],
    ["an array", [good]],
    ["a bad id", { ...good, id: "me@example.com" }],
    ["an unknown platform", { ...good, platform: "android" }],
    ["an extra field", { ...good, name: "Miguel" }],
    ["a missing field", { ...good, locale: undefined }],
    ["a negative count", { ...good, minutes: -1 }],
    ["a huge count", { ...good, meetings: 10_001 }],
    ["a fractional count", { ...good, minutes: 1.5 }],
    ["free text in a short field", { ...good, version: "2.9 <script>" }],
  ])("refuses %s", async (_, body) => {
    expect((await post(body)).status).toBe(400);
    expect(await rows()).toHaveLength(0);
  });

  it("refuses a body over 1 KB", async () => {
    expect((await post(" ".repeat(2000))).status).toBe(413);
  });

  it("answers nothing else", async () => {
    expect((await SELF.fetch("https://metrics.test/v1/ping")).status).toBe(405);
    expect((await SELF.fetch("https://metrics.test/")).status).toBe(404);
  });
});
