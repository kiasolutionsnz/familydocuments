import assert from 'node:assert/strict';
import {isolatedContext, stepUpMfa} from './isolated-context.mjs';

const {auth: authUrl, api: apiUrl, mail: mailUrl}=isolatedContext();
const suffix=`${Date.now()}-${crypto.randomUUID().slice(0,8)}`;

async function json(url,options={}){const response=await fetch(url,options);const body=await response.json().catch(()=>({}));return {response,body}}
async function account(label){
  const email=`${label}-${suffix}@family-passport.test`,password=`Synthetic-${label}-${suffix}-Password!`;
  const signup=await json(`${authUrl}/signup`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email,password})});
  assert.equal(signup.response.status,200,JSON.stringify(signup.body));
  let message;
  for(let i=0;i<24&&!message;i++){await new Promise(r=>setTimeout(r,250));const listing=await json(`${mailUrl}/api/v1/messages`);message=listing.body.messages?.find(x=>x.To?.some?.(to=>to.Address===email))}
  assert.ok(message,`confirmation missing for ${label}`);
  const detail=await json(`${mailUrl}/api/v1/message/${message.ID}`);const content=[detail.body.Text,detail.body.HTML].filter(Boolean).join('\n');
  const link=content.match(/https?:\/\/[^\s"'<>]+\/verify\?[^\s"'<>]+/i)?.[0]?.replaceAll('&amp;','&');assert.ok(link);
  const confirmation=await fetch(link,{redirect:'manual'});assert.ok([200,302,303].includes(confirmation.status));
  const signin=await json(`${authUrl}/token?grant_type=password`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email,password})});
  assert.equal(signin.response.status,200,JSON.stringify(signin.body));
  return {email,userId:signin.body.user.id,token:signin.body.access_token};
}
async function rpc(user,name,payload={}){return json(`${apiUrl}/rpc/${name}`,{method:'POST',headers:{authorization:`Bearer ${user.token}`,'content-type':'application/json'},body:JSON.stringify(payload)})}

const owner=await account('owner'),member=await account('member'),outsider=await account('outsider');
owner.token=await stepUpMfa(authUrl,owner.token);
const created=await rpc(owner,'bootstrap_household',{household_name:'Synthetic test household',display_name:'Synthetic Owner'});
assert.equal(created.response.status,200,JSON.stringify(created.body));assert.equal(created.body.current_user.role,'owner');assert.equal(created.body.categories.length,8);
assert.match(created.body.inbox.address,/^family-[0-9a-f]{24}@familydocuments[.]app$/);const firstInbox=created.body.inbox.address;
const invited=await rpc(owner,'invite_member',{invitee_email:member.email,member_role:'viewer'});assert.equal(invited.response.status,200,JSON.stringify(invited.body));
const accepted=await rpc(member,'accept_my_invitation');assert.equal(accepted.response.status,200,JSON.stringify(accepted.body));assert.equal(accepted.body.current_user.role,'viewer');assert.equal(accepted.body.inbox,null,'non-admin must not receive the inbox address');
const category=await rpc(owner,'create_category',{category_name:'School'});assert.equal(category.response.status,200,JSON.stringify(category.body));
const document=await rpc(owner,'create_document',{document_title:'Synthetic school record',category:category.body.id});assert.equal(document.response.status,200,JSON.stringify(document.body));
const before=await rpc(member,'household_snapshot');assert.equal(before.response.status,200);assert.equal(before.body.documents.length,0,'viewer must not see unshared document');
const granted=await rpc(owner,'set_document_access',{document:document.body.id,member:member.userId,access:'view'});assert.equal(granted.response.status,200,JSON.stringify(granted.body));
const after=await rpc(member,'household_snapshot');assert.equal(after.response.status,200);assert.equal(after.body.documents.length,1,'shared document must become visible');
const denied=await rpc(member,'create_category',{category_name:'Should fail'});assert.equal(denied.response.status,403,'viewer cannot create categories');
const outside=await rpc(outsider,'household_snapshot');assert.equal(outside.response.status,200);assert.equal(outside.body.needs_setup,true);assert.equal(outside.body.household,undefined);
const memberRotate=await rpc(member,'rotate_household_inbox');assert.equal(memberRotate.response.status,403,'viewer cannot rotate inbox');
const rotated=await rpc(owner,'rotate_household_inbox');assert.equal(rotated.response.status,200,JSON.stringify(rotated.body));assert.match(rotated.body.inbox.address,/^family-[0-9a-f]{24}@familydocuments[.]app$/);assert.notEqual(rotated.body.inbox.address,firstInbox);
const disabled=await rpc(owner,'disable_household_inbox');assert.equal(disabled.response.status,200);assert.equal(disabled.body.inbox,null);
const enabled=await rpc(owner,'enable_household_inbox');assert.equal(enabled.response.status,200);assert.match(enabled.body.inbox.address,/^family-[0-9a-f]{24}@familydocuments[.]app$/);assert.notEqual(enabled.body.inbox.address,rotated.body.inbox.address);
const privacy=await rpc(owner,'set_document_privacy',{document:document.body.id,mode:'shared_by_rules'});assert.equal(privacy.response.status,200,JSON.stringify(privacy.body));
const rule=await rpc(owner,'set_access_rule',{rule_scope:'category',scope_id:category.body.id,member:member.userId,access:'view'});assert.equal(rule.response.status,200,JSON.stringify(rule.body));
const rules=await rpc(owner,'access_rule_summaries');assert.equal(rules.response.status,200,JSON.stringify(rules.body));assert.equal(rules.body.length,1);
const removeRule=await rpc(owner,'set_access_rule',{rule_scope:'category',scope_id:category.body.id,member:member.userId,access:'none'});assert.equal(removeRule.response.status,200,JSON.stringify(removeRule.body));
const explicitSurvives=await rpc(member,'household_snapshot');assert.equal(explicitSurvives.body.documents.length,1,'removing a rule must preserve an explicit share');
const revoke=await rpc(owner,'set_document_access',{document:document.body.id,member:member.userId,access:'none'});assert.equal(revoke.response.status,200,JSON.stringify(revoke.body));
const revokedSnapshot=await rpc(member,'household_snapshot');assert.equal(revokedSnapshot.body.documents.length,0,'revoked access must disappear');
const audit=await rpc(owner,'permission_audit_summaries',{result_limit:20});assert.equal(audit.response.status,200,JSON.stringify(audit.body));assert.ok(audit.body.length>=5);
const deniedRule=await rpc(member,'set_access_rule',{rule_scope:'category',scope_id:category.body.id,member:member.userId,access:'view'});assert.equal(deniedRule.response.status,403,'viewer cannot create access defaults');
console.log(JSON.stringify({household_bootstrap:'PASS',household_inbox:'PASS',inbox_admin_boundary:'PASS',inbox_rotation_disable_enable:'PASS',invitation_acceptance:'PASS',custom_category:'PASS',default_deny:'PASS',document_grant:'PASS',permission_rules:'PASS',manual_share_preservation:'PASS',revocation:'PASS',permission_audit:'PASS',viewer_write_denial:'PASS',outsider_isolation:'PASS',active_inbox:enabled.body.inbox.address}));
