import test from 'node:test';
import assert from 'node:assert/strict';
import { AuthGateway, SESSION_COOKIE } from '../src/auth-gateway.js';

let clock = 2_000_000_000;
const identityProvider = {
  async verifyPassword(email, password) {
    if (email === 'adult@example.test' && password === 'correct-password') return { verified: true, subject: 'local:adult' };
    if (email === 'member@example.test' && password === 'member-password') return { verified: true, subject: 'local:member' };
    return null;
  },
  async verifiedIdentityFor(subject) {
    if (subject === 'local:adult') return { subject, email: 'adult@example.test', verified: true };
    if (subject === 'local:member') return { subject, email: 'member@example.test', verified: true };
    return null;
  }
};
const claims = overrides => ({ iss: 'https://accounts.google.com', aud: 'google-client', sub: '123', email_verified: true, exp: clock + 60, iat: clock, nonce: overrides.nonce, ...overrides });
const make = () => {
  let nextClaims;
  const oidcVerifier = { async exchangeAndVerify(input) { assert.equal(input.redirectUri, 'https://family.example.test/auth/google/callback'); return nextClaims; } };
  const membershipAuthority = { async roleFor(subject, familyId) { return subject === 'local:adult' && familyId === 'f1' ? 'owner' : null; } };
  const assuranceAuthority = { async verify({ subject, action, target, proof }) { return subject === 'local:adult' && action === 'invite_member' && target === 'f1' && proof === 'valid-single-use-step-up'; } };
  return { gateway: new AuthGateway({ origin: 'https://family.example.test', googleClientId: 'google-client', now: () => clock, identityProvider, oidcVerifier, membershipAuthority, assuranceAuthority }), setClaims: value => { nextClaims = value; } };
};

test('password failures are anti-enumerating and success issues secure opaque cookie', async () => {
  const { gateway } = make();
  assert.deepEqual(await gateway.passwordSignIn('adult@example.test', 'bad'), await gateway.passwordSignIn('unknown@example.test', 'bad'));
  const ok = await gateway.passwordSignIn(' ADULT@example.test ', 'correct-password');
  assert.equal(ok.status, 200); assert.match(ok.cookie, new RegExp(`^${SESSION_COOKIE}=`));
  for (const flag of ['Path=/', 'HttpOnly', 'Secure', 'SameSite=Lax']) assert.match(ok.cookie, new RegExp(flag));
  assert.equal(gateway.session(ok.session).subject, 'local:adult'); gateway.revokeSession(ok.session); assert.equal(gateway.session(ok.session), null);
});

test('Google flow freezes exact callback, PKCE S256, state and nonce', () => {
  const { gateway } = make(); const flow = gateway.startGoogle('browser-1'); const url = new URL(flow.authorizationUrl);
  assert.equal(url.origin, 'https://accounts.google.com'); assert.equal(url.searchParams.get('redirect_uri'), 'https://family.example.test/auth/google/callback');
  assert.equal(url.searchParams.get('code_challenge_method'), 'S256'); assert.ok(url.searchParams.get('state')); assert.ok(url.searchParams.get('nonce'));
});

test('Google callback accepts verified claims once and rejects replay/wrong browser', async () => {
  const { gateway, setClaims } = make(); const started = gateway.startGoogle('browser-1'); const url = new URL(started.authorizationUrl);
  setClaims(claims({ nonce: url.searchParams.get('nonce') }));
  const input = { flowId: started.flowId, browserSessionId: 'browser-1', state: url.searchParams.get('state'), code: 'provider-code' };
  assert.equal((await gateway.finishGoogle(input)).status, 200); assert.equal((await gateway.finishGoogle(input)).status, 202);
  const second = gateway.startGoogle('browser-1'); const u2 = new URL(second.authorizationUrl); setClaims(claims({ nonce: u2.searchParams.get('nonce') }));
  assert.equal((await gateway.finishGoogle({ ...input, flowId: second.flowId, state: u2.searchParams.get('state'), browserSessionId: 'browser-2' })).status, 202);
});

test('Google callback rejects wrong issuer, audience, nonce, expiry and unverified email', async () => {
  for (const bad of [{ iss: 'https://evil.test' }, { aud: 'other' }, { nonce: 'wrong' }, { exp: clock - 1 }, { email_verified: false }]) {
    const { gateway, setClaims } = make(); const started = gateway.startGoogle('b'); const url = new URL(started.authorizationUrl);
    setClaims(claims({ nonce: url.searchParams.get('nonce'), ...bad }));
    assert.equal((await gateway.finishGoogle({ flowId: started.flowId, browserSessionId: 'b', state: url.searchParams.get('state'), code: 'c' })).status, 202);
  }
});

test('invite requires trusted role and step-up; acceptance uses session identity and is single-use', async () => {
  const { gateway } = make(); const owner = await gateway.passwordSignIn('adult@example.test', 'correct-password');
  await assert.rejects(gateway.issueInvite({ actorSession: owner.session, familyId: 'f1', email: 'member@example.test', role: 'viewer', stepUpProof: 'bad' }));
  await assert.rejects(gateway.issueInvite({ actorSession: owner.session, familyId: 'f1', email: 'member@example.test', role: 'viewer', stepUpProof: 'valid-single-use-step-up', ttlSeconds: 0 }));
  const token = await gateway.issueInvite({ actorSession: owner.session, familyId: 'f1', email: 'member@example.test', role: 'viewer', stepUpProof: 'valid-single-use-step-up' });
  assert.equal(await gateway.acceptInvite({ token, actorSession: owner.session }), null);
  const member = await gateway.passwordSignIn('member@example.test', 'member-password');
  assert.deepEqual(await gateway.acceptInvite({ token, actorSession: member.session }), { familyId: 'f1', subject: 'local:member', role: 'viewer' });
  assert.equal(await gateway.acceptInvite({ token, actorSession: member.session }), null);
});

test('invites fail closed for empty or unverified/mismatched/failed identity assertions', async () => {
  const { gateway } = make(); const owner = await gateway.passwordSignIn('adult@example.test', 'correct-password');
  await assert.rejects(gateway.issueInvite({ actorSession: owner.session, familyId: 'f1', email: '', role: 'admin', stepUpProof: 'valid-single-use-step-up' }));
  const issue = async () => gateway.issueInvite({ actorSession: owner.session, familyId: 'f1', email: 'member@example.test', role: 'viewer', stepUpProof: 'valid-single-use-step-up' });
  const original = identityProvider.verifiedIdentityFor;
  for (const assertion of [null, { subject: 'local:adult', email: '', verified: true }, { subject: 'attacker', email: 'member@example.test', verified: true }, { subject: 'local:adult', email: 'member@example.test', verified: false }]) {
    const token = await issue(); identityProvider.verifiedIdentityFor = async () => assertion;
    assert.equal(await gateway.acceptInvite({ token, actorSession: owner.session }), null);
  }
  const token = await issue(); identityProvider.verifiedIdentityFor = async () => { throw new Error('provider unavailable'); };
  assert.equal(await gateway.acceptInvite({ token, actorSession: owner.session }), null);
  identityProvider.verifiedIdentityFor = original;
});

test('authorization is family-scoped, exact-resource and private-by-default', () => {
  const { gateway } = make(); gateway.addGrant({ familyId: 'f1', subject: 'u2', resourceType: 'category', resourceId: 'vehicles', permission: 'view' });
  assert.equal(gateway.authorize({ familyId: 'f1', subject: 'u2', action: 'view', resource: { familyId: 'f1', type: 'category', id: 'vehicles' } }), true);
  assert.equal(gateway.authorize({ familyId: 'f1', subject: 'u2', action: 'contribute', resource: { familyId: 'f1', type: 'category', id: 'vehicles' } }), false);
  assert.equal(gateway.authorize({ familyId: 'f2', subject: 'u2', action: 'view', resource: { familyId: 'f2', type: 'category', id: 'vehicles' } }), false);
  assert.equal(gateway.authorize({ familyId: 'f1', subject: 'u2', action: 'view', resource: { familyId: 'f1', type: 'category', id: 'vehicles', privateTo: 'u1' } }), false);
});

test('origin refuses HTTP, paths and wildcards', () => {
  for (const origin of ['http://family.example.test', 'https://family.example.test/path', 'https://*.example.test']) assert.throws(() => new AuthGateway({ origin, googleClientId: 'x', oidcVerifier: {}, identityProvider: {} }));
});
