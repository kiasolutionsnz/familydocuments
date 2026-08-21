import test from 'node:test';
import assert from 'node:assert/strict';
import { AuthHttpBoundary } from '../src/http-boundary.js';

const origin = 'https://family.example.test';
const baseRequest = (path, body, extra = {}) => {
  const { headers = {}, ...rest } = extra;
  return { method: 'POST', url: `${origin}${path}`, headers: { origin, 'content-type': 'application/json', ...headers }, body: JSON.stringify(body), clientKey: 'test', ...rest };
};
const make = () => {
  const calls = [];
  const gateway = {
    async passwordSignIn(email, password) { calls.push(['password', email, password]); return email === 'ok@example.test' ? { status: 200, cookie: '__Host-fp_session=opaque; Path=/; HttpOnly; Secure; SameSite=Lax' } : { status: 202 }; },
    startGoogle(browserId) { calls.push(['start', browserId]); return { flowId: 'f'.repeat(32), authorizationUrl: 'https://accounts.google.com/o/oauth2/v2/auth?state=s' }; },
    async finishGoogle(input) { calls.push(['finish', input]); return { status: 200, cookie: '__Host-fp_session=opaque; Path=/; HttpOnly; Secure; SameSite=Lax' }; },
    async acceptInvite(input) { calls.push(['accept', input]); return { familyId: 'f1', subject: 'u2', role: 'viewer' }; }
  };
  const csrf = new Map();
  const csrfAuthority = {
    async issue(session) { const token = `csrf_${session}_${'x'.repeat(32)}`; csrf.set(session, token); return token; },
    verify({ session, cookie, header }) { return !!session && csrf.get(session) === cookie && cookie === header; }
  };
  const boundary = new AuthHttpBoundary({
    gateway, origin,
    rateLimiter: { async allow(keys) { calls.push(['limit', keys]); return true; } },
    requestIdentity: { async networkKey() { return `network-${'n'.repeat(40)}`; } },
    accountKeyAuthority: { async key(email) { calls.push(['account-key-input', email]); return `hmac-key-${'k'.repeat(40)}`; } },
    csrfAuthority,
    invitationService: { async issueAndDeliver(input) { calls.push(['issue-deliver', input]); return true; } }
  });
  return { boundary, calls, csrfAuthority };
};

test('password route accepts exact schema and sets secure session without returning token', async () => {
  const { boundary, calls } = make(); const response = await boundary.handle(baseRequest('/auth/password/sign-in', { email: 'ok@example.test', password: 'correct-password' }));
  assert.equal(response.status, 200); assert.equal(response.body.authenticated, true); assert.match(response.headers['set-cookie'], /HttpOnly; Secure/); assert.equal('session' in response.body, false); assert.equal(calls.filter(x => x[0] === 'password').length, 1);
});

test('malformed JSON, extra fields, wrong content type, cross-origin and oversized bodies fail safely', async () => {
  const { boundary, calls } = make();
  const cases = [
    { ...baseRequest('/auth/password/sign-in', {}), body: '{' },
    baseRequest('/auth/password/sign-in', { email: 'ok@example.test', password: 'correct-password', admin: true }),
    baseRequest('/auth/password/sign-in', { email: 'ok@example.test', password: 'correct-password' }, { headers: { 'content-type': 'text/plain' } }),
    baseRequest('/auth/password/sign-in', { email: 'ok@example.test', password: 'correct-password' }, { headers: { origin: 'https://evil.test' } }),
    { ...baseRequest('/auth/password/sign-in', {}), body: 'x'.repeat(20_000) }
  ];
  for (const request of cases) assert.ok([202, 400].includes((await boundary.handle(request)).status));
  assert.equal(calls.filter(x => x[0] === 'password').length, 0);
});

test('Google start creates protected binding and callback rejects malformed binding/query', async () => {
  const { boundary, calls } = make();
  const start = await boundary.handle({ method: 'GET', url: `${origin}/auth/google/start`, headers: { 'sec-fetch-site': 'same-origin' } });
  assert.equal(start.status, 302); assert.match(start.headers['set-cookie'], /^__Host-fp_oidc=.*HttpOnly; Secure/);
  const malformed = await boundary.handle({ method: 'GET', url: `${origin}/auth/google/callback?state=s&code=c&extra=x`, headers: { cookie: start.headers['set-cookie'].split(';')[0] } });
  assert.equal(malformed.status, 400); assert.equal(calls.filter(x => x[0] === 'finish').length, 0);
  const duplicate = await boundary.handle({ method: 'GET', url: `${origin}/auth/google/callback?state=s&state=x&code=c`, headers: { cookie: start.headers['set-cookie'].split(';')[0] } });
  assert.equal(duplicate.status, 400);
  const callback = await boundary.handle({ method: 'GET', url: `${origin}/auth/google/callback?state=s&code=c`, headers: { cookie: start.headers['set-cookie'].split(';')[0] } });
  assert.equal(callback.status, 200); assert.equal(calls.filter(x => x[0] === 'finish').length, 1);
});

test('authenticated mutation requires exact origin, unique cookies and matching CSRF', async () => {
  const { boundary, calls } = make(); const body = { email: 'member@example.test', role: 'viewer', stepUpProof: 'p' };
  const csrfResponse = await boundary.handle({ method: 'GET', url: `${origin}/auth/csrf`, headers: { cookie: '__Host-fp_session=s', 'sec-fetch-site': 'same-origin' } });
  const csrf = csrfResponse.body.csrfToken;
  const denied = await boundary.handle(baseRequest('/families/f1/invitations', body, { headers: { cookie: '__Host-fp_session=s' } })); assert.equal(denied.status, 202);
  const duplicate = await boundary.handle(baseRequest('/families/f1/invitations', body, { headers: { cookie: `__Host-fp_session=s; __Host-fp_session=t; __Host-fp_csrf=${csrf}`, 'x-fp-csrf': csrf } })); assert.equal(duplicate.status, 400);
  const accepted = await boundary.handle(baseRequest('/families/f1/invitations', body, { headers: { cookie: `__Host-fp_session=s; __Host-fp_csrf=${csrf}`, 'x-fp-csrf': csrf } }));
  assert.equal(accepted.status, 202); assert.equal(calls.filter(x => x[0] === 'issue-deliver').length, 1); assert.equal(JSON.stringify(accepted).includes('token'), false);
});

test('unknown routes and handler exceptions do not leak details', async () => {
  const { boundary } = make(); assert.equal((await boundary.handle({ method: 'GET', url: `${origin}/missing`, headers: {} })).status, 404);
  const broken = new AuthHttpBoundary({ gateway: { async passwordSignIn() { throw new Error('secret database detail'); } }, origin, rateLimiter: { async allow() { return true; } }, requestIdentity: { async networkKey() { return `network-${'n'.repeat(40)}`; } }, accountKeyAuthority: { async key() { return `account-${'a'.repeat(40)}`; } }, csrfAuthority: {}, invitationService: {} });
  const response = await broken.handle(baseRequest('/auth/password/sign-in', { email: 'ok@example.test', password: 'correct-password' })); assert.equal(response.status, 202); assert.doesNotMatch(JSON.stringify(response), /database|secret/i);
});

test('non-callback routes reject ignored query and limiter keys come from trusted adapter plus account hash', async () => {
  const { boundary, calls } = make();
  assert.equal((await boundary.handle(baseRequest('/auth/password/sign-in?admin=true', { email: 'ok@example.test', password: 'correct-password' }))).status, 400);
  await boundary.handle(baseRequest('/auth/password/sign-in', { email: 'ok@example.test', password: 'correct-password' }, { clientKey: 'attacker-controlled' }));
  const keys = calls.find(x => x[0] === 'limit')[1]; assert.match(keys.networkKey, /^network-/); assert.equal('clientKey' in keys, false); assert.match(keys.accountKey, /^hmac-key-/); assert.deepEqual(calls.find(x => x[0] === 'account-key-input'), ['account-key-input', 'ok@example.test']);
});

test('async CSRF denial is awaited and prevents invitation service execution', async () => {
  const { boundary, calls } = make(); boundary.csrfAuthority.verify = async () => false;
  const csrf = 'c'.repeat(40); const response = await boundary.handle(baseRequest('/families/f1/invitations', { email: 'member@example.test', role: 'viewer', stepUpProof: 'p' }, { headers: { cookie: `__Host-fp_session=s; __Host-fp_csrf=${csrf}`, 'x-fp-csrf': csrf } }));
  assert.equal(response.status, 202); assert.equal(calls.filter(x => x[0] === 'issue-deliver').length, 0);
});

test('invalid, unavailable or slow limiter authorities fail before password verification', async () => {
  for (const mutate of [
    boundary => { boundary.requestIdentity.networkKey = async () => ''; },
    boundary => { boundary.accountKeyAuthority.key = async () => null; },
    boundary => { boundary.rateLimiter.allow = async () => 'true'; },
    boundary => { boundary.rateLimiter.allow = async () => new Promise(() => {}); }
  ]) {
    const { boundary, calls } = make(); mutate(boundary);
    const response = await boundary.handle(baseRequest('/auth/password/sign-in', { email: 'ok@example.test', password: 'correct-password' }));
    assert.equal(response.status, 202); assert.equal(calls.filter(x => x[0] === 'password').length, 0);
  }
});

test('invalid or stalled CSRF authorities fail within the boundary timeout', async () => {
  for (const issue of [async () => null, async () => 'short', async () => new Promise(() => {})]) {
    const { boundary } = make(); boundary.csrfAuthority.issue = issue;
    const started = Date.now(); const response = await boundary.handle({ method: 'GET', url: `${origin}/auth/csrf`, headers: { cookie: '__Host-fp_session=s', 'sec-fetch-site': 'same-origin' } });
    assert.equal(response.status, 202); assert.ok(Date.now() - started < 250);
  }
  const { boundary, calls } = make(); boundary.csrfAuthority.verify = async () => new Promise(() => {});
  const started = Date.now(); const response = await boundary.handle(baseRequest('/families/f1/invitations', { email: 'member@example.test', role: 'viewer', stepUpProof: 'p' }, { headers: { cookie: `__Host-fp_session=s; __Host-fp_csrf=${'c'.repeat(40)}`, 'x-fp-csrf': 'c'.repeat(40) } }));
  assert.equal(response.status, 202); assert.ok(Date.now() - started < 250); assert.equal(calls.filter(x => x[0] === 'issue-deliver').length, 0);
});
