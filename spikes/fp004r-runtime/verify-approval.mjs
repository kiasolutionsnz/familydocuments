import { createHash, createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';

const canonical = value => {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  return '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + canonical(value[k])).join(',') + '}';
};
const fields = ['run_id','gate','component','tag','digest','configuration_profile_sha256','evidence','decision','reviewed_at','residual_risk'];
const payload = approval => Object.fromEntries(fields.map(k => [k, approval[k]]));
const fingerprint = pem => createHash('sha256').update(createPublicKey(pem).export({type:'spki',format:'der'})).digest('hex').toUpperCase();

export function verifyApproval(approval, registry) {
  const errors=[];
  if (Object.keys(payload(approval)).some(k => approval[k] === undefined)) errors.push('missing_signed_field');
  if (approval.canonicalization !== 'JCS-RFC8785-subset:utf8:sorted-object-keys:array-order-preserved') errors.push('noncanonical_contract');
  const entry=(registry.keys||[]).find(k=>k.key_id===approval.signature?.key_id);
  if (!entry) errors.push('unknown_key');
  else {
    if (entry.status !== 'active') errors.push('revoked_key');
    if (entry.reviewer_identity === approval.producer_identity) errors.push('producer_reviewer_not_separated');
    if (entry.reviewer_identity !== approval.reviewer_identity) errors.push('reviewer_identity_mismatch');
    if (fingerprint(entry.public_key_pem) !== entry.fingerprint_sha256 || entry.fingerprint_sha256 !== approval.signature.fingerprint_sha256) errors.push('fingerprint_mismatch');
    try { if (!verify(null,Buffer.from(canonical(payload(approval)),'utf8'),entry.public_key_pem,Buffer.from(approval.signature.value_base64,'base64'))) errors.push('signature_mismatch'); } catch { errors.push('signature_malformed'); }
  }
  return {ok:errors.length===0,errors,payload_sha256:createHash('sha256').update(canonical(payload(approval))).digest('hex').toUpperCase()};
}

if (process.argv[2] === '--self-test') {
  const {publicKey,privateKey}=generateKeyPairSync('ed25519'); const pem=publicKey.export({type:'spki',format:'pem'}); const fp=fingerprint(pem);
  const base={run_id:'family-passport-2026-08-17',gate:'FP-004R',component:'fixture',tag:'fixture:1',digest:'sha256:'+('a'.repeat(64)),configuration_profile_sha256:'B'.repeat(64),evidence:[{role:'provenance_licence',path:'p',sha256:'C'.repeat(64)}],decision:'PASS',reviewed_at:'2026-08-19T00:00:00Z',residual_risk:[],canonicalization:'JCS-RFC8785-subset:utf8:sorted-object-keys:array-order-preserved',reviewer_identity:'reviewer-1',producer_identity:'producer-1',signature:{key_id:'reviewer-key-1',fingerprint_sha256:fp,value_base64:''}};
  base.signature.value_base64=sign(null,Buffer.from(canonical(payload(base)),'utf8'),privateKey).toString('base64'); const reg={keys:[{key_id:'reviewer-key-1',reviewer_identity:'reviewer-1',status:'active',fingerprint_sha256:fp,public_key_pem:pem}]};
  const cases=[]; const test=(name,a,r,expect)=>{const result=verifyApproval(a,r);cases.push({case:name,status:result.errors.includes(expect)?'PASS_REJECTED':'FAIL_ACCEPTED',errors:result.errors});};
  for(const [name,mutate,expect] of [
    ['bit_flip',a=>a.signature.value_base64=Buffer.from(Buffer.from(a.signature.value_base64,'base64').map((v,i)=>i? v:v^1)).toString('base64'),'signature_mismatch'],
    ['payload_tamper',a=>a.digest='sha256:'+('d'.repeat(64)),'signature_mismatch'],['unknown_key',a=>a.signature.key_id='unknown','unknown_key'],['wrong_fingerprint',a=>a.signature.fingerprint_sha256='0'.repeat(64),'fingerprint_mismatch'],['revoked_key',(a,r)=>r.keys[0].status='revoked','revoked_key'],['noncanonical',a=>a.canonicalization='JSON.stringify','noncanonical_contract'],['missing_evidence',a=>delete a.evidence,'missing_signed_field'],['cross_run',a=>a.run_id='other','signature_mismatch'],['cross_component',a=>a.component='other','signature_mismatch'],['producer_key',a=>a.producer_identity='reviewer-1','producer_reviewer_not_separated']]) { const a=structuredClone(base),r=structuredClone(reg); mutate(a,r); test(name,a,r,expect); }
  process.stdout.write(JSON.stringify(cases,null,2)); process.exit(cases.some(x=>x.status==='FAIL_ACCEPTED')?1:0);
}
if (process.argv.length===5) { const approval=JSON.parse(readFileSync(process.argv[2])); const registry=JSON.parse(readFileSync(process.argv[3])); const expected=process.argv[4]; const registryHash=createHash('sha256').update(readFileSync(process.argv[3])).digest('hex').toUpperCase(); if(registryHash!==expected){console.log(JSON.stringify({ok:false,errors:['registry_hash_mismatch']}));process.exit(1)} const result=verifyApproval(approval,registry);console.log(JSON.stringify(result));process.exit(result.ok?0:1); }
if (process.argv[2] !== '--self-test') process.exit(2);
