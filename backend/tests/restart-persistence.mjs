import assert from 'node:assert/strict';

const authUrl = 'http://127.0.0.1:55321';
const mailUrl = 'http://127.0.0.1:55324';
const email = 'synthetic-persistence@family-passport.test';
const password = 'Synthetic-Persistence-Only!2026';
const request = async (url, options = {}) => {
  const response = await fetch(url, options);
  const body = await response.json().catch(() => ({}));
  return {response, body};
};

const signin = () => request(`${authUrl}/token?grant_type=password`, {
  method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({email, password})
});

let result = await signin();
if (result.response.status !== 200) {
  const signup = await request(`${authUrl}/signup`, {
    method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({email, password})
  });
  assert.ok([200, 422].includes(signup.response.status), JSON.stringify(signup.body));
  let message;
  for (let i = 0; i < 20 && !message; i++) {
    await new Promise(resolve => setTimeout(resolve, 250));
    const list = await request(`${mailUrl}/api/v1/messages`);
    message = list.body.messages?.find(item => item.To?.some?.(to => to.Address === email));
  }
  assert.ok(message, 'persistence fixture confirmation email missing');
  const detail = await request(`${mailUrl}/api/v1/message/${message.ID}`);
  const content = [detail.body.Text, detail.body.HTML].filter(Boolean).join('\n');
  const link = content.match(/https?:\/\/[^\s"'<>]+\/verify\?[^\s"'<>]+/i)?.[0]?.replaceAll('&amp;', '&');
  assert.ok(link);
  const verified = await fetch(link, {redirect: 'manual'});
  assert.ok([200, 302, 303].includes(verified.status));
  result = await signin();
}
assert.equal(result.response.status, 200, JSON.stringify(result.body));
assert.equal(result.body.user?.email, email);
console.log(JSON.stringify({persistent_verified_user_signin:'PASS'}));
