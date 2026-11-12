import { config } from './config.ts';
import { log } from './log.ts';

/** verify: confirm a new account. reset: set a new password. link: add an email to this account. exists: someone tried to sign up with an email that already has an account. */
export type MailKind = 'verify' | 'reset' | 'link' | 'exists';
export type Mail = { to: string; kind: MailKind; code?: string };
export type Mailer = { send(mail: Mail): Promise<void> };

const RESEND_URL = 'https://api.resend.com/emails';
const RESEND_TIMEOUT_MS = 10_000;

/**
 * The mailer for this environment: Resend when RESEND_API_KEY is set, else the dev stub.
 * A key without MAIL_FROM is a setup mistake, so it stops the server instead of failing every send.
 */
export function createMailer(env: NodeJS.ProcessEnv = process.env, fetchImpl: typeof fetch = fetch): Mailer {
  const apiKey = env.RESEND_API_KEY?.trim();
  if (!apiKey) return createDevMailer();
  const from = env.MAIL_FROM?.trim();
  if (!from) throw new Error('missing env MAIL_FROM (needed with RESEND_API_KEY)');
  return createResendMailer({ apiKey, from, fetch: fetchImpl });
}

/**
 * The dev stub: it sends nothing. It logs the kind, never the address or the code.
 * For local testing, MAIL_DEV_PRINT=1 also prints the code (never in production) so a developer can finish a sign-up.
 */
export function createDevMailer(): Mailer {
  return {
    async send(m) {
      log('mail_stub', { kind: m.kind });
      if (process.env.MAIL_DEV_PRINT === '1' && process.env.NODE_ENV !== 'production' && m.code) {
        console.log(`[dev mail] ${m.kind} code ${m.code}`);
      }
    },
  };
}

/** Sends plain-text mail through the Resend HTTP API. Logs the kind and the HTTP status only, never the address, the code or the reply body. */
export function createResendMailer(o: { apiKey: string; from: string; fetch?: typeof fetch; timeoutMs?: number }): Mailer {
  const doFetch = o.fetch ?? fetch;
  return {
    async send(m) {
      const res = await doFetch(RESEND_URL, {
        method: 'POST',
        headers: { authorization: `Bearer ${o.apiKey}`, 'content-type': 'application/json' },
        body: JSON.stringify({ from: o.from, to: [m.to], ...message(m) }),
        signal: AbortSignal.timeout(o.timeoutMs ?? RESEND_TIMEOUT_MS),
      });
      if (!res.ok) {
        log('mail_rejected', { kind: m.kind, status: res.status });
        throw Object.assign(new Error(`resend status ${res.status}`), { name: 'MailSendError' });
      }
      log('mail_sent', { kind: m.kind });
    },
  };
}

export function message(m: Mail): { subject: string; text: string } {
  const expires = `It expires in ${Math.round(config.auth.codeTtlMs / 60_000)} minutes.`;
  const ignore = 'If you did not ask for this, you can ignore this email.';
  switch (m.kind) {
    case 'verify':
      return { subject: 'Your Pip code', text: `Your Pip code is ${m.code}. ${expires}\n\n${ignore}` };
    case 'reset':
      return { subject: 'Your Pip reset code', text: `Your Pip reset code is ${m.code}. ${expires}\n\n${ignore}` };
    case 'link':
      return { subject: 'Your Pip code', text: `Your Pip code to add this email is ${m.code}. ${expires}\n\n${ignore}` };
    case 'exists':
      return {
        subject: 'You already have a Pip account',
        text: `Someone tried to sign up for Pip with this email, but it already has an account. To get back in, sign in or reset your password.\n\n${ignore}`,
      };
  }
}
