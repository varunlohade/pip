import { appendFileSync, chmodSync, existsSync, readFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';

const path = new URL('../../.env', import.meta.url).pathname;
const text = existsSync(path) ? readFileSync(path, 'utf8') : '';
if (/^DATA_ENCRYPTION_KEY=[0-9a-f]{64}\s*$/m.test(text)) {
  console.log('DATA_ENCRYPTION_KEY present in .env');
} else {
  appendFileSync(path, `${text && !text.endsWith('\n') ? '\n' : ''}DATA_ENCRYPTION_KEY=${randomBytes(32).toString('hex')}\n`, { mode: 0o600 });
  chmodSync(path, 0o600);
  console.log('DATA_ENCRYPTION_KEY generated into .env (value not shown)');
}
