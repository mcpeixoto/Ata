import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

const shared = {
  app: "polaris",
  id: "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
  platform: "ios",
  version: "1.4.0",
  build: "88",
  os: "26.1",
  locale: "en-GB",
  counts: { plans: 2, sessions: 3 },
};

const legacyAta = {
  id: shared.id,
  platform: "mac",
  version: "3.4.0",
  build: "340",
  os: "26.1",
  locale: "pt-PT",
  meetings: 1,
  minutes: 30,
};

const post = (body: unknown) =>
  SELF.fetch("https://metrics.test/v1/ping", {
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

const rows = () =>
  env.DB.prepare("SELECT * FROM pings ORDER BY app, day").all<Record<string, unknown>>().then((r) => r.results);

describe("every app on one Worker", () => {
  beforeEach(() => env.DB.prepare("DELETE FROM pings").run());

  it("stores another app's ping with its counters", async () => {
    expect((await post(shared)).status).toBe(204);
    const [row] = await rows();
    expect(row).toMatchObject({ app: "polaris", id: shared.id, platform: "ios", meetings: 0, minutes: 0 });
    expect(JSON.parse(row.counts as string)).toEqual({ plans: 2, sessions: 3 });
  });

  it("files Ata 3.4.0's ping, which names no app, under ata", async () => {
    expect((await post(legacyAta)).status).toBe(204);
    const [row] = await rows();
    expect(row).toMatchObject({ app: "ata", meetings: 1, minutes: 30, counts: "{}" });
  });

  it("adds a second ping the same day counter by counter", async () => {
    await post(shared);
    await post({ ...shared, version: "1.4.1", counts: { sessions: 1, exports: 4 } });
    const all = await rows();
    expect(all).toHaveLength(1);
    expect(all[0].version).toBe("1.4.1");
    expect(JSON.parse(all[0].counts as string)).toEqual({ plans: 2, sessions: 4, exports: 4 });
  });

  it("keeps the same id in two apps apart", async () => {
    await post(shared);
    await post({ ...shared, app: "cabin" });
    await post(legacyAta);
    expect((await rows()).map((r) => r.app)).toEqual(["ata", "cabin", "polaris"]);
  });

  it("accepts a ping with no counters", async () => {
    expect((await post({ ...shared, counts: {} })).status).toBe(204);
  });

  it.each([
    ["an unknown app", { ...shared, app: "someoneelse" }],
    ["no counts object", { ...shared, counts: undefined }],
    ["counts as an array", { ...shared, counts: [1, 2] }],
    ["a counter name with free text", { ...shared, counts: { "Miguel's plans": 1 } }],
    ["a negative counter", { ...shared, counts: { plans: -1 } }],
    ["a huge counter", { ...shared, counts: { plans: 10_001 } }],
    ["a fractional counter", { ...shared, counts: { plans: 0.5 } }],
    ["a string counter", { ...shared, counts: { plans: "2" } }],
    ["too many counters", { ...shared, counts: Object.fromEntries("abcdefghi".split("").map((k) => [k, 1])) }],
    ["both shapes at once", { ...shared, meetings: 1, minutes: 1 }],
    ["Ata's counters with an app", { ...legacyAta, app: "ata" }],
  ])("refuses %s", async (_, body) => {
    expect((await post(body)).status).toBe(400);
    expect(await rows()).toHaveLength(0);
  });
});
