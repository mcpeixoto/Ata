import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

const id = "6f1c2a4e-1b2c-4d3e-8f9a-0b1c2d3e4f5a";
const id2 = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";

const ata = {
  id,
  platform: "ios",
  version: "4.0.0",
  build: "400",
  os: "26.1",
  locale: "pt-PT",
  meetings: 1,
  minutes: 12,
};

const post = (body: unknown) =>
  SELF.fetch("https://metrics.test/v1/ping", {
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

const rows = () =>
  env.DB.prepare("SELECT * FROM pings ORDER BY id").all<Record<string, unknown>>().then((r) => r.results);

describe("funnel and campaign", () => {
  beforeEach(() => env.DB.prepare("DELETE FROM pings").run());

  it("stores the optional funnel and campaign on an Ata ping", async () => {
    const res = await post({
      ...ata,
      campaign: "542370539",
      funnel: { onboardingStep: 4, "paywallShown.limit": 1, trialStarted: 1, "purchased.yearly": 1 },
    });
    expect(res.status).toBe(204);
    const [row] = await rows();
    expect(row).toMatchObject({ app: "ata", campaign: "542370539", meetings: 1 });
    expect(JSON.parse(row.funnel as string)).toEqual({
      onboardingStep: 4,
      "paywallShown.limit": 1,
      trialStarted: 1,
      "purchased.yearly": 1,
    });
  });

  it("keeps the highest onboarding step and adds the other counters", async () => {
    await post({ ...ata, campaign: "organic", funnel: { onboardingStep: 2, "paywallShown.limit": 1 } });
    await post({
      ...ata,
      version: "4.0.1",
      funnel: { onboardingStep: 5, "paywallShown.limit": 2, "featureLocked.askMeetings": 1 },
    });
    const [row] = await rows();
    expect(row.version).toBe("4.0.1");
    expect(row.campaign).toBe("organic");
    expect(JSON.parse(row.funnel as string)).toEqual({
      onboardingStep: 5,
      "paywallShown.limit": 3,
      "featureLocked.askMeetings": 1,
    });
  });

  it("keeps a campaign already stored when a later ping omits it", async () => {
    await post({ ...ata, campaign: "542370539", funnel: {} });
    await post({ ...ata, meetings: 0, minutes: 0 });
    const [row] = await rows();
    expect(row.campaign).toBe("542370539");
  });

  it.each([
    ["an unknown funnel key", { ...ata, funnel: { "not a key": 1 } }],
    ["a funnel value over the cap", { ...ata, funnel: { limitHit: 10_001 } }],
    ["a fractional funnel value", { ...ata, funnel: { limitHit: 1.5 } }],
    ["a negative funnel value", { ...ata, funnel: { onboardingStep: -1 } }],
    ["funnel as a list", { ...ata, funnel: [1] }],
    ["too many funnel keys", {
      ...ata,
      funnel: Object.fromEntries(Array.from({ length: 25 }, (_, i) => [`event${i}`, 1])),
    }],
    ["a campaign that is free text", { ...ata, campaign: "Miguel's campaign" }],
    ["a campaign longer than 32 characters", { ...ata, campaign: "a".repeat(33) }],
    ["a numeric campaign", { ...ata, campaign: 542370539 }],
    ["an unknown key next to a funnel", { ...ata, funnel: { limitHit: 1 }, email: "a@b.c" }],
  ])("refuses %s", async (_, body) => {
    expect((await post(body)).status).toBe(400);
    expect(await rows()).toHaveLength(0);
  });

  it("rolls the day up by version and campaign", async () => {
    await env.DB.prepare(
      `INSERT INTO pings (app, id, day, platform, version, build, os, locale, meetings, minutes, counts, funnel, campaign)
       VALUES ('ata', ?1, '2026-11-22', 'ios', '4.0.0', '1', '26.1', 'en-US', 0, 0, '{}', ?2, '542370539')`,
    ).bind(id, JSON.stringify({
      onboardingStep: 4,
      "paywallShown.limit": 2,
      "paywallShown.settings": 1,
      trialStarted: 1,
      "purchased.yearly": 1,
    })).run();
    await env.DB.prepare(
      `INSERT INTO pings (app, id, day, platform, version, build, os, locale, meetings, minutes, counts, funnel, campaign)
       VALUES ('ata', ?1, '2026-11-22', 'ios', '4.0.0', '1', '26.1', 'en-US', 0, 0, '{}', '{}', NULL)`,
    ).bind(id2).run();

    const { results } = await env.DB.prepare(
      `SELECT stage, detail, campaign, n FROM funnel_daily
       WHERE day = '2026-11-22' AND version = '4.0.0'
       ORDER BY campaign, stage, detail`,
    ).all<{ stage: string; detail: string; campaign: string; n: number }>();

    const of = (campaign: string) =>
      results.filter((r) => r.campaign === campaign).map((r) => [r.stage, r.detail, r.n]);

    expect(of("542370539")).toEqual([
      ["installs", "", 1],
      ["onboarded", "", 1],
      ["paid", "yearly", 1],
      ["paywall", "limit", 2],
      ["paywall", "settings", 1],
      ["trial", "", 1],
    ]);
    expect(of("(none)")).toEqual([["installs", "", 1]]);
  });
});
