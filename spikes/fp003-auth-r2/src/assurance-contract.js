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
    this.stepUpChallenges = new Map();
    this.alerts = [];
    this.auditEvents = [];
    this.credentialEpoch = 1;
  }

  addPasskey(id, name, authorization = {}) {
    if (!id || !name) throw new Error('named passkey required');
    if ([...this.recoveries.values()].some(r => r.state === 'cooling-off')) throw new Error('factor changes blocked during cooling-off');
    const session = authorization.sessionId && this.sessions.get(authorization.sessionId);
    const activeSessionAuthorized = session && session.revokedAt === null && session.aal >= 2 && session.epoch === this.credentialEpoch;
    const recovery = authorization.recoveryId && this.recoveries.get(authorization.recoveryId);
    const recoveryAuthorized = recovery && recovery.state === 'awaiting-enrollment' &&
      stableHash(authorization.enrollmentToken || '') === recovery.enrollmentTokenHash;
    if (!activeSessionAuthorized && !recoveryAuthorized) throw new Error('authorized factor enrollment required');
    this.passkeys.set(id, { id, name, revokedAt: null, epoch: this.credentialEpoch });
    if (recoveryAuthorized) {
      recovery.state = 'complete';
      recovery.enrollmentTokenHash = null;
      this.alerts.push({ type: 'post-recovery-passkey-enrolled', id, recoveryId: authorization.recoveryId });
    }
  }

  revokePasskey(id) {
    const key = this.passkeys.get(id);
    if (!key) throw new Error('unknown passkey');
    key.revokedAt = this.now();
    this.alerts.push({ type: 'passkey-revoked', id });
  }

  isPasskeyUsable(id) {
    const key = this.passkeys.get(id);
    return Boolean(key && key.revokedAt === null && key.epoch === this.credentialEpoch);
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

  issueStepUpChallenge({ sessionId, action, target }) {
    const session = this.sessions.get(sessionId);
    if (!session || session.revokedAt !== null || session.aal < 2) throw new Error('AAL2 active session required');
    const challenge = randomBytes(16).toString('base64url');
    this.stepUpChallenges.set(stableHash(challenge), {
      sessionId, action, target, issuedAt: this.now(), expiresAt: this.now() + FIVE_MINUTES_MS,
      epoch: this.credentialEpoch, consumedAt: null
    });
    return challenge;
  }

  issueStepUp({ sessionId, action, target, challenge, phishingResistant = false }) {
    const record = this.stepUpChallenges.get(stableHash(challenge || ''));
    if (!record || record.sessionId !== sessionId || record.action !== action || record.target !== target) {
      throw new Error('valid server-issued challenge required');
    }
    if (!phishingResistant) throw new Error('phishing-resistant ceremony required');
    const issuedAt = this.now();
    const payload = [sessionId, action, target, challenge, issuedAt, this.credentialEpoch, 'webauthn'].join('|');
    return { sessionId, action, target, challenge, issuedAt, epoch: this.credentialEpoch,
      method: 'webauthn', proof: createHmac('sha256', this.secret).update(payload).digest('hex') };
  }

  verifyAndConsumeStepUp(assertion, expected) {
    const session = this.sessions.get(expected.sessionId);
    if (!session || session.revokedAt !== null || session.aal < 2 || assertion.method !== 'webauthn') return false;
    if (this.now() - assertion.issuedAt > FIVE_MINUTES_MS || assertion.issuedAt > this.now()) return false;
    for (const field of ['sessionId', 'action', 'target', 'challenge']) {
      if (assertion[field] !== expected[field]) return false;
    }
    if (assertion.epoch !== this.credentialEpoch || session.epoch !== this.credentialEpoch) return false;
    const payload = [assertion.sessionId, assertion.action, assertion.target, assertion.challenge,
      assertion.issuedAt, assertion.epoch, assertion.method].join('|');
    const expectedProof = createHmac('sha256', this.secret).update(payload).digest();
    const actual = Buffer.from(assertion.proof, 'hex');
    if (actual.length !== expectedProof.length || !timingSafeEqual(actual, expectedProof)) return false;
    const challengeRecord = this.stepUpChallenges.get(stableHash(assertion.challenge));
    if (!challengeRecord || challengeRecord.consumedAt !== null || challengeRecord.expiresAt < this.now() ||
      challengeRecord.sessionId !== assertion.sessionId || challengeRecord.action !== assertion.action ||
      challengeRecord.target !== assertion.target || challengeRecord.epoch !== assertion.epoch) return false;
    challengeRecord.consumedAt = this.now();
    const assertionId = stableHash(payload + '|' + assertion.proof);
    this.auditEvents.push({ type: 'step-up-consumed', assertionId, action: assertion.action, target: assertion.target });
    return true;
  }

  createRecoveryCodes(count = 8) {
    const plaintext = [];
    for (let i = 0; i < count; i += 1) {
      const code = randomBytes(16).toString('hex');
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
    recovery.state = 'completing';
    this.revokeAll();
    const revokedAt = this.now();
    for (const key of this.passkeys.values()) key.revokedAt = revokedAt;
    for (const code of this.recoveryCodes.values()) code.revokedAt = revokedAt;
    this.credentialEpoch += 1;
    const enrollmentToken = randomBytes(16).toString('base64url');
    recovery.enrollmentTokenHash = stableHash(enrollmentToken);
    recovery.state = 'awaiting-enrollment';
    this.alerts.push({ type: 'all-passkeys-revoked-after-recovery', id });
    this.alerts.push({ type: 'recovery-completed', id });
    this.auditEvents.push({ type: 'global-credential-rotation', id, newEpoch: this.credentialEpoch });
    return enrollmentToken;
  }

  supportRecover() { throw new Error('support recovery forbidden'); }
  lostAllFactorsRecover() { throw new Error('lost-all-factor recovery fails closed'); }
}

module.exports = { AssuranceContract, FIVE_MINUTES_MS, COOLING_OFF_MS };
