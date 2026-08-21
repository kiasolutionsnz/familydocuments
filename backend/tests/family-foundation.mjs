import assert from 'node:assert/strict';

const authUrl='http://127.0.0.1:55321', apiUrl='http://127.0.0.1:55322', mailUrl='http://127.0.0.1:55324';
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
const created=await rpc(owner,'bootstrap_household',{household_name:'Synthetic test household',display_name:'Synthetic Owner'});
assert.equal(created.response.status,200,JSON.stringify(created.body));assert.equal(created.body.current_user.role,'owner');assert.equal(created.body.categories.length,6);
const invited=await rpc(owner,'invite_member',{invitee_email:member.email,member_role:'viewer'});assert.equal(invited.response.status,200,JSON.stringify(invited.body));
const accepted=await rpc(member,'accept_my_invitation');assert.equal(accepted.response.status,200,JSON.stringify(accepted.body));assert.equal(accepted.body.current_user.role,'viewer');
const category=await rpc(owner,'create_category',{category_name:'School'});assert.equal(category.response.status,200,JSON.stringify(category.body));
const document=await rpc(owner,'create_document',{document_title:'Synthetic school record',category:category.body.id});assert.equal(document.response.status,200,JSON.stringify(document.body));
const before=await rpc(member,'household_snapshot');assert.equal(before.response.status,200);assert.equal(before.body.documents.length,0,'viewer must not see unshared document');
const granted=await rpc(owner,'set_document_access',{document:document.body.id,member:member.userId,access:'view'});assert.equal(granted.response.status,200,JSON.stringify(granted.body));
const after=await rpc(member,'household_snapshot');assert.equal(after.response.status,200);assert.equal(after.body.documents.length,1,'shared document must become visible');
const denied=await rpc(member,'create_category',{category_name:'Should fail'});assert.equal(denied.response.status,403,'viewer cannot create categories');
const outside=await rpc(outsider,'household_snapshot');assert.equal(outside.response.status,200);assert.equal(outside.body.needs_setup,true);assert.equal(outside.body.household,undefined);
console.log(JSON.stringify({household_bootstrap:'PASS',invitation_acceptance:'PASS',custom_category:'PASS',default_deny:'PASS',document_grant:'PASS',viewer_write_denial:'PASS',outsider_isolation:'PASS'}));
