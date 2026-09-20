import { createPrivateKey, sign } from 'node:crypto';
import { readFile } from 'node:fs/promises';

for (const name of ['ASC_ISSUER_ID', 'ASC_KEY_ID', 'ASC_KEY_PATH', 'ASC_APP_ID']) {
  if (!process.env[name]) throw new Error(`Missing ${name}`);
}

const privateKey = createPrivateKey(await readFile(process.env.ASC_KEY_PATH));

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

function token() {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({
    alg: 'ES256',
    kid: process.env.ASC_KEY_ID,
    typ: 'JWT',
  }));
  const payload = base64url(JSON.stringify({
    iss: process.env.ASC_ISSUER_ID,
    iat: now - 10,
    exp: now + 600,
    aud: 'appstoreconnect-v1',
  }));
  const body = `${header}.${payload}`;
  const signature = sign('sha256', Buffer.from(body), {
    key: privateKey,
    dsaEncoding: 'ieee-p1363',
  }).toString('base64url');
  return `${body}.${signature}`;
}

const query = new URLSearchParams({
  'filter[app]': process.env.ASC_APP_ID,
  'sort': '-uploadedDate',
  'limit': '5',
  'fields[builds]': 'version,uploadedDate,processingState,expired',
});
const response = await fetch(`https://api.appstoreconnect.apple.com/v1/builds?${query}`, {
  headers: { authorization: `Bearer ${token()}` },
});
if (!response.ok) {
  throw new Error(`App Store Connect build query failed (${response.status}): ${await response.text()}`);
}

const result = await response.json();
console.log(JSON.stringify(result.data.map(({ id, attributes }) => ({ id, ...attributes }))));
