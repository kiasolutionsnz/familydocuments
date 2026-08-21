import crypto from 'node:crypto';
import { SESSION_COOKIE, genericDenial, validEmail } from './auth-gateway.js';

const JSON_TYPE = 'application/json';
const MAX_BODY_BYTES = 16_384;
const AUTHORITY_TIMEOUT_MS = 100;
const json = (status, body, headers = {}) => ({ status, headers: { 'content-type': JSON_TYPE, 'cache-control': 'no-store', ...headers }, body });
const denied = () => json(202, genericDenial().body);
const bad = () => json(400, { message: 'The request could not be processed.' });
const opaqueKey = value => typeof value === 'string' && /^[A-Za-z0-9_-]{32,256}$/.test(value);
const bounded = promise => Promise.race([promise, new Promise(resolve => setTimeout(() => resolve(null), AUTHORITY_TIMEOUT_MS))]);

function exactObject(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

function parseJson(request) {
  if (String(request.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase() !== JSON_TYPE) return null;
  if (typeof request.body !== 'string' || Buffer.byteLength(request.body) > MAX_BODY_BYTES) return null;
  try { return JSON.parse(request.body); } catch { return null; }
}

function cookies(header = '') {
  const result = new Map();
  for (const item of header.split(';')) {
    const at = item.indexOf('='); if (at < 1) continue;
    const key = item.slice(0, at).trim(), value = item.slice(at + 1).trim();
    if (!key || result.has(key)) return null; result.set(key, value);
  }
  return result;
}

export class AuthHttpBoundary {
  constructor({ gateway, origin, rateLimiter, requestIdentity, accountKeyAuthority, csrfAuthority, invitationService }) {
    this.gateway = gateway; this.origin = origin; this.rateLimiter = rateLimiter; this.requestIdentity = requestIdentity; this.accountKeyAuthority = accountKeyAuthority; this.csrfAuthority = csrfAuthority; this.invitationService = invitationService;
  }

  async handle(request) {
    try {
      if (!request || !['GET', 'POST'].includes(request.method) || typeof request.url !== 'string' || !request.headers || typeof request.headers !== 'object') return bad();
      const url = new URL(request.url, this.origin);
      if (url.origin !== this.origin) return bad();
      const jar = cookies(request.headers.cookie); if (jar === null) return bad();
      if (url.pathname !== '/auth/google/callback' && url.search !== '') return bad();

      if (request.method === 'POST' && request.headers.origin !== this.origin) return denied();

      if (request.method === 'POST' && url.pathname === '/auth/password/sign-in') {
        const body = parseJson(request);
        if (!exactObject(body, ['email', 'password']) || !validEmail(String(body.email ?? '').trim().toLowerCase()) || typeof body.password !== 'string' || body.password.length < 8 || body.password.length > 1024) return bad();
        const networkKey = await bounded(this.requestIdentity.networkKey(request));
        const accountKey = await bounded(this.accountKeyAuthority.key(String(body.email).trim().toLowerCase()));
        if (!opaqueKey(networkKey) || !opaqueKey(accountKey)) return denied();
        const allowed = await bounded(this.rateLimiter.allow({ route: 'signin', networkKey, accountKey }));
        if (allowed !== true) return denied();
        const result = await this.gateway.passwordSignIn(body.email, body.password);
        return result.status === 200 ? json(200, { authenticated: true, aal: 1 }, { 'set-cookie': result.cookie }) : denied();
      }

      if (request.method === 'GET' && url.pathname === '/auth/google/start') {
        if (request.headers['sec-fetch-site'] && !['same-origin', 'none'].includes(request.headers['sec-fetch-site'])) return denied();
        const browserId = crypto.randomBytes(24).toString('base64url');
        const result = this.gateway.startGoogle(browserId);
        return { status: 302, headers: { location: result.authorizationUrl, 'cache-control': 'no-store', 'set-cookie': `__Host-fp_oidc=${result.flowId}.${browserId}; Path=/; Max-Age=300; HttpOnly; Secure; SameSite=Lax` }, body: null };
      }

      if (request.method === 'GET' && url.pathname === '/auth/google/callback') {
        if ([...url.searchParams.keys()].some(k => !['state', 'code'].includes(k)) || url.searchParams.getAll('state').length !== 1 || url.searchParams.getAll('code').length !== 1 || !url.searchParams.get('state') || !url.searchParams.get('code')) return bad();
        const binding = jar.get('__Host-fp_oidc'); const parts = binding?.split('.') ?? [];
        if (parts.length !== 2 || parts.some(x => !/^[A-Za-z0-9_-]{20,}$/.test(x))) return denied();
        const result = await this.gateway.finishGoogle({ flowId: parts[0], browserSessionId: parts[1], state: url.searchParams.get('state'), code: url.searchParams.get('code') });
        return result.status === 200 ? json(200, { authenticated: true, aal: 1 }, { 'set-cookie': [result.cookie, '__Host-fp_oidc=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax'] }) : denied();
      }

      if (request.method === 'GET' && url.pathname === '/auth/csrf') {
        const session = jar.get(SESSION_COOKIE);
        if (!session || (request.headers['sec-fetch-site'] && request.headers['sec-fetch-site'] !== 'same-origin')) return denied();
        const token = await bounded(this.csrfAuthority.issue(session));
        if (!opaqueKey(token)) return denied();
        return json(200, { csrfToken: token }, { 'set-cookie': `__Host-fp_csrf=${token}; Path=/; Max-Age=600; Secure; SameSite=Strict` });
      }

      const inviteMatch = request.method === 'POST' && url.pathname.match(/^\/families\/([A-Za-z0-9_-]{1,64})\/invitations$/);
      if (inviteMatch) {
        const session = jar.get(SESSION_COOKIE); if (!session || !await this.#csrf(request, jar)) return denied();
        const body = parseJson(request);
        if (!exactObject(body, ['email', 'role', 'stepUpProof']) || typeof body.stepUpProof !== 'string') return bad();
        const accepted = await this.invitationService.issueAndDeliver({ actorSession: session, familyId: inviteMatch[1], email: body.email, role: body.role, stepUpProof: body.stepUpProof });
        return accepted ? json(202, { message: 'If eligible, the invitation will be delivered.' }) : denied();
      }

      if (request.method === 'POST' && url.pathname === '/invitations/accept') {
        const session = jar.get(SESSION_COOKIE); if (!session || !await this.#csrf(request, jar)) return denied();
        const body = parseJson(request); if (!exactObject(body, ['token']) || typeof body.token !== 'string' || body.token.length < 32) return bad();
        const membership = await this.gateway.acceptInvite({ token: body.token, actorSession: session });
        return membership ? json(200, membership) : denied();
      }

      return json(404, { message: 'Not found.' });
    } catch { return denied(); }
  }

  async #csrf(request, jar) {
    const cookie = jar.get('__Host-fp_csrf'), header = request.headers['x-fp-csrf'];
    const session = jar.get(SESSION_COOKIE);
    return await bounded(this.csrfAuthority.verify({ session, cookie, header })) === true;
  }
}
