'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { performance } = require('node:perf_hooks');
const { OnlineAuthority } = require('../src/online-authority');

test('exact origin/redirect and state/nonce/PKCE/CSRF all fail closed and flow is single use', () => {
  const expected = { origin: 'http://localhost:43117', redirectUri: 'http://localhost:43117/callback' };
  for (const field of ['origin', 'redirectUri', 'state', 'nonce', 'csrf', 'verifier']) {
    const auth = new OnlineAuthority(expected); const f = auth.beginFlow();
    assert.equal(auth.completeFlow({ ...f, ...expected, [field]: 'wrong' }), false, field);
  }
  const auth = new OnlineAuthority(expected); const f = auth.beginFlow();
  assert.equal(auth.completeFlow({ ...f, ...expected }), true);
  assert.equal(auth.completeFlow({ ...f, ...expected }), false);
});

test('online API authority rejects individual/global revocation under concurrent checks well below 60s', async () => {
  const auth = new OnlineAuthority({ origin: 'http://localhost:43117', redirectUri: 'http://localhost:43117/callback' });
  auth.createSession('a'); auth.createSession('b');
  const start = performance.now(); auth.revoke('a');
  const denied = await Promise.all(Array.from({ length: 2000 }, async () => !auth.authorize('a')));
  const individualMs = performance.now() - start;
  assert.equal(denied.every(Boolean), true); assert.ok(individualMs < 60_000);
  const allStart = performance.now(); auth.revokeAll();
  const allDenied = await Promise.all(Array.from({ length: 2000 }, async () => !auth.authorize('b')));
  const globalMs = performance.now() - allStart;
  assert.equal(allDenied.every(Boolean), true); assert.ok(globalMs < 60_000);
  assert.equal(auth.alerts.some(a => a.type === 'session-revoked'), true);
  assert.equal(auth.alerts.some(a => a.type === 'all-sessions-revoked'), true);
});

test('concurrent refresh reuse permits one rotation then revokes the online session family', async () => {
  const auth = new OnlineAuthority({ origin: 'http://localhost:43117', redirectUri: 'http://localhost:43117/callback' });
  auth.createSession('race');
  const results = await Promise.all(Array.from({ length: 100 }, async () => auth.rotateRefresh('race', '0')));
  assert.equal(results.filter(value => value === '1').length, 1);
  assert.equal(auth.authorize('race'), false);
  assert.equal(auth.rotateRefresh('race', '1'), false);
  assert.equal(auth.alerts.some(a => a.type === 'refresh-reuse'), true);
});
