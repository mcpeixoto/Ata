// The few plain HTML pages a buyer sees. Colours are the app's own, from
// ThemeTokens in Sources/Ata/Theme.swift (brand gradient, accent light/dark).

export function escapeHTML(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

const STYLE = `
:root { --accent: #8338E0; --ink: #FFFFFF; --bg: #FFFFFF; --text: #16141C; --muted: #6B6775; --card: #F6F3FB; }
@media (prefers-color-scheme: dark) {
  :root { --accent: #B98CFF; --ink: #16141C; --bg: #16141C; --text: #F4F1FA; --muted: #A49FAF; --card: #221F2B; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
main { max-width: 520px; margin: 0 auto; padding: 48px 16px; }
.mark { height: 6px; border-radius: 3px; background: linear-gradient(90deg, #8B6CF9, #A552F3, #D24CBE); margin-bottom: 32px; }
h1 { font-size: 28px; margin: 0 0 16px; }
p { margin: 0 0 16px; }
.muted { color: var(--muted); font-size: 14px; }
.key { font: 600 20px/1.4 ui-monospace, "SF Mono", Menlo, monospace; letter-spacing: 0.04em; background: var(--card); padding: 16px; border-radius: 12px; text-align: center; user-select: all; word-break: break-all; }
.button { display: inline-block; background: var(--accent); color: var(--ink); padding: 12px 20px; border-radius: 10px; text-decoration: none; font-weight: 600; }
a { color: var(--accent); }
`;

export function page(title: string, body: string, head = ""): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width, initial-scale=1">` +
    `<title>${escapeHTML(title)}</title>${head}<style>${STYLE}</style></head>` +
    `<body><main><div class="mark"></div><h1>${escapeHTML(title)}</h1>${body}</main></body></html>`;
}

export function messagePage(title: string, message: string): string {
  return page(title, `<p>${escapeHTML(message)}</p>`);
}

export function pendingPage(): string {
  return page(
    "Payment processing",
    "<p>Your payment hasn't gone through yet. This page checks again every few seconds.</p>",
    '<meta http-equiv="refresh" content="5">',
  );
}

export function thanksPage(key: string, plan: string, portalURL: string | null): string {
  const k = escapeHTML(key);
  const activate = `ata://licence?key=${encodeURIComponent(key)}`;
  return page(
    "Thank you",
    `<p>Your Ata Pro licence key (${escapeHTML(plan)}):</p>` +
      `<p class="key">${k}</p>` +
      `<p><a class="button" href="${escapeHTML(activate)}">Activate in Ata</a></p>` +
      "<p class=\"muted\">The button opens Ata on this Mac and activates it. On another Mac, paste the key into Ata. " +
      "One key works on up to three Macs. Keep it somewhere safe; Ata can also email it to you again.</p>" +
      (portalURL ? `<p class="muted"><a href="${escapeHTML(portalURL)}">Manage your subscription</a></p>` : ""),
  );
}
