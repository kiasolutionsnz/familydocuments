import assert from 'node:assert/strict';

const authUrl = 'http://127.0.0.1:55321';
const mailUrl = 'http://127.0.0.1:55324';
const suffix = `${Date.now()}-${crypto.randomUUID().slice(0, 8)}`;
const email = `synthetic-${suffix}@family-passport.test`;
const password = `Synthetic-${suffix}-Password!`;

const json = async (url, options = {}) => {
  const response = await fetch(url, options);
  const body = await response.json().catch(() => ({}));
  return {response, body};
};

const signup = await json(`${authUrl}/signup`, {
  method: 'POST',
  headers: {'content-type': 'application/json'},
  body: JSON.stringify({email, password})
});
assert.equal(signup.response.status, 200, JSON.stringify(signup.body));
assert.equal(signup.body.session ?? null, null, 'unverified signup must not receive a session');

const unverifiedSignin = await json(`${authUrl}/token?grant_type=password`, {
  method: 'POST',
  headers: {'content-type': 'application/json'},
  body: JSON.stringify({email, password})
});
assert.notEqual(unverifiedSignin.response.status, 200, 'unverified email must not sign in');

let message;
for (let attempt = 0; attempt < 20 && !message; attempt++) {
  await new Promise(resolve => setTimeout(resolve, 250));
  const listing = await json(`${mailUrl}/api/v1/messages`);
  message = listing.body.messages?.find(item => item.To?.some?.(to => to.Address === email));
}
assert.ok(message, 'confirmation message was not captured');

const detail = await json(`${mailUrl}/api/v1/message/${message.ID}`);
const content = [detail.body.Text, detail.body.HTML].filter(Boolean).join('\n');
const link = content.match(/https?:\/\/[^\s"'<>]+\/verify\?[^\s"'<>]+/i)?.[0]?.replaceAll('&amp;', '&');
assert.ok(link, 'confirmation link missing from captured message');
const confirmation = await fetch(link, {redirect: 'manual'});
assert.ok([200, 302, 303].includes(confirmation.status), `confirmation failed: ${confirmation.status}`);

const signin = await json(`${authUrl}/token?grant_type=password`, {
  method: 'POST',
  headers: {'content-type': 'application/json'},
  body: JSON.stringify({email, password})
});
assert.equal(signin.response.status, 200, JSON.stringify(signin.body));
assert.equal(signin.body.user?.email, email);
assert.ok(signin.body.access_token);
assert.ok(signin.body.refresh_token);

const weak = await json(`${authUrl}/signup`, {
  method: 'POST',
  headers: {'content-type': 'application/json'},
  body: JSON.stringify({email: `weak-${suffix}@family-passport.test`, password: 'TooShort1!'})
});
assert.notEqual(weak.response.status, 200, 'password shorter than 14 characters must be rejected');

console.log(JSON.stringify({signup:'PASS', unverified_denial:'PASS', email_confirmation:'PASS', signin:'PASS', weak_password_denial:'PASS', synthetic_email:email}));
