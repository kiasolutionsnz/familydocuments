import crypto from 'node:crypto';

const random = bytes => crypto.randomBytes(bytes).toString('base64url');
const digest = value => crypto.createHash('sha256').update(value).digest('base64url');
const same = (a, b) => {
  const x = Buffer.from(String(a)); const y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};

export const ROLES = Object.freeze(['owner', 'admin', 'adult', 'contributor', 'viewer']);
export const GOOGLE_ISSUERS = Object.freeze(['https://accounts.google.com', 'accounts.google.com']);
export const SESSION_COOKIE = '__Host-fp_session';

export class AuthGateway {
  constructor({ origin, googleClientId, now = () => Math.floor(Date.now() / 1000), oidcVerifier, identityProvider, membershipAuthority, assuranceAuthority }) {
    const parsed = new URL(origin);
    if (parsed.protocol !== 'https:' || parsed.pathname !== '/' || parsed.search || parsed.hash || parsed.hostname.includes('*')) throw new Error('exact HTTPS origin required');
    this.origin = parsed.origin;
    this.googleClientId = googleClientId;
    this.now = now;
    this.oidcVerifier = oidcVerifier;
    this.identityProvider = identityProvider;
    this.membershipAuthority = membershipAuthority;
    this.assuranceAuthority = assuranceAuthority;
    this.flows = new Map(); this.sessions = new Map(); this.invites = new Map(); this.grants = [];
  }

  async passwordSignIn(email, password) {
    let result;
    try { result = await this.identityProvider.verifyPassword(normalizeEmail(email), password); } catch { return genericDenial(); }
    if (!result?.verified || !result?.subject) return genericDenial();
    return this.#newSession(result.subject, 1);
  }

  startGoogle(browserSessionId) {
    const id = random(24), state = random(32), nonce = random(32), verifier = random(48);
    const callback = `${this.origin}/auth/google/callback`;
    this.flows.set(id, { browserSessionId, stateHash: digest(state), nonceHash: digest(nonce), verifier, exp: this.now() + 300, used: false });
    const url = new URL('https://accounts.google.com/o/oauth2/v2/auth');
    url.search = new URLSearchParams({ client_id: this.googleClientId, redirect_uri: callback, response_type: 'code', scope: 'openid email profile', state, nonce, code_challenge: digest(verifier), code_challenge_method: 'S256', prompt: 'select_account' });
    return { flowId: id, authorizationUrl: url.toString() };
  }

  async finishGoogle({ flowId, browserSessionId, state, code }) {
    const flow = this.flows.get(flowId);
    if (!flow || flow.used || flow.exp <= this.now() || flow.browserSessionId !== browserSessionId || !same(flow.stateHash, digest(state))) return genericDenial();
    flow.used = true;
    const claims = await this.oidcVerifier.exchangeAndVerify({ code, pkceVerifier: flow.verifier, redirectUri: `${this.origin}/auth/google/callback` });
    delete flow.verifier;
    if (!claims || !GOOGLE_ISSUERS.includes(claims.iss) || claims.aud !== this.googleClientId || claims.exp <= this.now() || claims.iat > this.now() + 60 || claims.email_verified !== true || !claims.sub || !same(flow.nonceHash, digest(claims.nonce))) return genericDenial();
    return this.#newSession(`google:${claims.sub}`, 1);
  }

  #newSession(subject, aal) {
    const raw = random(32); this.sessions.set(digest(raw), { subject, aal, epoch: 1, revoked: false, createdAt: this.now() });
    return { status: 200, session: raw, cookie: `${SESSION_COOKIE}=${raw}; Path=/; Max-Age=43200; HttpOnly; Secure; SameSite=Lax` };
  }

  revokeSession(raw) { const session = this.sessions.get(digest(raw)); if (session) session.revoked = true; }
  session(raw) { const value = this.sessions.get(digest(raw)); return value && !value.revoked ? { ...value } : null; }

  async issueInvite({ actorSession, familyId, email, role, stepUpProof, ttlSeconds = 604800 }) {
    const actor = this.session(actorSession);
    const inviteEmail = normalizeEmail(email);
    const actorRole = actor && await this.membershipAuthority.roleFor(actor.subject, familyId);
    const steppedUp = actor && await this.assuranceAuthority.verify({ subject: actor.subject, session: actorSession, action: 'invite_member', target: familyId, proof: stepUpProof });
    if (!actor || !steppedUp || !['owner', 'admin'].includes(actorRole) || !ROLES.includes(role) || role === 'owner' || !validEmail(inviteEmail) || !Number.isInteger(ttlSeconds) || ttlSeconds < 60 || ttlSeconds > 604800) throw new Error('denied');
    const raw = random(32); this.invites.set(digest(raw), { familyId, email: inviteEmail, role, exp: this.now() + ttlSeconds, used: false }); return raw;
  }

  async acceptInvite({ token, actorSession }) {
    const invite = this.invites.get(digest(token));
    const actor = this.session(actorSession);
    let identity;
    try { identity = actor && await this.identityProvider.verifiedIdentityFor(actor.subject); } catch { return null; }
    if (!invite || !actor || invite.used || invite.exp <= this.now() || !identity || identity.verified !== true || identity.subject !== actor.subject || !validEmail(identity.email) || invite.email !== normalizeEmail(identity.email)) return null;
    invite.used = true; return Object.freeze({ familyId: invite.familyId, subject: actor.subject, role: invite.role });
  }

  addGrant(grant) {
    if (!grant.familyId || !grant.subject || !['category', 'entity', 'document'].includes(grant.resourceType) || !grant.resourceId || !['view', 'contribute', 'manage'].includes(grant.permission)) throw new Error('invalid grant');
    this.grants.push(Object.freeze({ ...grant }));
  }

  authorize({ subject, familyId, action, resource }) {
    if (!subject || !familyId || !resource || resource.familyId !== familyId) return false;
    if (resource.privateTo && resource.privateTo !== subject) return false;
    const rank = { view: 1, contribute: 2, manage: 3 };
    return this.grants.some(g => g.subject === subject && g.familyId === familyId && g.resourceType === resource.type && g.resourceId === resource.id && rank[g.permission] >= rank[action]);
  }
}

export function normalizeEmail(value) { return String(value ?? '').trim().toLowerCase(); }
export function validEmail(value) { return typeof value === 'string' && value.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value); }
export function genericDenial() { return { status: 202, body: { message: 'If the details are valid, continue.' }, cache: 'no-store' }; }
