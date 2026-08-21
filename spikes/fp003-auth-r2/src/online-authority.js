'use strict';

const { createHash, randomBytes, timingSafeEqual } = require('node:crypto');

function hash(value) { return createHash('sha256').update(value).digest(); }
function randomToken() { return randomBytes(32).toString('base64url'); }
function equal(a, b) {
  const left = Buffer.from(a || ''); const right = Buffer.from(b || '');
  return left.length === right.length && timingSafeEqual(left, right);
}

class OnlineAuthority {
  constructor({ now = () => Date.now(), origin, redirectUri }) {
    this.now = now; this.origin = origin; this.redirectUri = redirectUri;
    this.flows = new Map(); this.sessions = new Map(); this.refreshFamilies = new Map(); this.alerts = [];
  }

  beginFlow() {
    const flow = { id: randomToken(), state: randomToken(), nonce: randomToken(), csrf: randomToken(), verifier: randomToken(), used: false };
    flow.pkceChallenge = hash(flow.verifier).toString('base64url');
    this.flows.set(flow.id, { ...flow, verifierHash: hash(flow.verifier) });
    return flow;
  }

  completeFlow(input) {
    const flow = this.flows.get(input.id);
    if (!flow || flow.used || input.origin !== this.origin || input.redirectUri !== this.redirectUri ||
      !equal(input.state, flow.state) || !equal(input.nonce, flow.nonce) || !equal(input.csrf, flow.csrf) ||
      !timingSafeEqual(hash(input.verifier || ''), flow.verifierHash)) return false;
    flow.used = true; return true;
  }

  createSession(id, providerIdentity = {}) {
    this.sessions.set(id, { revokedAt: null, epoch: 1, ...providerIdentity });
    this.refreshFamilies.set(id, { active: '0', used: new Set(), revokedAt: null });
    return { sessionId: id, refreshToken: '0' };
  }
  rotateRefresh(id, token) {
    const family = this.refreshFamilies.get(id); const session = this.sessions.get(id);
    if (!family || !session || family.revokedAt !== null || session.revokedAt !== null) return false;
    if (family.used.has(token) || token !== family.active) {
      family.revokedAt = this.now(); session.revokedAt = this.now(); session.epoch += 1;
      this.alerts.push({ type: 'refresh-reuse', id }); return false;
    }
    family.used.add(token); family.active = String(Number(token) + 1); return family.active;
  }
  authorize(id, epoch = 1) { const s = this.sessions.get(id); return Boolean(s && s.revokedAt === null && s.epoch === epoch); }
  revoke(id) {
    const s = this.sessions.get(id); if (!s) return false;
    s.revokedAt = this.now(); s.epoch += 1;
    const family = this.refreshFamilies.get(id); if (family) family.revokedAt = this.now();
    this.alerts.push({ type: 'session-revoked', id }); return true;
  }
  revokeAll() { for (const id of this.sessions.keys()) this.revoke(id); this.alerts.push({ type: 'all-sessions-revoked' }); }
  revokeProviderSession(providerSessionId) {
    let count = 0;
    for (const [id, session] of this.sessions) {
      if (session.providerSessionId === providerSessionId && session.revokedAt === null) { this.revoke(id); count += 1; }
    }
    return count;
  }
  revokeCredential(credentialId) {
    let count = 0;
    for (const [id, session] of this.sessions) {
      if (session.credentialId === credentialId && session.revokedAt === null) { this.revoke(id); count += 1; }
    }
    return count;
  }
}

module.exports = { OnlineAuthority };
