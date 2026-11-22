// Licence keys: ATA-XXXX-XXXX-XXXX-XXXX in Crockford base32, 80 random bits.

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const KEY = /^ATA(-[0-9A-HJKMNP-TV-Z]{4}){4}$/;

export function newKey(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  // 256 is a multiple of 32, so `& 31` keeps every character equally likely.
  const chars = [...bytes].map((b) => CROCKFORD[b & 31]).join("");
  return `ATA-${chars.slice(0, 4)}-${chars.slice(4, 8)}-${chars.slice(8, 12)}-${chars.slice(12, 16)}`;
}

/** A key as a person might type or paste it, in canonical form; null if it can't be one. */
export function normaliseKey(input: unknown): string | null {
  if (typeof input !== "string" || input.length > 64) return null;
  // Crockford base32 reads I and L as 1 and O as 0, so a misread key still works.
  const s = input.toUpperCase().replace(/[\s]/g, "").replace(/[IL]/g, "1").replace(/O/g, "0");
  const body = s.replace(/^ATA-?/, "").replace(/-/g, "");
  if (body.length !== 16) return null;
  const key = `ATA-${body.slice(0, 4)}-${body.slice(4, 8)}-${body.slice(8, 12)}-${body.slice(12, 16)}`;
  return KEY.test(key) ? key : null;
}

export async function emailHash(email: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(email.trim().toLowerCase()));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
