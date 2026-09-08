import {createHmac,createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {assertFresh,scanBuffer,scannerVersion} from './clamd-client.mjs';

const mailUrl=process.env.FP_MAILPIT_URL||'http://127.0.0.1:55324',apiUrl=process.env.FP_API_URL||'http://127.0.0.1:55322';
const clamHost=process.env.FP_CLAMD_HOST||'127.0.0.1',clamPort=Number(process.env.FP_CLAMD_PORT||55326),maxBytes=5*1024*1024;
function b64url(value){return Buffer.from(value).toString('base64url')}
function jwt(secret){const now=Math.floor(Date.now()/1000),h=b64url(JSON.stringify({alg:'HS256',typ:'JWT'})),p=b64url(JSON.stringify({role:'service_role',iss:'supabase',iat:now,exp:now+300})),u=`${h}.${p}`;return `${u}.${createHmac('sha256',secret).update(u).digest('base64url')}`}
async function secret(){if(process.env.GOTRUE_JWT_SECRET)return process.env.GOTRUE_JWT_SECRET;const env=await readFile(new URL('../.env.local',import.meta.url),'utf8'),line=env.split(/\r?\n/).find(x=>x.startsWith('GOTRUE_JWT_SECRET='));if(!line)throw new Error('GOTRUE_JWT_SECRET is required');return line.slice(line.indexOf('=')+1).trim()}
async function rpc(name,payload,token){const response=await fetch(`${apiUrl}/rpc/${name}`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify(payload)}),body=await response.json().catch(()=>({}));if(!response.ok)throw new Error(body.message||`${name} returned ${response.status}`);return body}
function looksLikePdf(bytes){return bytes.subarray(0,5).toString('ascii')==='%PDF-'&&bytes.subarray(Math.max(0,bytes.length-2048)).includes(Buffer.from('%%EOF'))}
const jwtSecret=await secret();
async function cycle(){
  const version=await scannerVersion(clamHost,clamPort);assertFresh(version);const [engine,signature]=version.split('/'),token=jwt(jwtSecret),pending=await rpc('pending_attachment_scans',{batch_size:10},token);let clean=0,rejected=0,malformed=0,errors=0;
  for(const item of pending){
    try{
      let bytes;
      if(item.source_system==='cloudflare_email_worker') bytes=Buffer.from(item.quarantined_content_base64||'','base64');
      else {const response=await fetch(`${mailUrl}/api/v1/message/${encodeURIComponent(item.external_message_id)}/part/${encodeURIComponent(item.part_id)}`);if(!response.ok)throw new Error(`attachment download returned ${response.status}`);bytes=Buffer.from(await response.arrayBuffer())}
      const hash=createHash('sha256').update(bytes).digest('hex');
      if(bytes.length<1||bytes.length>maxBytes||bytes.length!==item.expected_size_bytes||hash!==item.expected_sha256)throw new Error('attachment integrity mismatch');
      const scan=await scanBuffer(clamHost,clamPort,bytes);
      if(!scan.clean){await rpc('record_attachment_scan',{attachment_id:item.id,verdict:'rejected',content_base64:null,provided_sha256:null,scanner_engine:engine,scanner_signature:signature,result_code:'malware_detected'},token);rejected++;continue}
      if(!looksLikePdf(bytes)){await rpc('record_attachment_scan',{attachment_id:item.id,verdict:'malformed',content_base64:null,provided_sha256:null,scanner_engine:engine,scanner_signature:signature,result_code:'invalid_pdf_structure'},token);malformed++;continue}
      await rpc('record_attachment_scan',{attachment_id:item.id,verdict:'clean',content_base64:bytes.toString('base64'),provided_sha256:hash,scanner_engine:engine,scanner_signature:signature,result_code:'clean'},token);clean++;
    }catch(error){errors++;try{await rpc('record_attachment_scan',{attachment_id:item.id,verdict:'error',content_base64:null,provided_sha256:null,scanner_engine:engine,scanner_signature:signature,result_code:'scanner_processing_error'},token)}catch{}console.error(JSON.stringify({attachment_id:item.id,status:'error',message:error.message}))}
  }
  return {clean,rejected,malformed,errors};
}
if(process.argv.includes('--watch')){console.log(JSON.stringify({status:'watching',scanner:`${clamHost}:${clamPort}`,poll_seconds:5}));while(true){try{const result=await cycle();if(Object.values(result).some(Boolean))console.log(JSON.stringify(result))}catch(error){console.error(JSON.stringify({status:'cycle_failed',message:error.message}))}await new Promise(r=>setTimeout(r,5000))}}else console.log(JSON.stringify(await cycle()));
