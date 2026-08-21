'use strict';

const { createHash, createHmac, randomBytes, scryptSync, timingSafeEqual } = require('node:crypto');

const FIVE_MINUTES_MS = 5 * 60 * 1000;
const COOLING_OFF_MS = 72 * 60 * 60 * 1000;

function stableHash(value) {
  return createHash('sha256').update(value).digest('hex');
}

class AssuranceContract {
  constructor({ now = () => Date.now(), secret = randomBytes(32) } = {}) {
    this.now = now;
    this.secret = secret;
    this.passkeys = new Map();
    this.sessions = new Map();
    this.refreshFamilies = new Map();
    this.recoveryCodes = new Map();
    this.recoveries = new Map();
    this.alerts = [];
    this.credentialEpoch = 1;
  }

  addPasskey(id, name) {
    if (!id || !name) throw new Error('named passkey required');
    this.passkeys.set(id, { id, name, revokedAt: null });
  }

  revokePasskey(id) {
    const key = this.passkeys.get(id);
    if (!key) throw new Error('unknown passkey');
    key.revokedAt = this.now();
    this.alerts.push({ type: 'passkey-revoked', id });
  }

  createSession(id, aal = 2) {
    this.sessions.set(id, { id, aal, revokedAt: null, epoch: this.credentialEpoch });
    const family = { id: `rf-${id}`, active: '0', revokedAt: null, used: new Set() };
    this.refreshFamilies.set(family.id, family);
    return { sessionId: id, refreshFamilyId: family.id, refreshToken: '0' };
  }

  rotateRefresh(familyId, token) {
    const family = this.refreshFamilies.get(familyId);
    if (!family || family.revokedAt !== null) throw new Error('refresh family revoked');
    if (family.used.has(token) || token !== family.active) {
      family.revokedAt = this.now();
      this.alerts.push({ type: 'refresh-reuse', familyId });
      throw new Error('refresh reuse detected; family revoked');
    }
    family.used.add(token);
    family.active = String(Number(token) + 1);
    return family.active;
  }

  revokeSession(id) {
    const session = this.sessions.get(id);
    if (!session) throw new Error('unknown session');
    session.revokedAt = this.now();
    const family = this.refreshFamilies.get(`rf-${id}`);
    if (family) family.revokedAt = this.now();
  }

  revokeAll() {
    for (const session of this.sessions.values()) session.revokedAt = this.now();
    for (const family of this.refreshFamilies.values()) family.revokedAt = this.now();
  }

  issueStepUp({ sessionId, action, target, challenge }) {
    const session = this.sessions.get(sessionId);
    if (!session || session.revokedAt !== null || session.aal < 2) throw new Error('AAL2 active session required');
    const issuedAt = this.now();
    const payload = [sessionId, action, target, challenge, issuedAt, this.credentialEpoch].join('|');
    return { sessionId, action, target, challenge, issuedAt, epoch: this.credentialEpoch,
      proof: createHmac('sha256', this.secret).update(payload).digest('hex') };
  }

  verifyStepUp(assertion, expected) {
    const session = this.sessions.get(expected.sessionId);
    if (!session || session.revokedAt !== null || session.aal < 2) return false;
    if (this.now() - assertion.issuedAt > FIVE_MINUTES_MS || assertion.issuedAt > this.now()) return false;
    for (const field of ['sessionId', 'action', 'target', 'challenge']) {
      if (assertion[field] !== expected[field]) return false;
    }
    if (assertion.epoch !== this.credentialEpoch || session.epoch !== this.credentialEpoch) return false;
    const payload = [assertion.sessionId, assertion.action, assertion.target, assertion.challenge,
      assertion.issuedAt, assertion.epoch].join('|');
    const expectedProof = createHmac('sha256', this.secret).update(payload).digest();
    const actual = Buffer.from(assertion.proof, 'hex');
    return actual.length === expectedProof.length && timingSafeEqual(actual, expectedProof);
  }

  createRecoveryCodes(count = 8) {
    const plaintext = [];
    for (let i = 0; i < count; i += 1) {
      const code = randomBytes(16).toString('hex'); // 128 bits
      const salt = randomBytes(16);
      const hash = scryptSync(code, salt, 32, { N: 16384, r: 8, p: 1 });
      this.recoveryCodes.set(stableHash(code), { salt, hash, usedAt: null, revokedAt: null });
      plaintext.push(code);
    }
    this.alerts.push({ type: 'recovery-codes-created' });
    return plaintext;
  }

  consumeRecoveryCode(code) {
    const record = this.recoveryCodes.get(stableHash(code));
    if (!record || record.usedAt !== null || record.revokedAt !== null) return false;
    const candidate = scryptSync(code, record.salt, 32, { N: 16384, r: 8, p: 1 });
    if (!timingSafeEqual(candidate, record.hash)) return false;
    record.usedAt = this.now();
    return true;
  }

  requestRecovery(id) {
    this.recoveries.set(id, { requestedAt: this.now(), state: 'cooling-off' });
    this.alerts.push({ type: 'recovery-requested', id });
  }

  cancelRecovery(id) {
    const recovery = this.recoveries.get(id);
    if (!recovery || recovery.state !== 'cooling-off') throw new Error('not cancellable');
    recovery.state = 'cancelled';
    this.alerts.push({ type: 'recovery-cancelled', id });
  }

  completeRecovery(id) {
    const recovery = this.recoveries.get(id);
    if (!recovery || recovery.state !== 'cooling-off') throw new Error('invalid recovery');
    if (this.now() - recovery.requestedAt < COOLING_OFF_MS) throw new Error('cooling-off active');
    recovery.state = 'complete';
    this.revokeAll();
    for (const code of this.recoveryCodes.values()) code.revokedAt = this.now();
    this.credentialEpoch += 1;
    this.alerts.push({ type: 'recovery-completed', id });
  }

  supportRecover() { throw new Error('support recovery forbidden'); }
  lostAllFactorsRecover() { throw new Error('lost-all-factor recovery fails closed'); }
}

module.exports = { AssuranceContract, FIVE_MINUTES_MS, COOLING_OFF_MS };
