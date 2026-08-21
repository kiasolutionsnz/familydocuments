'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { AssuranceContract, FIVE_MINUTES_MS, COOLING_OFF_MS } = require('../src/assurance-contract');

test('multiple named passkeys are independently revoked', () => {
  const auth = new AssuranceContract();
  auth.addPasskey('a', 'Phone'); auth.addPasskey('b', 'Laptop');
  auth.revokePasskey('a');
  assert.notEqual(auth.passkeys.get('a').revokedAt, null);
  assert.equal(auth.passkeys.get('b').revokedAt, null);
});

test('step-up is AAL2, session/action/target/challenge bound and no older than five minutes', () => {
  let now = 1_000_000;
  const auth = new AssuranceContract({ now: () => now, secret: Buffer.alloc(32, 7) });
  auth.createSession('s', 2);
  const proof = auth.issueStepUp({ sessionId: 's', action: 'share', target: 'record-1', challenge: 'c1' });
  assert.equal(auth.verifyStepUp(proof, { sessionId: 's', action: 'share', target: 'record-1', challenge: 'c1' }), true);
  assert.equal(auth.verifyStepUp(proof, { sessionId: 's', action: 'delete', target: 'record-1', challenge: 'c1' }), false);
  assert.equal(auth.verifyStepUp(proof, { sessionId: 's', action: 'share', target: 'record-2', challenge: 'c1' }), false);
  now += FIVE_MINUTES_MS + 1;
  assert.equal(auth.verifyStepUp(proof, { sessionId: 's', action: 'share', target: 'record-1', challenge: 'c1' }), false);
});

test('refresh tokens rotate once and reuse revokes the family', () => {
  const auth = new AssuranceContract();
  const session = auth.createSession('s');
  assert.equal(auth.rotateRefresh(session.refreshFamilyId, '0'), '1');
  assert.throws(() => auth.rotateRefresh(session.refreshFamilyId, '0'), /family revoked/);
  assert.throws(() => auth.rotateRefresh(session.refreshFamilyId, '1'), /family revoked/);
});

test('individual and global revocation reject immediately in concurrent checks', async () => {
  const auth = new AssuranceContract();
  auth.createSession('a'); auth.createSession('b');
  auth.revokeSession('a');
  const checks = await Promise.all(Array.from({ length: 1000 }, async () => auth.sessions.get('a').revokedAt !== null));
  assert.equal(checks.every(Boolean), true);
  assert.equal(auth.sessions.get('b').revokedAt, null);
  auth.revokeAll();
  assert.equal([...auth.sessions.values()].every(s => s.revokedAt !== null), true);
});

test('recovery codes contain 128 random bits, are slow-hashed and single use', () => {
  const auth = new AssuranceContract();
  const [code] = auth.createRecoveryCodes(1);
  assert.equal(Buffer.from(code, 'hex').length, 16);
  const record = auth.recoveryCodes.values().next().value;
  assert.equal(Object.hasOwn(record, 'plaintext'), false);
  assert.equal(auth.consumeRecoveryCode(code), true);
  assert.equal(auth.consumeRecoveryCode(code), false);
  assert.equal(auth.alerts.some(a => a.type === 'recovery-codes-created'), true);
});

test('recovery has a cancellable 72h cooling-off and rotates all credentials/sessions', () => {
  let now = 5_000;
  const auth = new AssuranceContract({ now: () => now });
  auth.createSession('s'); auth.createRecoveryCodes(1); auth.requestRecovery('r1');
  assert.throws(() => auth.completeRecovery('r1'), /cooling-off active/);
  auth.cancelRecovery('r1');
  assert.throws(() => auth.completeRecovery('r1'), /invalid recovery/);
  auth.requestRecovery('r2'); now += COOLING_OFF_MS;
  auth.completeRecovery('r2');
  assert.equal(auth.credentialEpoch, 2);
  assert.equal([...auth.sessions.values()].every(s => s.revokedAt !== null), true);
  assert.equal([...auth.recoveryCodes.values()].every(c => c.revokedAt !== null), true);
});

test('lost-all-factor and support recovery fail closed', () => {
  const auth = new AssuranceContract();
  assert.throws(() => auth.lostAllFactorsRecover(), /fails closed/);
  assert.throws(() => auth.supportRecover(), /forbidden/);
});
