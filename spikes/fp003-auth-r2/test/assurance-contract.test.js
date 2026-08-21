'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { AssuranceContract, FIVE_MINUTES_MS, COOLING_OFF_MS } = require('../src/assurance-contract');

test('step-up requires phishing-resistant ceremony and is consumed exactly once', async () => {
  let now = 1_000_000;
  const auth = new AssuranceContract({ now: () => now, secret: Buffer.alloc(32, 7) });
  auth.createSession('s', 2);
  assert.throws(() => auth.issueStepUp({ sessionId: 's', action: 'share', target: 'record-1', challenge: 'caller-value' }), /server-issued/);
  const challenge = auth.issueStepUpChallenge({ sessionId: 's', action: 'share', target: 'record-1' });
  assert.equal(Buffer.from(challenge, 'base64url').length, 16);
  assert.throws(() => auth.issueStepUp({ sessionId: 's', action: 'share', target: 'record-1', challenge }), /phishing-resistant/);
  const proof = auth.issueStepUp({ sessionId: 's', action: 'share', target: 'record-1', challenge, phishingResistant: true });
  const expected = { sessionId: 's', action: 'share', target: 'record-1', challenge };
  const concurrent = await Promise.all(Array.from({ length: 100 }, async () => auth.verifyAndConsumeStepUp(proof, expected)));
  assert.equal(concurrent.filter(Boolean).length, 1);
  assert.equal(auth.auditEvents.filter(e => e.type === 'step-up-consumed').length, 1);
  const c2 = auth.issueStepUpChallenge({ sessionId: 's', action: 'share', target: 'record-1' });
  const other = auth.issueStepUp({ sessionId: 's', action: 'share', target: 'record-1', challenge: c2, phishingResistant: true });
  assert.equal(auth.verifyAndConsumeStepUp(other, { ...expected, challenge: c2, sessionId: 'other' }), false);
  assert.equal(auth.verifyAndConsumeStepUp(other, { ...expected, challenge: c2, action: 'delete' }), false);
  assert.equal(auth.verifyAndConsumeStepUp(other, { ...expected, challenge: c2, target: 'record-2' }), false);
  now += FIVE_MINUTES_MS + 1;
  assert.equal(auth.verifyAndConsumeStepUp(other, { ...expected, challenge: c2 }), false);
});

test('recovery completion revokes every existing passkey, session, refresh family and recovery code', () => {
  let now = 5_000;
  const auth = new AssuranceContract({ now: () => now });
  auth.createSession('s1'); auth.createSession('s2');
  auth.addPasskey('phone', 'Phone', { sessionId: 's1' }); auth.addPasskey('laptop', 'Laptop', { sessionId: 's1' });
  auth.createRecoveryCodes(2); auth.requestRecovery('r1');
  assert.throws(() => auth.addPasskey('bad', 'Bad', { sessionId: 's1' }), /cooling-off/);
  assert.throws(() => auth.completeRecovery('r1'), /cooling-off active/);
  now += COOLING_OFF_MS;
  const enrollmentToken = auth.completeRecovery('r1');
  assert.throws(() => auth.completeRecovery('r1'), /invalid recovery/);
  assert.equal(auth.isPasskeyUsable('phone'), false);
  assert.equal(auth.isPasskeyUsable('laptop'), false);
  assert.equal([...auth.passkeys.values()].every(k => k.revokedAt !== null), true);
  assert.equal([...auth.sessions.values()].every(s => s.revokedAt !== null), true);
  assert.equal([...auth.refreshFamilies.values()].every(f => f.revokedAt !== null), true);
  assert.equal([...auth.recoveryCodes.values()].every(c => c.revokedAt !== null), true);
  assert.equal(auth.credentialEpoch, 2);
  assert.equal(auth.alerts.some(a => a.type === 'all-passkeys-revoked-after-recovery'), true);
  assert.equal(auth.alerts.some(a => a.type === 'recovery-completed'), true);
  assert.equal(auth.auditEvents.some(e => e.type === 'global-credential-rotation'), true);
  assert.throws(() => auth.addPasskey('new', 'New', { recoveryId: 'r1', enrollmentToken: 'wrong' }), /authorized/);
  auth.addPasskey('new', 'New', { recoveryId: 'r1', enrollmentToken });
  assert.equal(auth.isPasskeyUsable('new'), true);
  assert.throws(() => auth.addPasskey('duplicate', 'Duplicate', { recoveryId: 'r1', enrollmentToken }), /authorized/);
});

test('cancelled recovery cannot complete or authorize enrollment', () => {
  let now = 10_000;
  const auth = new AssuranceContract({ now: () => now });
  auth.createSession('s'); auth.requestRecovery('cancelled'); auth.cancelRecovery('cancelled');
  now += COOLING_OFF_MS;
  assert.throws(() => auth.completeRecovery('cancelled'), /invalid recovery/);
  assert.throws(() => auth.addPasskey('p', 'Phone', { recoveryId: 'cancelled', enrollmentToken: 'x' }), /authorized/);
});

test('refresh reuse revokes the family and lost-all-factor/support paths fail closed', () => {
  const auth = new AssuranceContract();
  const session = auth.createSession('s');
  assert.equal(auth.rotateRefresh(session.refreshFamilyId, '0'), '1');
  assert.throws(() => auth.rotateRefresh(session.refreshFamilyId, '0'), /family revoked/);
  assert.throws(() => auth.supportRecover(), /forbidden/);
  assert.throws(() => auth.lostAllFactorsRecover(), /fails closed/);
});

test('individual/global revocation is immediately visible in 1000 concurrent local checks', async () => {
  const auth = new AssuranceContract();
  auth.createSession('a'); auth.createSession('b'); auth.revokeSession('a');
  const checks = await Promise.all(Array.from({ length: 1000 }, async () => auth.sessions.get('a').revokedAt !== null));
  assert.equal(checks.every(Boolean), true);
  auth.revokeAll();
  assert.equal([...auth.sessions.values()].every(s => s.revokedAt !== null), true);
});
