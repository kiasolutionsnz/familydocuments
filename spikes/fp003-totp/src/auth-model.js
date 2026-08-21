import crypto from 'node:crypto';

export const MANIFEST_SHA256 = '7BC475F8A55891B65FBB9A7FFAEAFEE1DA22A3598F3889FA1E8B44661DEAE97F';
export const COOLING_OFF_SECONDS = 259200;
const B32 = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

export function hotpSha256(secret, counter) {
  const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(counter));
  const h = crypto.createHmac('sha256', secret).update(b).digest();
  const o = h[h.length - 1] & 15;
  return String((h.readUInt32BE(o) & 0x7fffffff) % 1_000_000).padStart(6, '0');
}

export function totp(secret, nowSeconds) { return hotpSha256(secret, Math.floor(nowSeconds / 30)); }

export class AuthModel {
  constructor(now = 1_800_000_000) {
    this.now = now; this.users = new Map(); this.sessions = new Map(); this.challenges = new Map();
    this.recoveries = new Map(); this.audit = []; this.rate = new Map();
  }
  genericRequest(kind, eligible) { if (eligible && kind !== 'sign_in_denial') this.event(`${kind}_queued`, { result: 'accepted' }); return { status: 202, contentType: 'application/json', body: { message: 'If eligible, the request will be processed.' }, cache: 'no-store', redirects: 0 }; }
  limit(key, maximum, windowSeconds, storeAvailable = true) { if (!storeAvailable) return false; const bucket=Math.floor(this.now/windowSeconds); const k=`${key}:${bucket}`; const n=(this.rate.get(k)??0)+1; this.rate.set(k,n); return n<=maximum; }
  rotateRefresh(token) { if (!this.refresh) this.refresh=new Set(); if(this.refresh.has(token)) return null; this.refresh.add(token); return crypto.randomBytes(32).toString('hex'); }
  addUser(id, password, verified = true) { this.users.set(id, { id, password, verified, epoch: 1, factor: null, usedSteps: new Set() }); }
  signIn(id, password) {
    const u = this.users.get(id); if (!u || !u.verified || u.password !== password) return { status: 202, body: { message: 'If the details are valid, continue.' } };
    const sid = crypto.randomUUID(); this.sessions.set(sid, { sid, uid: id, aal: 1, epoch: u.epoch, revoked: false });
    return { status: 200, sid, aal: 1 };
  }
  enrollTotp(sid) {
    const s = this.sessions.get(sid); if (!s || s.revoked) throw new Error('denied');
    const secret = crypto.randomBytes(32); this.users.get(s.uid).pendingFactor = secret;
    return { secret, qr: `otpauth://totp/FamilyPassport:${s.uid}` };
  }
  verifyTotp(sid, code, at = this.now) {
    const s = this.sessions.get(sid); if (!s || s.revoked) return false;
    const u = this.users.get(s.uid); const secret = u.factor ?? u.pendingFactor;
    for (const d of [-1, 0, 1]) { const step = Math.floor(at / 30) + d; if (hotpSha256(secret, step) === code && !u.usedSteps.has(step)) { u.usedSteps.add(step); u.factor = secret; delete u.pendingFactor; s.aal = 2; return true; } }
    return false;
  }
  newStepUp(sid, action, target) {
    const s = this.sessions.get(sid); if (!s || s.aal !== 2 || s.revoked) throw new Error('denied');
    const id = crypto.randomBytes(16).toString('hex'); this.challenges.set(id, { sid, uid: s.uid, action, target, epoch: s.epoch, exp: this.now + 300, used: false }); return id;
  }
  completeStepUp(id, { sid, action, target, password, code }) {
    const c = this.challenges.get(id); const s = this.sessions.get(sid); const u = s && this.users.get(s.uid);
    if (!c || c.used || !s || s.revoked || this.now > c.exp || c.sid !== sid || c.action !== action || c.target !== target || c.epoch !== u.epoch || u.password !== password) return false;
    if (!this.verifyTotp(sid, code)) return false; c.used = true; return true;
  }
  revokeAll(uid) { const u = this.users.get(uid); u.epoch++; for (const s of this.sessions.values()) if (s.uid === uid) s.revoked = true; }
  authorize(sid, sensitive = false) { const s = this.sessions.get(sid); const u = s && this.users.get(s.uid); return !!(s && u && !s.revoked && s.epoch === u.epoch && (!sensitive || s.aal === 2)); }
  requestRecovery(uid, key) { const prior = [...this.recoveries.values()].find(r => r.uid === uid && !['FAILED_NOTIFICATION','FAILED_COMPLETION','CANCELLED','EXPIRED','COMPLETED'].includes(r.state)); if (prior) return prior; const r = { id: crypto.randomUUID(), uid, key, state: 'NOTIFYING', version: 1 }; this.recoveries.set(r.id, r); return r; }
  acceptNotice(id, receiptAt) { const r = this.recoveries.get(id); if (r.state !== 'NOTIFYING') return false; r.state='COOLING_OFF'; r.notifiedAt=receiptAt; r.eligibleAt=receiptAt+COOLING_OFF_SECONDS; r.version++; return true; }
  failNotices(id) { const r=this.recoveries.get(id); if(r.state!=='NOTIFYING') return false; r.state='FAILED_NOTIFICATION'; r.version++; return true; }
  cancel(id) { const r=this.recoveries.get(id); if(!['NOTIFYING','COOLING_OFF'].includes(r.state)) return false; r.state='CANCELLED'; r.version++; return true; }
  complete(id, failAt = null) { const r=this.recoveries.get(id); if(r.state!=='COOLING_OFF'||this.now<r.eligibleAt) return false; const u=this.users.get(r.uid); const snapshot={...u, usedSteps:new Set(u.usedSteps)}; try { r.state='COMPLETING'; if(failAt==='rotate') throw new Error('fault'); u.password='replacement-password-value'; u.factor=crypto.randomBytes(32); this.revokeAll(u.id); if(failAt==='codes') throw new Error('fault'); r.state='COMPLETED'; return true; } catch { this.users.set(u.id,snapshot); this.revokeAll(u.id); r.state='FAILED_COMPLETION'; return false; } }
  makeRecoveryCodes() { return Array.from({length:10},()=>{let out='', bits=0, value=0; for(const b of crypto.randomBytes(20)){value=(value<<8)|b;bits+=8;while(bits>=5){out+=B32[(value>>>(bits-5))&31];bits-=5;}}return out;}); }
  event(eventType, data={}) { const forbidden=['password','totp','recovery_code','token','email_link','document_metadata','notification_body']; if(forbidden.some(k=>k in data)) throw new Error('forbidden audit field'); this.audit.push({eventType,...data}); }
}
