import {createHmac} from "node:crypto";
import {readFile} from "node:fs/promises";
import nodemailer from "nodemailer";
import {renderNotificationHtml} from "./template.mjs";
import {withDraftRetention} from "./maintenance.mjs";

const apiUrl=process.env.FP_API_URL||"http://127.0.0.1:55322";
const intervalMs=Math.max(60,Number(process.env.FP_NOTIFICATION_INTERVAL_SECONDS||300))*1000;
function base64url(value){return Buffer.from(value).toString("base64url")}
function serviceJwt(secret){const now=Math.floor(Date.now()/1000),header=base64url(JSON.stringify({alg:"HS256",typ:"JWT"})),payload=base64url(JSON.stringify({role:"service_role",iss:"supabase",iat:now,exp:now+300})),unsigned=`${header}.${payload}`;return `${unsigned}.${createHmac("sha256",secret).update(unsigned).digest("base64url")}`}
async function localEnv(){try{return await readFile(new URL("../.env.local",import.meta.url),"utf8")}catch{return ""}}
function value(env,key){return process.env[key]||env.split(/\r?\n/).find(x=>x.startsWith(`${key}=`))?.slice(key.length+1).trim()||""}
async function rpc(name,payload,token,{timeoutMs}={}){const response=await fetch(`${apiUrl}/rpc/${name}`,{method:"POST",headers:{authorization:`Bearer ${token}`,"content-type":"application/json"},body:JSON.stringify(payload||{}),...(timeoutMs?{signal:AbortSignal.timeout(timeoutMs)}:{})});const body=await response.json().catch(()=>({}));if(!response.ok)throw new Error(body.message||`${name} failed (${response.status})`);return body}
function smtpTransport(env){const host=value(env,"SMTP_HOST"),port=Number(value(env,"SMTP_PORT")),user=value(env,"SMTP_USERNAME"),pass=value(env,"SMTP_PASSWORD");if(!host||!Number.isInteger(port)||!user||!pass)throw new Error("SMTP2GO configuration is required; delivery remains fail-closed");return nodemailer.createTransport({host,port,secure:port===465,requireTLS:port!==465,auth:{user,pass},tls:{minVersion:"TLSv1.2"},pool:true,maxConnections:2,maxMessages:100})}
async function cycle(){
  const env=await localEnv(),secret=value(env,"GOTRUE_JWT_SECRET"),fromAddress=value(env,"SMTP_FROM_EMAIL"),fromName=value(env,"SMTP_FROM_NAME")||"Family Documents";
  if(!secret)throw new Error("GOTRUE_JWT_SECRET is required");
  const token=serviceJwt(secret);
  return withDraftRetention({rpc,token,onRetentionError:event=>console.error(JSON.stringify(event)),deliver:async()=>{
    if(!fromAddress)throw new Error("SMTP_FROM_EMAIL is required; delivery remains fail-closed");
    const transport=smtpTransport(env);
    try{
      await transport.verify();await rpc("enqueue_due_notifications",{},token);
      const batch=await rpc("claim_notification_batch",{batch_size:20},token);let sent=0,failed=0;
      for(const item of batch){
        try{
          if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(item.recipient_email)||/\.(?:test|invalid|example)$/i.test(item.recipient_email))throw Object.assign(new Error("synthetic recipient blocked"),{safeCode:"synthetic_recipient_blocked"});
          const result=await transport.sendMail({from:{name:fromName,address:fromAddress},to:item.recipient_email,subject:item.subject,text:item.body_text,html:renderNotificationHtml(item),messageId:`<fp-${item.id}@familydocuments.app>`,headers:{"X-Family-Documents-Notification":item.id}});
          await rpc("complete_notification",{notification:item.id,sent:true,provider_id:String(result.messageId||item.id).slice(0,200),error_code:null},token);sent++;
        }catch(error){await rpc("complete_notification",{notification:item.id,sent:false,provider_id:null,error_code:error.safeCode||"smtp_delivery_failed"},token);failed++}
      }
      return {claimed:batch.length,sent,failed};
    }finally{transport.close()}
  }});
}
async function main(){if(process.argv.includes("--watch")){console.log(JSON.stringify({status:"watching",interval_seconds:intervalMs/1000}));while(true){try{console.log(JSON.stringify(await cycle()))}catch(error){console.error(JSON.stringify({status:"cycle_failed",message:error.message}))}await new Promise(resolve=>setTimeout(resolve,intervalMs))}}else console.log(JSON.stringify(await cycle()))}
await main();
