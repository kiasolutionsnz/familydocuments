import {createHmac,createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';

const mailUrl=process.env.FP_MAILPIT_URL||'http://127.0.0.1:55324';
const apiUrl=process.env.FP_API_URL||'http://127.0.0.1:55322';
const maxBytes=5*1024*1024;
const aliasPattern=/^(?:family-[0-9a-f]{24}|[a-z0-9][a-z0-9-]{2,39})@(family-passport[.]local|familydocuments[.]servicehub[.]co[.]nz)$/i;

function base64url(value){return Buffer.from(value).toString('base64url')}
function serviceJwt(secret){
  const now=Math.floor(Date.now()/1000),header=base64url(JSON.stringify({alg:'HS256',typ:'JWT'}));
  const payload=base64url(JSON.stringify({role:'service_role',iss:'supabase',iat:now,exp:now+300}));
  const unsigned=`${header}.${payload}`,signature=createHmac('sha256',secret).update(unsigned).digest('base64url');
  return `${unsigned}.${signature}`;
}
async function secret(){
  if(process.env.GOTRUE_JWT_SECRET)return process.env.GOTRUE_JWT_SECRET;
  const env=await readFile(new URL('../.env.local',import.meta.url),'utf8');
  const line=env.split(/\r?\n/).find(x=>x.startsWith('GOTRUE_JWT_SECRET='));
  if(!line)throw new Error('GOTRUE_JWT_SECRET is required');
  return line.slice(line.indexOf('=')+1).trim();
}
async function getJson(path){const response=await fetch(`${mailUrl}${path}`);if(!response.ok)throw new Error(`Mailpit ${path} returned ${response.status}`);return response.json()}
async function ingest(payload,token){
  const response=await fetch(`${apiUrl}/rpc/ingest_mailpit_message`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify(payload)});
  const body=await response.json().catch(()=>({}));if(!response.ok)throw new Error(body.message||`Ingestion API returned ${response.status}`);return body;
}
const jwtSecret=await secret(),seen=new Set();
async function runCycle(){
 const listing=await getJson('/api/v1/messages'),token=serviceJwt(jwtSecret);
 const result={accepted:0,duplicates:0,ignored:0,rejected:0};
 for(const item of listing.messages||[]){
  if(seen.has(item.ID))continue;
  const destinations=(item.To||[]).map(x=>String(x.Address||'').toLowerCase());
  const alias=destinations.find(x=>aliasPattern.test(x));
  if(!alias){result.ignored++;seen.add(item.ID);continue}
  if(Number(item.Size||0)>maxBytes||Number(item.Attachments||0)>20){result.rejected++;seen.add(item.ID);continue}
  const [detail,rawResponse]=await Promise.all([getJson(`/api/v1/message/${encodeURIComponent(item.ID)}`),fetch(`${mailUrl}/api/v1/message/${encodeURIComponent(item.ID)}/raw`)]);
  if(!rawResponse.ok)throw new Error(`Mailpit raw message returned ${rawResponse.status}`);
  const raw=Buffer.from(await rawResponse.arrayBuffer());
  if(raw.length>maxBytes){result.rejected++;seen.add(item.ID);continue}
  const manifest=(detail.Attachments||[]).map(x=>({part_id:String(x.PartID||'').slice(0,80),file_name:String(x.FileName||x.Name||'attachment').slice(0,255),content_type:String(x.ContentType||'application/octet-stream').slice(0,160),size_bytes:Number(x.Size||0),sha256:String(x.Checksums?.SHA256||'').toLowerCase()}));
  const outcome=await ingest({
    recipient_address:alias,mailpit_message_id:String(item.ID),internet_message_id:String(detail.MessageID||item.MessageID||''),
    sender_address:String(detail.From?.Address||item.From?.Address||'unknown@invalid.local'),recipient_addresses:destinations,
    message_subject:String(detail.Subject||''),message_sent_at:detail.Date||item.Created||null,raw_email:raw.toString('base64'),
    raw_sha256:createHash('sha256').update(raw).digest('hex'),body_text:String(detail.Text||''),attachment_manifest:manifest
  },token);
  if(outcome.accepted){if(outcome.duplicate)result.duplicates++;else result.accepted++}else result.rejected++;
  seen.add(item.ID);
 }
 return result;
}
if(process.argv.includes('--watch')){
  console.log(JSON.stringify({status:'watching',mailpit:mailUrl,poll_seconds:5}));
  while(true){
    try{const result=await runCycle();if(result.accepted||result.rejected)console.log(JSON.stringify(result))}catch(error){console.error(JSON.stringify({status:'cycle_failed',message:error.message}))}
    await new Promise(resolve=>setTimeout(resolve,5000));
  }
}else console.log(JSON.stringify(await runCycle()));
