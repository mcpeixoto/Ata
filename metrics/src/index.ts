// The other end of Sources/Ata/Metrics.swift: one anonymous ping per install per
// day. The request's IP address is never read, stored or logged; only the
// country Cloudflare derives from it.

export interface Env {
  DB: D1Database;
}

export interface Ping {
  id: string;
  platform: "mac" | "ios";
  version: string;
  build: string;
  os: string;
  locale: string;
  meetings: number;
  minutes: number;
}

const KEYS = ["id", "platform", "version", "build", "os", "locale", "meetings", "minutes"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SHORT = /^[A-Za-z0-9._-]{1,32}$/;
const MAX_BODY = 1024;
const MAX_COUNT = 10_000;

/** The ping, or null when it is anything other than exactly what the app sends. */
export function parse(body: unknown): Ping | null {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return null;
  const b = body as Record<string, unknown>;
  if (Object.keys(b).length !== KEYS.length || !KEYS.every((k) => k in b)) return null;
  const count = (v: unknown) => Number.isInteger(v) && (v as number) >= 0 && (v as number) <= MAX_COUNT;
  const short = (v: unknown) => typeof v === "string" && SHORT.test(v);
  if (typeof b.id !== "string" || !UUID.test(b.id)) return null;
  if (b.platform !== "mac" && b.platform !== "ios") return null;
  if (![b.version, b.build, b.os, b.locale].every(short)) return null;
  if (!count(b.meetings) || !count(b.minutes)) return null;
  return {
    id: b.id.toLowerCase(),
    platform: b.platform,
    version: b.version as string,
    build: b.build as string,
    os: b.os as string,
    locale: b.locale as string,
    meetings: b.meetings as number,
    minutes: b.minutes as number,
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
    await env.DB.prepare(
      `INSERT INTO pings (id, day, platform, version, build, os, locale, country, meetings, minutes)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
       ON CONFLICT (id, day) DO UPDATE SET
         platform = excluded.platform, version = excluded.version, build = excluded.build,
         os = excluded.os, locale = excluded.locale, country = excluded.country,
         meetings = pings.meetings + excluded.meetings,
         minutes = pings.minutes + excluded.minutes`,
    )
      .bind(ping.id, day, ping.platform, ping.version, ping.build, ping.os, ping.locale, country,
            ping.meetings, ping.minutes)
      .run();
    return new Response(null, { status: 204 });
  },
} satisfies ExportedHandler<Env>;
