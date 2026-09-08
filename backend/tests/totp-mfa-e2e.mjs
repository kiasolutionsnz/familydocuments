import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {isolatedContext} from './isolated-context.mjs';
const {auth,mail}=isolatedContext();
const suffix=`${Date.now()}-${crypto.randomUUID().slice(0,8)}`,email=`mfa-${suffix}@family-passport.test`,password=`Synthetic-MFA-${suffix}-Password!`;
async function json(url,options={}){const response=await fetch(url,options);const body=await response.json().catch(()=>({}));return {response,body}}
function base32(value){const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';let bits='';for(const c of value.replace(/=+$/,'').toUpperCase())bits+=alphabet.indexOf(c).toString(2).padStart(5,'0');return Buffer.from(bits.match(/.{8}/g)?.map(x=>parseInt(x,2))||[])}
function totp(secret){const counter=Math.floor(Date.now()/30000),buf=Buffer.alloc(8);buf.writeBigUInt64BE(BigInt(counter));const digest=createHmac('sha1',base32(secret)).update(buf).digest(),offset=digest[19]&15;return String((digest.readUInt32BE(offset)&0x7fffffff)%1000000).padStart(6,'0')}
const signup=await json(`${auth}/signup`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email,password})});assert.equal(signup.response.status,200,JSON.stringify(signup.body));
let message;for(let i=0;i<24&&!message;i++){await new Promise(r=>setTimeout(r,250));const list=await json(`${mail}/api/v1/messages`);message=list.body.messages?.find(x=>x.To?.some?.(to=>to.Address===email))}assert.ok(message);
const detail=await json(`${mail}/api/v1/message/${message.ID}`),content=[detail.body.Text,detail.body.HTML].filter(Boolean).join('\n'),link=content.match(/https?:\/\/[^\s"'<>]+\/verify\?[^\s"'<>]+/i)?.[0]?.replaceAll('&amp;','&');assert.ok(link);await fetch(link,{redirect:'manual'});
const signin=await json(`${auth}/token?grant_type=password`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email,password})});assert.equal(signin.response.status,200,JSON.stringify(signin.body));let token=signin.body.access_token;
const enroll=await json(`${auth}/factors`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify({factor_type:'totp',friendly_name:'Family Passport test'})});assert.equal(enroll.response.status,200,JSON.stringify(enroll.body));assert.ok(enroll.body.totp?.secret);
const challenge=await json(`${auth}/factors/${enroll.body.id}/challenge`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:'{}'});assert.equal(challenge.response.status,200,JSON.stringify(challenge.body));
const verify=await json(`${auth}/factors/${enroll.body.id}/verify`,{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify({challenge_id:challenge.body.id,code:totp(enroll.body.totp.secret)})});assert.equal(verify.response.status,200,JSON.stringify(verify.body));token=verify.body.access_token;
const claims=JSON.parse(Buffer.from(token.split('.')[1],'base64url'));assert.equal(claims.aal,'aal2');
const globalLogout=await fetch(`${auth}/logout?scope=global`,{method:'POST',headers:{authorization:`Bearer ${token}`}});assert.ok([200,204].includes(globalLogout.status));
console.log(JSON.stringify({totp_enrollment:'PASS',totp_verification:'PASS',aal2_token:'PASS',global_logout:'PASS'}));
