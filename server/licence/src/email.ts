// /v1/recover emails the buyer their licence keys.
//
// senderFor picks whichever sender this deployment can actually use:
// - The Cloudflare Email Sending binding, when `EMAIL` and `EMAIL_FROM` are
//   both set. That binding needs a paid plan, so it is not how we deploy.
// - SMTP when `SMTP_HOST`, `SMTP_USER`, `SMTP_PASSWORD` and `EMAIL_FROM` are
//   all set. SMTP2GO is implicit TLS on port 465: Workers block outbound
//   port 25, so this cannot be a cleartext relay.
// With neither configured, recover still answers 200 and nothing is sent.

import { connect } from "cloudflare:sockets";

export interface Mail {
  to: string;
  subject: string;
  text: string;
  html: string;
}

export interface EmailSender {
  send(mail: Mail): Promise<void>;
}

/** A TCP connection. Tests pass a fake; production dials with implicit TLS. */
export type Dial = (host: string, port: number) => {
  readable: ReadableStream<Uint8Array>;
  writable: WritableStream<Uint8Array>;
  close(): Promise<void> | void;
};

export const noopSender: EmailSender = { send: async () => {} };

export function cloudflareSender(binding: SendEmail, from: string): EmailSender {
  return {
    async send(mail) {
      await binding.send({ from: { email: from, name: "Ata" }, to: mail.to, subject: mail.subject, text: mail.text, html: mail.html });
    },
  };
}

type SmtpOpts = { host: string; port: number; user: string; password: string; from: string; fromName: string };

// `connect` types the streams without a chunk type; the socket still carries bytes.
const defaultDial: Dial = (host, port) => {
  const socket = connect({ hostname: host, port }, { secureTransport: "on", allowHalfOpen: false });
  return {
    readable: socket.readable as ReadableStream<Uint8Array>,
    writable: socket.writable as WritableStream<Uint8Array>,
    close: () => socket.close(),
  };
};

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"] as const;
// A stuck relay must not hold the isolate until the platform kills the request.
const SMTP_TIMEOUT_MS = 20_000;

export function smtpSender(opts: SmtpOpts, dial: Dial = defaultDial): EmailSender {
  return {
    async send(mail) {
      // A line break in the recipient is a second SMTP command, not part of the address.
      if (mail.to.includes("\r") || mail.to.includes("\n")) {
        throw new Error("SMTP recipient rejected: CR or LF in address");
      }
      const socket = dial(opts.host, opts.port);
      let timer: ReturnType<typeof setTimeout> | undefined;
      const conversation = exchange(socket, opts, mail);
      // If the timeout wins the race, the conversation then fails because the
      // socket was closed. That rejection is not the one the caller awaits.
      void conversation.catch(() => {});
      try {
        await Promise.race([
          conversation,
          new Promise<never>((_, reject) => {
            timer = setTimeout(() => {
              void Promise.resolve(socket.close()).catch(() => {});
              reject(new Error("SMTP timeout"));
            }, SMTP_TIMEOUT_MS);
          }),
        ]);
      } finally {
        if (timer !== undefined) clearTimeout(timer);
      }
    },
  };
}

export function senderFor(env: {
  EMAIL?: SendEmail;
  EMAIL_FROM?: string;
  SMTP_HOST?: string;
  SMTP_PORT?: string;
  SMTP_USER?: string;
  SMTP_PASSWORD?: string;
}): EmailSender {
  if (env.EMAIL && env.EMAIL_FROM) return cloudflareSender(env.EMAIL, env.EMAIL_FROM);
  if (env.SMTP_HOST && env.SMTP_USER && env.SMTP_PASSWORD && env.EMAIL_FROM) {
    return smtpSender({
      host: env.SMTP_HOST,
      port: Number(env.SMTP_PORT || 465),
      user: env.SMTP_USER,
      password: env.SMTP_PASSWORD,
      from: env.EMAIL_FROM,
      fromName: "Ata",
    });
  }
  return noopSender;
}

async function exchange(socket: ReturnType<Dial>, opts: SmtpOpts, mail: Mail): Promise<void> {
  const writer = socket.writable.getWriter();
  const reader = new ReplyReader(socket.readable);
  const encode = new TextEncoder();
  const write = (line: string) => writer.write(encode.encode(line));
  try {
    await expectCode(reader, "greeting", 220);
    await write("EHLO ata-licence\r\n");
    await expectCode(reader, "EHLO", 250);
    // AUTH PLAIN is UTF-8, not a binary string: btoa() throws on non-ASCII.
    await write(`AUTH PLAIN ${base64Bytes(encode.encode(`\0${opts.user}\0${opts.password}`))}\r\n`);
    await expectCode(reader, "AUTH", 235);
    await write(`MAIL FROM:<${opts.from}>\r\n`);
    await expectCode(reader, "MAIL", 250);
    await write(`RCPT TO:<${mail.to}>\r\n`);
    await expectCode(reader, "RCPT", 250, 251);
    await write("DATA\r\n");
    await expectCode(reader, "DATA", 354);
    await write(dotStuff(renderMessage(opts, mail)));
    await expectCode(reader, "DATA", 250);
    try {
      await write("QUIT\r\n");
      await reader.readCode();
    } catch {
      // The message is already accepted. Dropping the connection here is a
      // finished session, not a failed delivery.
    }
  } finally {
    try {
      await writer.close();
    } catch {
      // The timeout may already have torn the socket down.
    }
    try {
      await socket.close();
    } catch {
      // close() is idempotent for the caller; a second close can reject.
    }
  }
}

async function expectCode(reader: ReplyReader, command: string, ...ok: number[]): Promise<void> {
  const code = await reader.readCode();
  // The reply text is omitted on purpose: a 535 can echo the AUTH line, and that line is the password.
  if (!ok.includes(code)) throw new Error(`SMTP ${command} failed: ${code}`);
}

class ReplyReader {
  private pending = new Uint8Array(0);
  private readonly reader: ReadableStreamDefaultReader<Uint8Array>;

  constructor(stream: ReadableStream<Uint8Array>) {
    this.reader = stream.getReader();
  }

  async readCode(): Promise<number> {
    let line = await this.readLine();
    // 250- is a continuation. Only a line that does not use the hyphen ends the reply.
    while (line.length >= 4 && line[3] === "-") line = await this.readLine();
    if (!/^[0-9]{3}(?:[ -].*)?$/.test(line)) throw new Error("SMTP reply failed: unreadable");
    return Number(line.slice(0, 3));
  }

  private async readLine(): Promise<string> {
    const decode = new TextDecoder();
    for (;;) {
      const at = indexOfCrlf(this.pending);
      if (at >= 0) {
        const line = decode.decode(this.pending.subarray(0, at));
        this.pending = this.pending.subarray(at + 2);
        return line;
      }
      const { value, done } = await this.reader.read();
      if (done) {
        if (this.pending.length === 0) throw new Error("SMTP connection closed");
        const line = decode.decode(this.pending);
        this.pending = new Uint8Array(0);
        return line;
      }
      this.pending = concatBytes(this.pending, value);
    }
  }
}

function indexOfCrlf(buf: Uint8Array): number {
  for (let i = 0; i < buf.length - 1; i++) {
    if (buf[i] === 13 && buf[i + 1] === 10) return i;
  }
  return -1;
}

function concatBytes(a: Uint8Array<ArrayBuffer>, b: ArrayLike<number>): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  for (let i = 0; i < b.length; i++) out[a.length + i] = b[i];
  return out;
}

function base64Bytes(bytes: ArrayLike<number>): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

function wrap76(b64: string): string[] {
  const lines: string[] = [];
  for (let i = 0; i < b64.length; i += 76) lines.push(b64.slice(i, i + 76));
  return lines.length > 0 ? lines : [""];
}

// An encoded-word is at most 75 characters (RFC 2047). Longer subjects are split so nothing is truncated.
function encodeSubject(subject: string): string {
  if (/^[\x20-\x7E]*$/.test(subject)) return subject;
  const bytes = new TextEncoder().encode(subject);
  const words: string[] = [];
  for (let i = 0; i < bytes.length; i += 45) {
    words.push(`=?UTF-8?B?${base64Bytes(bytes.subarray(i, i + 45))}?=`);
  }
  return words.join("\r\n ");
}

function rfc5322Date(now: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${WEEKDAYS[now.getUTCDay()]}, ${now.getUTCDate()} ${MONTHS[now.getUTCMonth()]} ${now.getUTCFullYear()} ${pad(now.getUTCHours())}:${pad(now.getUTCMinutes())}:${pad(now.getUTCSeconds())} +0000`;
}

function domainOf(from: string): string {
  const domain = from.slice(from.lastIndexOf("@") + 1);
  return domain && domain !== from ? domain : "localhost";
}

function quoted(name: string): string {
  // A quote or a line break would end the quoted-string and start another header.
  const clean = name.replace(/[\r\n]+/g, " ").replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return `"${clean}"`;
}

function renderMessage(opts: SmtpOpts, mail: Mail): string {
  const boundary = `ata_${crypto.randomUUID()}`;
  const plain = textLines(mail.text);
  const lines = [
    `From: ${quoted(opts.fromName)} <${opts.from}>`,
    `To: ${mail.to}`,
    `Subject: ${encodeSubject(mail.subject)}`,
    `Date: ${rfc5322Date(new Date())}`,
    `Message-ID: <${crypto.randomUUID()}@${domainOf(opts.from)}>`,
    "MIME-Version: 1.0",
    `Content-Type: multipart/alternative; boundary=${boundary}`,
    "",
    // Repeated in front of the first boundary so a client that ignores
    // multipart still shows the keys. Those lines are also the ones SMTP
    // dot-stuffing can see; base64 never starts a line with ".".
    ...plain,
    ...mimePart("text/plain", mail.text, boundary),
    ...mimePart("text/html", mail.html, boundary),
    `--${boundary}--`,
  ];
  return `${lines.join("\r\n")}\r\n`;
}

function textLines(text: string): string[] {
  if (text.length === 0) return [];
  return text.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");
}

function mimePart(kind: "text/plain" | "text/html", content: string, boundary: string): string[] {
  return [
    `--${boundary}`,
    `Content-Type: ${kind}; charset=utf-8`,
    "Content-Transfer-Encoding: base64",
    "",
    ...wrap76(base64Bytes(new TextEncoder().encode(content))),
  ];
}

// A line that is just "." ends DATA. Stuff first, then add that terminator, or a body line of "." would truncate the mail.
function dotStuff(message: string): string {
  const lines = message.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  const stuffed = lines.map((line) => (line.startsWith(".") ? `.${line}` : line));
  return `${stuffed.join("\r\n")}\r\n.\r\n`;
}
