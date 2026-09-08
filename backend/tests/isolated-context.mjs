import assert from 'node:assert/strict';
import {createHmac, createHash, randomBytes} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import nodemailer from 'nodemailer';

// Mutating test suites must never silently fall back to the live local stack.
export function isolatedContext() {
  assert.equal(process.env.FD_TEST_CONTEXT, 'isolated', 'Run npm run test:isolated; these tests must not use the live application.');
  const urls = {};
  for (const name of ['AUTH', 'API', 'MAIL', 'OCR', 'SEARCH', 'GATEWAY']) {
    const value = process.env[`FD_${name}_URL`];
    const url = new URL(value);
    assert.equal(url.hostname, '127.0.0.1');
    assert.equal(url.protocol, 'http:');
    assert.ok(Number(url.port) >= 57000, 'Only isolated high loopback ports are accepted.');
    urls[name.toLowerCase()] = value;
  }
  assert.match(process.env.FD_TEST_CONTAINER || '', /^fd-test-[a-f0-9]{12}-db$/);
  return urls;
}

export async function ingestSyntheticEmail(to, subject, attachmentPath, externalId = crypto.randomUUID()) {
  const {gateway} = isolatedContext();
  const bytes = await readFile(attachmentPath);
  const filename = attachmentPath.split(/[\\/]/).pop();
  assert.match(filename, /^synthetic-.*\.pdf$/);
  const transport = nodemailer.createTransport({streamTransport: true, buffer: true});
  const message = await transport.sendMail({from: 'synthetic-sender@family-passport.test', to, subject,
    text: 'Synthetic local test message. No real family information is included.',
    attachments: [{filename, content: bytes, contentType: 'application/pdf'}]});
  const hash = value => createHash('sha256').update(value).digest('hex');
  const nonce = randomBytes(16).toString('hex'), timestamp = Math.floor(Date.now() / 1000);
  const payload = {recipient_address: to, external_message_id: externalId, internet_message_id: message.messageId,
    sender_address: 'synthetic-sender@family-passport.test', recipient_addresses: [to], message_subject: subject,
    message_sent_at: new Date().toISOString(), raw_email: message.message.toString('base64'), raw_sha256: hash(message.message),
    body_text: 'Synthetic local test message. No real family information is included.',
    attachments: [{part_id: '1', file_name: filename, content_type: 'application/pdf', size_bytes: bytes.length, sha256: hash(bytes), content_base64: bytes.toString('base64')}], webhook_nonce: nonce};
  const body = JSON.stringify(payload), bodyHash = hash(body);
  const signature = createHmac('sha256', process.env.FD_TEST_HMAC_SECRET).update(`v1\n${timestamp}\n${nonce}\n${bodyHash}`).digest('hex');
  const response = await fetch(`${gateway}/v1/inbound-email`, {method: 'POST', headers: {'content-type': 'application/json', 'x-fd-timestamp': String(timestamp), 'x-fd-nonce': nonce, 'x-fd-content-sha256': bodyHash, 'x-fd-signature': signature}, body});
  const result = await response.json();
  assert.equal(response.status, 200, JSON.stringify(result));
  assert.equal(result.accepted, true, JSON.stringify(result));
  return result;
}

export async function stepUpMfa(auth, token) {
  async function post(path, body) {
    const response = await fetch(`${auth}${path}`, {method: 'POST', headers: {authorization: `Bearer ${token}`, 'content-type': 'application/json'}, body: JSON.stringify(body)});
    const result = await response.json();
    assert.equal(response.status, 200, JSON.stringify(result));
    return result;
  }
  const factor = await post('/factors', {factor_type: 'totp', friendly_name: 'Synthetic test authenticator'});
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const bits = [...factor.totp.secret.replace(/=+$/, '').toUpperCase()].map(c => alphabet.indexOf(c).toString(2).padStart(5, '0')).join('');
  const key = Buffer.from(bits.match(/.{8}/g).map(x => parseInt(x, 2)));
  const counter = Buffer.alloc(8); counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000)));
  const digest = createHmac('sha1', key).update(counter).digest();
  const code = String((digest.readUInt32BE(digest[19] & 15) & 0x7fffffff) % 1000000).padStart(6, '0');
  const challenge = await post(`/factors/${factor.id}/challenge`, {});
  const verified = await post(`/factors/${factor.id}/verify`, {challenge_id: challenge.id, code});
  return verified.access_token;
}

export async function syntheticAccount(label) {
  const {auth, mail} = isolatedContext();
  const suffix = `${Date.now()}-${crypto.randomUUID().slice(0, 8)}`;
  const email = `${label}-${suffix}@family-passport.test`, password = `Synthetic-${suffix}-Password!`;
  const headers = {'content-type': 'application/json'};
  const signup = await fetch(`${auth}/signup`, {method: 'POST', headers, body: JSON.stringify({email, password})});
  assert.equal(signup.status, 200, await signup.text());
  let message;
  for (let attempt = 0; attempt < 24 && !message; attempt++) {
    const listing = await (await fetch(`${mail}/api/v1/messages`)).json();
    message = listing.messages?.find(item => item.To?.some(to => to.Address === email));
    if (!message) await new Promise(resolve => setTimeout(resolve, 250));
  }
  assert.ok(message, `Synthetic confirmation missing for ${label}`);
  const detail = await (await fetch(`${mail}/api/v1/message/${message.ID}`)).json();
  const link = [detail.Text, detail.HTML].join('\n').match(/https?:\/\/[^\s"'<>]+\/verify\?[^\s"'<>]+/i)?.[0]?.replaceAll('&amp;', '&');
  assert.ok(link);
  assert.equal(new URL(link).origin, auth, 'Confirmation must stay in the disposable auth service');
  await fetch(link, {redirect: 'manual'});
  const signin = await fetch(`${auth}/token?grant_type=password`, {method: 'POST', headers, body: JSON.stringify({email, password})});
  const session = await signin.json();
  assert.equal(signin.status, 200, JSON.stringify(session));
  return {email, userId: session.user.id, token: session.access_token};
}
