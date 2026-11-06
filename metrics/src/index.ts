// One anonymous ping per install per day, for Ata (Sources/Ata/Metrics.swift)
// and the other apps that share this Worker. The request's IP address is never
// read, stored or logged; only the country Cloudflare derives from it.

export interface Env {
  DB: D1Database;
}

/** The apps allowed to report. Anything else is refused. */
export const APPS = ["ata", "polaris", "drexpenses", "mealmind", "almanac", "cabin", "deephealth"] as const;
export type App = (typeof APPS)[number];

export interface Ping {
  app: App;
  id: string;
  platform: "mac" | "ios";
  version: string;
  build: string;
  os: string;
  locale: string;
  /** Ata 3.4.0's own two counters; 0 for every other app. */
  meetings: number;
  minutes: number;
  /** Every other app's counters, by name. */
  counts: Record<string, number>;
}

const COMMON = ["id", "platform", "version", "build", "os", "locale"];
// What Ata 3.4.0 sends, with no `app`. Already in the field: never break it.
const LEGACY = [...COMMON, "meetings", "minutes"];
const SHARED = ["app", ...COMMON, "counts"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SHORT = /^[A-Za-z0-9._-]{1,32}$/;
const COUNTER = /^[a-z][a-z0-9_]{0,31}$/;
const MAX_BODY = 1024;
const MAX_COUNT = 10_000;
const MAX_COUNTERS = 8;

const hasExactly = (b: Record<string, unknown>, keys: string[]) =>
  Object.keys(b).length === keys.length && keys.every((k) => k in b);
const isCount = (v: unknown): v is number =>
  Number.isInteger(v) && (v as number) >= 0 && (v as number) <= MAX_COUNT;

function parseCounts(v: unknown): Record<string, number> | null {
  if (typeof v !== "object" || v === null || Array.isArray(v)) return null;
  const entries = Object.entries(v);
  if (entries.length > MAX_COUNTERS) return null;
  if (!entries.every(([k, n]) => COUNTER.test(k) && isCount(n))) return null;
  return Object.fromEntries(entries) as Record<string, number>;
}

/** The ping, or null when it is anything other than exactly what an app sends. */
export function parse(body: unknown): Ping | null {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return null;
  const b = body as Record<string, unknown>;

  let app: App;
  let meetings = 0;
  let minutes = 0;
  let counts: Record<string, number> = {};
  if (hasExactly(b, LEGACY)) {
    if (!isCount(b.meetings) || !isCount(b.minutes)) return null;
    app = "ata";
    meetings = b.meetings;
    minutes = b.minutes;
  } else if (hasExactly(b, SHARED)) {
    if (!APPS.includes(b.app as App)) return null;
    const c = parseCounts(b.counts);
    if (!c) return null;
    app = b.app as App;
    counts = c;
  } else {
    return null;
  }

  const short = (v: unknown) => typeof v === "string" && SHORT.test(v);
  if (typeof b.id !== "string" || !UUID.test(b.id)) return null;
  if (b.platform !== "mac" && b.platform !== "ios") return null;
  if (![b.version, b.build, b.os, b.locale].every(short)) return null;
  return {
    app,
    id: b.id.toLowerCase(),
    platform: b.platform,
    version: b.version as string,
    build: b.build as string,
    os: b.os as string,
    locale: b.locale as string,
    meetings,
    minutes,
    counts,
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== "/v1/ping") return new Response(null, { status: 404 });
    if (request.method !== "POST") return new Response(null, { status: 405 });

    const text = await request.text();
    if (text.length > MAX_BODY) return new Response(null, { status: 413 });
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      return new Response(null, { status: 400 });
    }
    const ping = parse(json);
    if (!ping) return new Response(null, { status: 400 });

    const country = (request.cf?.country as string | undefined) ?? null;
    const day = new Date().toISOString().slice(0, 10);
    // A second ping the same day adds to the first, counter by counter.
    await env.DB.prepare(
      `INSERT INTO pings (app, id, day, platform, version, build, os, locale, country, meetings, minutes, counts)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
       ON CONFLICT (app, id, day) DO UPDATE SET
         platform = excluded.platform, version = excluded.version, build = excluded.build,
         os = excluded.os, locale = excluded.locale, country = excluded.country,
         meetings = pings.meetings + excluded.meetings,
         minutes = pings.minutes + excluded.minutes,
         counts = (
           SELECT COALESCE(json_group_object(key, total), '{}') FROM (
             SELECT key, SUM(value) AS total FROM (
               SELECT key, value FROM json_each(pings.counts)
               UNION ALL
               SELECT key, value FROM json_each(excluded.counts)
             ) GROUP BY key
           )
         )`,
    )
      .bind(ping.app, ping.id, day, ping.platform, ping.version, ping.build, ping.os, ping.locale,
            country, ping.meetings, ping.minutes, JSON.stringify(ping.counts))
      .run();
    return new Response(null, { status: 204 });
  },
} satisfies ExportedHandler<Env>;
