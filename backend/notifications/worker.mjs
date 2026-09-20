import {createHmac} from "node:crypto";
import {readFile} from "node:fs/promises";
import nodemailer from "nodemailer";
import {GoogleAuth} from "google-auth-library";
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
function firebaseConfig(env){const projectId=value(env,"FIREBASE_PROJECT_ID"),encoded=value(env,"FIREBASE_SERVICE_ACCOUNT_BASE64");if(!projectId||!encoded)return null;let credentials;try{credentials=JSON.parse(Buffer.from(encoded,"base64").toString("utf8"))}catch{throw new Error("FIREBASE_SERVICE_ACCOUNT_BASE64 is invalid")};if(credentials.project_id!==projectId)throw new Error("Firebase project does not match the service account");return {projectId,auth:new GoogleAuth({credentials,scopes:["https://www.googleapis.com/auth/firebase.messaging"]})}}
async function sendPush(config,item){const client=await config.auth.getClient(),token=await client.getAccessToken();if(!token.token)throw new Error("Firebase access token unavailable");const response=await fetch(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(config.projectId)}/messages:send`,{method:"POST",headers:{authorization:`Bearer ${token.token}`,"content-type":"application/json"},body:JSON.stringify({message:{token:item.token,notification:{title:item.title,body:item.body_text},data:{route:item.route,notification_id:item.id},android:{priority:"high",notification:{sound:"default"}},apns:{payload:{aps:{sound:"default"}}}}}),signal:AbortSignal.timeout(20000)});const body=await response.json().catch(()=>({}));if(!response.ok){const code=body?.error?.details?.find?.(x=>x.errorCode)?.errorCode||body?.error?.status||"fcm_delivery_failed";throw Object.assign(new Error("Firebase delivery failed"),{safeCode:String(code).toLowerCase().slice(0,80),disableDevice:["unregistered","invalid_argument"].includes(String(code).toLowerCase())})}return String(body.name||item.id)}
async function cycle(){
  const env=await localEnv(),secret=value(env,"GOTRUE_JWT_SECRET"),fromAddress=value(env,"SMTP_FROM_EMAIL"),fromName=value(env,"SMTP_FROM_NAME")||"Family Documents";
  if(!secret)throw new Error("GOTRUE_JWT_SECRET is required");
  const token=serviceJwt(secret),firebase=firebaseConfig(env);
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
      let pushClaimed=0,pushSent=0,pushFailed=0;
      if(firebase){
        await rpc("enqueue_due_push_notifications",{},token);
        const pushes=await rpc("claim_push_notification_batch",{batch_size:20},token);pushClaimed=pushes.length;
        for(const item of pushes){try{const providerId=await sendPush(firebase,item);await rpc("complete_push_notification",{notification:item.id,sent:true,provider_id:providerId,error_code:null,disable_device:false},token);pushSent++}catch(error){await rpc("complete_push_notification",{notification:item.id,sent:false,provider_id:null,error_code:error.safeCode||"fcm_delivery_failed",disable_device:error.disableDevice===true},token);pushFailed++}}
      }
      return {claimed:batch.length,sent,failed,push_claimed:pushClaimed,push_sent:pushSent,push_failed:pushFailed};
    }finally{transport.close()}
  }});
}
async function main(){if(process.argv.includes("--watch")){console.log(JSON.stringify({status:"watching",interval_seconds:intervalMs/1000}));while(true){try{console.log(JSON.stringify(await cycle()))}catch(error){console.error(JSON.stringify({status:"cycle_failed",message:error.message}))}await new Promise(resolve=>setTimeout(resolve,intervalMs))}}else console.log(JSON.stringify(await cycle()))}
await main();
