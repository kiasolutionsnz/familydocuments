import { createPrivateKey, sign } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { join } from 'node:path';

const required = [
  'ASC_ISSUER_ID',
  'ASC_KEY_ID',
  'ASC_KEY_PATH',
  'ASC_CERTIFICATE_ID',
  'ASC_BUNDLE_IDENTIFIER',
  'ASC_SIGNING_OUTPUT',
];
for (const name of required) {
  if (!process.env[name]) throw new Error(`Missing ${name}`);
}

const issuer = process.env.ASC_ISSUER_ID;
const keyId = process.env.ASC_KEY_ID;
const output = process.env.ASC_SIGNING_OUTPUT;
const privateKey = createPrivateKey(await readFile(process.env.ASC_KEY_PATH));

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

function token() {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }));
  const payload = base64url(JSON.stringify({
    iss: issuer,
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

async function request(path, options = {}) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    ...options,
    headers: {
      authorization: `Bearer ${token()}`,
      'content-type': 'application/json',
      ...(options.headers ?? {}),
    },
  });
  if (!response.ok) {
    throw new Error(`${options.method ?? 'GET'} ${path} failed (${response.status}): ${await response.text()}`);
  }
  return response.status === 204 ? null : response.json();
}

await mkdir(output, { recursive: true });

const certificate = await request(`/v1/certificates/${encodeURIComponent(process.env.ASC_CERTIFICATE_ID)}`);
await writeFile(
  join(output, 'FamilyDocumentsDistribution.cer'),
  Buffer.from(certificate.data.attributes.certificateContent, 'base64'),
);

const bundleQuery = new URLSearchParams({
  'filter[identifier]': process.env.ASC_BUNDLE_IDENTIFIER,
  limit: '1',
});
const bundles = await request(`/v1/bundleIds?${bundleQuery}`);
if (bundles.data.length !== 1) throw new Error('FamilyDocuments bundle ID was not found');

const profileName = 'FamilyDocuments App Store 2026';
const profileQuery = new URLSearchParams({ 'filter[name]': profileName, limit: '1' });
let profiles = await request(`/v1/profiles?${profileQuery}`);
let profile = profiles.data[0];
if (!profile) {
  const created = await request('/v1/profiles', {
    method: 'POST',
    body: JSON.stringify({
      data: {
        type: 'profiles',
        attributes: { name: profileName, profileType: 'IOS_APP_STORE' },
        relationships: {
          bundleId: { data: { type: 'bundleIds', id: bundles.data[0].id } },
          certificates: {
            data: [{ type: 'certificates', id: process.env.ASC_CERTIFICATE_ID }],
          },
        },
      },
    }),
  });
  profile = created.data;
} else if (!profile.attributes.profileContent) {
  profile = (await request(`/v1/profiles/${profile.id}`)).data;
}

await writeFile(
  join(output, 'FamilyDocuments_AppStore.mobileprovision'),
  Buffer.from(profile.attributes.profileContent, 'base64'),
);

console.log(JSON.stringify({
  status: 'APPLE_SIGNING_ASSETS_READY',
  certificate_id: certificate.data.id,
  certificate_expiration: certificate.data.attributes.expirationDate,
  profile_id: profile.id,
  profile_name: profile.attributes.name,
  output,
}));
