// Sending the "here are your keys" email for /v1/recover.
//
// The Cloudflare Email Sending binding (`EMAIL`, a `send_email` binding in
// wrangler.toml) is configured at deploy time, once the sender domain is
// onboarded. Until then the Worker uses the no-op sender: recover still answers
// 200, it just sends nothing.

export interface Mail {
  to: string;
  subject: string;
  text: string;
  html: string;
}

export interface EmailSender {
  send(mail: Mail): Promise<void>;
}

export const noopSender: EmailSender = { send: async () => {} };

export function cloudflareSender(binding: SendEmail, from: string): EmailSender {
  return {
    async send(mail) {
      await binding.send({ from: { email: from, name: "Ata" }, to: mail.to, subject: mail.subject, text: mail.text, html: mail.html });
    },
  };
}

export function senderFor(env: { EMAIL?: SendEmail; EMAIL_FROM?: string }): EmailSender {
  return env.EMAIL && env.EMAIL_FROM ? cloudflareSender(env.EMAIL, env.EMAIL_FROM) : noopSender;
}
