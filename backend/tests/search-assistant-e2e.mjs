import assert from 'node:assert/strict';
import {isolatedContext, syntheticAccount} from './isolated-context.mjs';

const {api, search: assistant} = isolatedContext();
async function post(url, bearer, body) {
  const response = await fetch(url, {method: 'POST', headers: {origin: 'http://127.0.0.1:3300', authorization: `Bearer ${bearer}`, 'content-type': 'application/json'}, body: JSON.stringify(body)});
  return {response, json: await response.json()};
}
const owner = await syntheticAccount('search-owner'), viewer = await syntheticAccount('search-viewer'), outsider = await syntheticAccount('search-outsider');
const rpc = (user, name, body = {}) => post(`${api}/rpc/${name}`, user.token, body);
const household = await rpc(owner, 'bootstrap_household', {household_name: 'Synthetic search family', display_name: 'Search owner'});
assert.equal(household.response.status, 200, JSON.stringify(household.json));
const category = household.json.categories[0].id;
const invitation = await rpc(owner, 'invite_member', {invitee_email: viewer.email, member_role: 'viewer'});
assert.equal(invitation.response.status, 200, JSON.stringify(invitation.json));
assert.equal((await rpc(viewer, 'accept_my_invitation')).response.status, 200);
const sharedDocument = await rpc(owner, 'create_document', {document_title: 'Synthetic school record', category});
assert.equal(sharedDocument.response.status, 200, JSON.stringify(sharedDocument.json));
assert.equal((await rpc(owner, 'set_document_access', {document: sharedDocument.json.id, member: viewer.userId, access: 'view'})).response.status, 200);
assert.equal((await rpc(owner, 'create_document', {document_title: 'Private search sentinel', category})).response.status, 200);
assert.equal((await rpc(outsider, 'bootstrap_household', {household_name: 'Different synthetic family', display_name: 'Other owner'})).response.status, 200);
for (const user of [owner, viewer]) {
  const shared = await rpc(user, 'search_household_records', {search_query: 'Synthetic school record', result_limit: 20});
  assert.equal(shared.response.status, 200, JSON.stringify(shared.json));
  assert.equal(shared.json.length, 1);
  assert.equal(shared.json[0].title, 'Synthetic school record');
}
for (const [user, query] of [[viewer, 'Private search sentinel'], [outsider, 'Synthetic school record']]) {
  const denied = await rpc(user, 'search_household_records', {search_query: query, result_limit: 20});
  assert.equal(denied.response.status, 200);
  assert.deepEqual(denied.json, [], 'Inaccessible documents must not reveal titles, counts or sources');
}
// The isolated assistant deliberately has no AI service: retrieval must still work.
const fallback = await post(`${assistant}/ask`, owner.token, {query: 'Find the synthetic school record'});
assert.equal(fallback.response.status, 200, JSON.stringify(fallback.json));
assert.ok(fallback.json.sources.some(source => source.id === sharedDocument.json.id));
assert.ok(fallback.json.cited_ids.every(id => fallback.json.sources.some(source => source.id === id)));
const denied = await fetch(`${assistant}/ask`, {method: 'POST', headers: {'content-type': 'application/json'}, body: '{"query":"school"}'});
assert.equal(denied.status, 401);
console.log(JSON.stringify({real_auth_synthetic_search: 'PASS', shared_permission: 'PASS', private_and_cross_household_non_disclosure: 'PASS', ai_unavailable_fallback: 'PASS', citation_subset: 'PASS', unauthenticated_denial: 'PASS'}));
