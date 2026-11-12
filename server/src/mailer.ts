import { log } from './log.ts';

/** verify: confirm a new account. reset: set a new password. link: add an email to this account. exists: someone tried to sign up with an email that already has an account. */
export type MailKind = 'verify' | 'reset' | 'link' | 'exists';
export type Mail = { to: string; kind: MailKind; code?: string };
export type Mailer = { send(mail: Mail): Promise<void> };

/**
 * The only mailer for now: it sends nothing. It logs the kind, never the address or the code.
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
