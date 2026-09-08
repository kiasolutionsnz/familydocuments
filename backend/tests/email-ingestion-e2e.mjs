import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {isolatedContext,ingestSyntheticEmail} from './isolated-context.mjs';

const {auth:authUrl,api:apiUrl,mail:mailUrl}=isolatedContext();
const suffix=`${Date.now()}-${crypto.randomUUID().slice(0,8)}`,subject=`Synthetic power bill ${suffix}`;
async function json(url,options={}){const response=await fetch(url,options);const body=await response.json().catch(()=>({}));return {response,body}}
async function account(label){
  const email=`ingest-${label}-${suffix}@family-passport.test`,password=`Synthetic-${label}-${suffix}-Password!`;
  const signup=await json(`${authUrl}/signup`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email,password})});assert.equal(signup.response.status,200,JSON.stringify(signup.body));
  let message;for(let i=0;i<24&&!message;i++){await new Promise(r=>setTimeout(r,250));const listing=await json(`${mailUrl}/api/v1/messages`);message=listing.body.messages?.find(x=>x.To?.some?.(to=>to.Address===email))}assert.ok(message);
  const detail=await json(`${mailUrl}/api/v1/message/${message.ID}`),content=[detail.body.Text,detail.body.HTML].filter(Boolean).join('\n');
  const link=content.match(/https?:\/\/[^\s"'<>]+\/verify\?[^\s"'<>]+/i)?.[0]?.replaceAll('&amp;','&');assert.ok(link);await fetch(link,{redirect:'manual'});
  const signin=await json(`${authUrl}/token?grant_type=password`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email,password})});assert.equal(signin.response.status,200,JSON.stringify(signin.body));
  return {email,token:signin.body.access_token};
}
async function rpc(user,name,payload={}){return json(`${apiUrl}/rpc/${name}`,{method:'POST',headers:{authorization:`Bearer ${user.token}`,'content-type':'application/json'},body:JSON.stringify(payload)})}

const owner=await account('owner'),viewer=await account('viewer');
const household=await rpc(owner,'bootstrap_household',{household_name:'Synthetic ingestion household',display_name:'Inbox owner'});assert.equal(household.response.status,200);const address=household.body.inbox.address;
await rpc(owner,'invite_member',{invitee_email:viewer.email,member_role:'viewer'});assert.equal((await rpc(viewer,'accept_my_invitation')).response.status,200);
const root=fileURLToPath(new URL('..',import.meta.url));
const first=await ingestSyntheticEmail(address,subject,`${root}\\tests\\fixtures\\synthetic-bill.pdf`,suffix);assert.equal(first.duplicate,false);
const second=await ingestSyntheticEmail(address,subject,`${root}\\tests\\fixtures\\synthetic-bill.pdf`,suffix);assert.equal(second.duplicate,true);
const summaries=await rpc(owner,'inbound_email_summaries');assert.equal(summaries.response.status,200,JSON.stringify(summaries.body));
const matches=summaries.body.filter(x=>x.subject===subject);assert.equal(matches.length,1,'idempotent worker must retain one source message');assert.equal(matches[0].attachment_count,1);assert.equal(matches[0].attachment_status,'sender_quarantine');assert.equal(matches[0].processing_status,'awaiting_classification');assert.match(matches[0].raw_sha256,/^[0-9a-f]{64}$/);
const allowed=await rpc(owner,'set_inbound_sender_rule',{sender:'synthetic-sender@family-passport.test',rule_action:'allow'});assert.equal(allowed.response.status,200,JSON.stringify(allowed.body));
const released=await rpc(owner,'inbound_email_summaries');assert.equal(released.body.find(x=>x.id===first.email_id).attachment_status,'quarantined_unscanned');
assert.equal((await rpc(viewer,'inbound_email_summaries')).response.status,403,'viewer must not list household inbound email');
console.log(JSON.stringify({hmac_gateway_ingestion:'PASS',alias_resolution:'PASS',raw_source_hash:'PASS',pdf_preserved_in_rfc822:'PASS',sender_quarantine_and_deliberate_allow:'PASS',attachment_quarantine:'PASS',idempotent_ingestion:'PASS',admin_only_listing:'PASS'}));
