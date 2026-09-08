import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {isolatedContext,ingestSyntheticEmail} from './isolated-context.mjs';

const {auth:authUrl,api:apiUrl,mail:mailUrl}=isolatedContext();
const suffix=`${Date.now()}-${crypto.randomUUID().slice(0,8)}`;
async function json(url,options={}){const response=await fetch(url,options);const body=await response.json().catch(()=>({}));return {response,body}}
async function account(label){const email=`scan-${label}-${suffix}@family-passport.test`,password=`Synthetic-${label}-${suffix}-Password!`;assert.equal((await json(`${authUrl}/signup`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email,password})})).response.status,200);let message;for(let i=0;i<24&&!message;i++){await new Promise(r=>setTimeout(r,250));message=(await json(`${mailUrl}/api/v1/messages`)).body.messages?.find(x=>x.To?.some?.(to=>to.Address===email))}assert.ok(message);const detail=await json(`${mailUrl}/api/v1/message/${message.ID}`),link=[detail.body.Text,detail.body.HTML].join('\n').match(/https?:\/\/[^\s"'<>]+\/verify\?[^\s"'<>]+/i)?.[0]?.replaceAll('&amp;','&');assert.ok(link);await fetch(link,{redirect:'manual'});const signin=await json(`${authUrl}/token?grant_type=password`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email,password})});assert.equal(signin.response.status,200);return {email,token:signin.body.access_token}}
async function rpc(user,name,payload={}){return json(`${apiUrl}/rpc/${name}`,{method:'POST',headers:{authorization:`Bearer ${user.token}`,'content-type':'application/json'},body:JSON.stringify(payload)})}
const root=fileURLToPath(new URL('..',import.meta.url)),owner=await account('owner'),viewer=await account('viewer');
const created=await rpc(owner,'bootstrap_household',{household_name:'Synthetic scanner household',display_name:'Scanner owner'});assert.equal(created.response.status,200);const address=created.body.inbox.address;
await rpc(owner,'invite_member',{invitee_email:viewer.email,member_role:'viewer'});assert.equal((await rpc(viewer,'accept_my_invitation')).response.status,200);
assert.equal((await rpc(owner,'set_inbound_sender_rule',{sender:'synthetic-sender@family-passport.test',rule_action:'allow'})).response.status,200);
for(const [name,subject] of [['synthetic-bill.pdf',`Clean ${suffix}`],['synthetic-eicar.pdf',`EICAR ${suffix}`],['synthetic-malformed.pdf',`Malformed ${suffix}`]]) await ingestSyntheticEmail(address,subject,`${root}\\tests\\fixtures\\${name}`);
const scanned=spawnSync(process.execPath,[`${root}\\email-ingestion\\attachment-scanner.mjs`],{encoding:'utf8',cwd:root});assert.equal(scanned.status,0,scanned.stderr||scanned.stdout);
const summaries=await rpc(owner,'inbound_attachment_summaries');assert.equal(summaries.response.status,200,JSON.stringify(summaries.body));const bySubject=Object.fromEntries(summaries.body.filter(x=>x.email_subject?.endsWith(suffix)).map(x=>[x.email_subject.split(' ')[0],x]));
assert.equal(bySubject.Clean.scan_status,'clean');assert.equal(bySubject.Clean.safe_result_code,'clean');
assert.equal(bySubject.EICAR.scan_status,'rejected');assert.equal(bySubject.EICAR.safe_result_code,'malware_detected');
assert.equal(bySubject.Malformed.scan_status,'malformed');assert.equal(bySubject.Malformed.safe_result_code,'invalid_pdf_structure');
assert.equal((await rpc(viewer,'inbound_attachment_summaries')).response.status,403);
console.log(JSON.stringify({fresh_scanner:'PASS',clean_pdf_persisted:'PASS',eicar_rejected:'PASS',malformed_pdf_rejected:'PASS',viewer_denied:'PASS'}));
