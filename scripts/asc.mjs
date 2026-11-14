#!/usr/bin/env node
// App Store Connect API calls for scripts/ship-testflight.sh.
// Usage:
//   node scripts/asc.mjs state <buildNumber>          -> prints "<processingState> <internalBuildState> <usesNonExemptEncryption>"
//   node scripts/asc.mjs no-encryption <buildNumber>  -> sets usesNonExemptEncryption=false if it is not set
//   node scripts/asc.mjs notes <buildNumber> <file>   -> sets en-US "What to Test" and prints it back from the API
// The key never leaves this process; errors print status and API messages only.
import crypto from 'node:crypto';
import fs from 'node:fs';

const KEY_ID = process.env.ASC_KEY_ID || '6CHR4MM9J4';
const ISSUER = process.env.ASC_ISSUER_ID || 'ba5ac58d-794c-4386-8994-a5fab9aaf8f9';
const APP_ID = process.env.ASC_APP_ID || '6833946851';
const KEY_PATH = `${process.env.HOME}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`;
const API = 'https://api.appstoreconnect.apple.com/v1/';

function token() {
  const key = fs.readFileSync(KEY_PATH);
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const body = `${b64({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })}.${b64({ iss: ISSUER, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' })}`;
  const sig = crypto.sign('sha256', Buffer.from(body), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${body}.${sig}`;
}

async function call(method, path, body) {
  const res = await fetch(API + path, {
    method,
    headers: { authorization: `Bearer ${token()}`, 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) {
    let detail = text.slice(0, 500);
    try { detail = JSON.parse(text).errors.map((e) => `${e.code}: ${e.detail}`).join('; '); } catch {}
    throw new Error(`${method} ${path.split('?')[0]} -> HTTP ${res.status}: ${detail}`);
  }
  return text ? JSON.parse(text) : {};
}

async function findBuild(number) {
  const r = await call('GET', `builds?filter[app]=${APP_ID}&filter[version]=${number}&include=buildBetaDetail&limit=5`);
  const b = r.data?.[0];
  if (!b) return null;
  const detail = r.included?.find((i) => i.type === 'buildBetaDetails' && i.id === b.relationships.buildBetaDetail.data.id);
  return { id: b.id, attrs: b.attributes, internal: detail?.attributes?.internalBuildState ?? 'UNKNOWN' };
}

async function mustFind(number) {
  const b = await findBuild(number);
  if (!b) throw new Error(`build ${number} not found in App Store Connect`);
  return b;
}

const [cmd, number, file] = process.argv.slice(2);
try {
  if (!cmd || !number) throw new Error('usage: asc.mjs state|no-encryption|notes <buildNumber> [file]');
  if (cmd === 'state') {
    const b = await findBuild(number);
    console.log(b ? `${b.attrs.processingState} ${b.internal} ${b.attrs.usesNonExemptEncryption}` : 'NOT_FOUND NONE null');
  } else if (cmd === 'no-encryption') {
    const b = await mustFind(number);
    if (b.attrs.usesNonExemptEncryption === false) {
      console.log('usesNonExemptEncryption already false');
    } else {
      await call('PATCH', `builds/${b.id}`, { data: { type: 'builds', id: b.id, attributes: { usesNonExemptEncryption: false } } });
      console.log('usesNonExemptEncryption set to false');
    }
  } else if (cmd === 'notes') {
    if (!file) throw new Error('notes needs a file');
    const whatsNew = fs.readFileSync(file, 'utf8').trim();
    if (!whatsNew) throw new Error(`notes file ${file} is empty`);
    const b = await mustFind(number);
    const loc = await call('GET', `builds/${b.id}/betaBuildLocalizations`);
    const en = loc.data?.find((l) => l.attributes.locale === 'en-US');
    if (en) {
      await call('PATCH', `betaBuildLocalizations/${en.id}`, { data: { type: 'betaBuildLocalizations', id: en.id, attributes: { whatsNew } } });
    } else {
      await call('POST', 'betaBuildLocalizations', {
        data: { type: 'betaBuildLocalizations', attributes: { locale: 'en-US', whatsNew }, relationships: { build: { data: { type: 'builds', id: b.id } } } },
      });
    }
    const back = (await call('GET', `builds/${b.id}/betaBuildLocalizations`)).data?.find((l) => l.attributes.locale === 'en-US');
    if (back?.attributes?.whatsNew?.trim() !== whatsNew) throw new Error('What to Test read-back does not match the notes file');
    console.log('What to Test (read back from App Store Connect):');
    console.log(back.attributes.whatsNew);
  } else {
    throw new Error(`unknown command ${cmd}`);
  }
} catch (e) {
  console.error(`asc.mjs: ${e.message}`);
  process.exit(1);
}
