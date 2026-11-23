import { describe, expect, it } from "vitest";
import { noopSender, senderFor, smtpSender, type Dial, type Mail } from "../src/email";

const OPTS = {
  host: "mail-eu.smtp2go.com",
  port: 465,
  user: "user",
  password: "pass",
  from: "licence@example.com",
  fromName: "Ata",
};

const DAYS = "(Sun|Mon|Tue|Wed|Thu|Fri|Sat)";
const MONTHS = "(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)";

function capture(replies: string[]): { dial: Dial; state: { chunks: Uint8Array[]; host: string; port: number; dialed: boolean; closed: boolean } } {
  const state = { chunks: [] as Uint8Array[], host: "", port: 0, dialed: false, closed: false };
  const dial: Dial = (host, port) => {
    state.dialed = true;
    state.host = host;
    state.port = port;
    let i = 0;
    const encoder = new TextEncoder();
    const readable = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (i >= replies.length) {
          controller.close();
          return;
        }
        controller.enqueue(encoder.encode(replies[i]));
        i += 1;
      },
    });
    const writable = new WritableStream<Uint8Array>({
      write(chunk) {
        // Copy: the sender may reuse the buffer it just wrote.
        state.chunks.push(chunk.slice());
      },
    });
    return {
      readable,
      writable,
      close() {
        state.closed = true;
      },
    };
  };
  return { dial, state };
}

function textOf(chunks: Uint8Array[]): string {
  const size = chunks.reduce((n, c) => n + c.length, 0);
  const all = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    all.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder().decode(all);
}

/** One complete reply per chunk, so a short read cannot swallow the next command's answer. */
function okReplies(ehlo: string[] = ["250 hello\r\n"], rcpt = "250 ok\r\n", quit = true): string[] {
  const tail = ["354 go\r\n", "250 queued\r\n"];
  if (quit) tail.push("221 bye\r\n");
  return ["220 ready\r\n", ...ehlo, "235 ok\r\n", "250 ok\r\n", rcpt, ...tail];
}

function mail(over: Partial<Mail> = {}): Mail {
  return {
    to: "buyer@example.com",
    subject: "Licença",
    text: "A".repeat(120),
    html: `<p>${"B".repeat(120)}</p>`,
    ...over,
  };
}

function transcript(raw: string): { commands: string[]; message: string } {
  const lines = raw.split("\r\n");
  const dataAt = lines.indexOf("DATA");
  const quitAt = lines.lastIndexOf("QUIT");
  const dotAt = lines.lastIndexOf(".", quitAt);
  // Drop the one dot SMTP added so a body line of "." would not end DATA.
  const stuffed = lines.slice(dataAt + 1, dotAt);
  const message = stuffed.map((line) => (line.startsWith(".") ? line.slice(1) : line)).join("\r\n");
  return { commands: lines.slice(0, dataAt + 1), message };
}

function header(message: string, name: string): string {
  const block = message.split("\r\n\r\n", 1)[0].replace(/\r\n[ \t]+/g, " ");
  const match = new RegExp(`^${name}: (.*)$`, "m").exec(block);
  if (!match) throw new Error(`missing header ${name}`);
  return match[1];
}

function decodeWords(value: string): string {
  return value.split(/\s+/).map((word) => {
    const match = /^=\?UTF-8\?B\?([A-Za-z0-9+/=]+)\?=$/.exec(word);
    expect(match, word).not.toBeNull();
    const bytes = Uint8Array.from(atob(match![1]), (c) => c.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  }).join("");
}

function mimeParts(message: string): { type: string; headers: string; body: string }[] {
  const boundary = /boundary="?([^";\s]+)"?/.exec(header(message, "Content-Type"))?.[1];
  expect(boundary).toBeTruthy();
  const chunks = message.split(`--${boundary}`);
  const parts: { type: string; headers: string; body: string }[] = [];
  for (const chunk of chunks.slice(1)) {
    if (chunk.startsWith("--")) break;
    const [headers, ...rest] = chunk.replace(/^\r\n/, "").split("\r\n\r\n");
    const type = /Content-Type: ([^;\r\n]+)/.exec(headers)?.[1] ?? "";
    parts.push({ type, headers, body: rest.join("\r\n\r\n").replace(/\r\n$/, "") });
  }
  return parts;
}

function decodePart(part: { headers: string; body: string }): string {
  expect(part.headers).toContain("charset=utf-8");
  expect(part.headers).toMatch(/Content-Transfer-Encoding: base64/);
  const lines = part.body.split("\r\n").filter((line) => line.length > 0);
  expect(lines.length).toBeGreaterThan(0);
  for (const line of lines) expect(line.length).toBeLessThanOrEqual(76);
  const bytes = Uint8Array.from(atob(lines.join("")), (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

describe("smtpSender", () => {
  it("speaks SMTP and sends both MIME parts", async () => {
    const cap = capture(okReplies());
    const sent = mail();
    await smtpSender(OPTS, cap.dial).send(sent);

    const raw = textOf(cap.state.chunks);
    const { commands, message } = transcript(raw);
    expect(cap.state).toMatchObject({ dialed: true, closed: true, host: OPTS.host, port: 465 });
    expect(commands).toEqual([
      "EHLO ata-licence",
      expect.stringMatching(/^AUTH PLAIN \S+$/),
      "MAIL FROM:<licence@example.com>",
      "RCPT TO:<buyer@example.com>",
      "DATA",
    ]);
    const payload = commands[1].slice("AUTH PLAIN ".length);
    const decoded = new TextDecoder().decode(Uint8Array.from(atob(payload), (c) => c.charCodeAt(0)));
    expect(decoded).toBe("\0user\0pass");

    expect(raw.endsWith("\r\n.\r\nQUIT\r\n")).toBe(true);
    expect(header(message, "From")).toBe('"Ata" <licence@example.com>');
    expect(header(message, "To")).toBe("buyer@example.com");
    expect(decodeWords(header(message, "Subject"))).toBe("Licença");
    expect(header(message, "Date")).toMatch(new RegExp(`^${DAYS}, [0-9]{1,2} ${MONTHS} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} \\+0000$`));
    expect(header(message, "Message-ID")).toMatch(/^<[0-9a-f-]{36}@example\.com>$/);
    expect(header(message, "MIME-Version")).toBe("1.0");
    expect(header(message, "Content-Type")).toMatch(/^multipart\/alternative; boundary=\S+$/);

    const parts = mimeParts(message);
    expect(parts.map((part) => part.type)).toEqual(["text/plain", "text/html"]);
    expect(decodePart(parts[0])).toBe(sent.text);
    expect(decodePart(parts[1])).toBe(sent.html);
    expect(parts[0].body.split("\r\n").some((line) => line.length === 76)).toBe(true);
  });

  it("accepts a multi-line EHLO reply delivered in two chunks", async () => {
    // The CRLF of the final 250 is split, and 250- lines must not be taken as the end of the reply.
    const cap = capture(okReplies(["250-a\r\n250-b\r\n250 c\r", "\n"]));
    await smtpSender(OPTS, cap.dial).send(mail());
    const lines = textOf(cap.state.chunks).split("\r\n");
    expect(lines[0]).toBe("EHLO ata-licence");
    expect(lines[1].startsWith("AUTH PLAIN ")).toBe(true);
    expect(lines.at(-2)).toBe("QUIT");
  });

  it("sends a text body line that starts with '.' as '..'", async () => {
    const text = "Hello\n.hidden\nBye";
    const cap = capture(okReplies(undefined, "251 ok\r\n"));
    await smtpSender(OPTS, cap.dial).send(mail({ subject: "Keys", text, html: "<p>Hi</p>" }));
    const raw = textOf(cap.state.chunks);
    const lines = raw.split("\r\n");
    expect(lines).toContain("..hidden");
    expect(lines).not.toContain(".hidden");
    const { message } = transcript(raw);
    expect(header(message, "Subject")).toBe("Keys");
    const plain = mimeParts(message).find((part) => part.type === "text/plain");
    expect(plain).toBeTruthy();
    expect(decodePart(plain!)).toBe(text);
  });

  it("rejects a 535 and keeps the password out of the error", async () => {
    const password = "smtp-secret-9f3a";
    const cap = capture(["220 ready\r\n", "250 hello\r\n", "535 denied\r\n"]);
    const sender = smtpSender({ ...OPTS, password }, cap.dial);
    let message = "";
    try {
      await sender.send(mail());
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
    }
    expect(message).toContain("AUTH");
    expect(message).toContain("535");
    expect(message).not.toContain(password);
    expect(message).not.toContain("AUTH PLAIN");
    expect(cap.state.closed).toBe(true);
    expect(textOf(cap.state.chunks)).not.toContain("MAIL FROM");
  });

  it("rejects a recipient containing CR LF before dialling", async () => {
    const cap = capture(okReplies());
    const sender = smtpSender(OPTS, cap.dial);
    await expect(sender.send(mail({ to: "buyer@example.com\r\nRCPT TO:<other@evil.test>" }))).rejects.toThrow();
    expect(cap.state.dialed).toBe(false);
    expect(cap.state.chunks).toHaveLength(0);
  });

  it("does not fail the send when the server drops QUIT", async () => {
    const cap = capture(okReplies(undefined, "250 ok\r\n", false));
    await smtpSender(OPTS, cap.dial).send(mail());
    expect(textOf(cap.state.chunks).endsWith("QUIT\r\n")).toBe(true);
    expect(cap.state.closed).toBe(true);
  });

  it("base64-encodes a non-ASCII password without throwing", async () => {
    const cap = capture(okReplies());
    await smtpSender({ ...OPTS, user: "usé", password: "päss" }, cap.dial).send(mail());
    const auth = textOf(cap.state.chunks).split("\r\n")[1];
    const decoded = new TextDecoder().decode(Uint8Array.from(atob(auth.slice("AUTH PLAIN ".length)), (c) => c.charCodeAt(0)));
    expect(decoded).toBe("\0usé\0päss");
  });
});

describe("senderFor", () => {
  it("uses the Email Sending binding when that is configured", async () => {
    const calls: Array<EmailMessage | EmailMessageBuilder> = [];
    const EMAIL: SendEmail = {
      async send(message) {
        calls.push(message);
        return { messageId: "test" };
      },
    };
    const sender = senderFor({
      EMAIL,
      EMAIL_FROM: "from@example.com",
      SMTP_HOST: "mail-eu.smtp2go.com",
      SMTP_USER: "user",
      SMTP_PASSWORD: "secret",
    });
    await sender.send({ to: "a@b.c", subject: "s", text: "t", html: "<p>t</p>" });
    expect(calls).toEqual([
      {
        from: { email: "from@example.com", name: "Ata" },
        to: "a@b.c",
        subject: "s",
        text: "t",
        html: "<p>t</p>",
      },
    ]);
  });

  it("uses SMTP when host, user, password and EMAIL_FROM are set", () => {
    const sender = senderFor({
      SMTP_HOST: "mail-eu.smtp2go.com",
      SMTP_PORT: "465",
      SMTP_USER: "user",
      SMTP_PASSWORD: "secret",
      EMAIL_FROM: "from@example.com",
    });
    expect(sender).not.toBe(noopSender);
  });

  it("stays a no-op when the SMTP password is missing", () => {
    const base = { SMTP_HOST: "mail-eu.smtp2go.com", SMTP_USER: "user", EMAIL_FROM: "from@example.com" };
    expect(senderFor(base)).toBe(noopSender);
    expect(senderFor({ ...base, SMTP_PASSWORD: "" })).toBe(noopSender);
  });
});
