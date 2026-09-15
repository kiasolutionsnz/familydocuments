import {createHash,createHmac} from 'node:crypto';
import {mkdir,readFile,unlink,writeFile} from 'node:fs/promises';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {checksum,detectSupportedFile,processTransportCycle,TELEGRAM_MAX_FILE_BYTES} from './worker-core.mjs';

async function localEnv(name){try{return await readFile(new URL(`../${name}`,import.meta.url),'utf8')}catch{return ''}}
const env=await localEnv('.env.local');
const telegramEnv=await localEnv('.telegram.local');
function value(source,key){return source.split(/\r?\n/).find(line=>line.startsWith(`${key}=`))?.slice(key.length+1).trim()||''}
function configured(key,fallback=''){return process.env[key]||value(telegramEnv,key)||value(env,key)||fallback}
const api=configured('FP_API_URL','http://127.0.0.1:55322').replace(/\/$/,'');
const gateway=configured('FP_GATEWAY_URL','http://127.0.0.1:55327').replace(/\/$/,'');
const botAPI=configured('TELEGRAM_API_BASE_URL','https://api.telegram.org').replace(/\/$/,'');
const botIdentity=configured('TELEGRAM_BOT_IDENTITY'),token=configured('TELEGRAM_BOT_TOKEN');
const jwtIssuer=configured('JWT_EXPECTED_ISSUER','familydocuments');
const stagingDir=configured('TELEGRAM_STAGING_DIR',join(process.cwd(),'.telegram-staging'));
const b64url=value=>Buffer.from(value).toString('base64url');
function signedJwt(secret,role='service_role',subject,familyID){const now=Math.floor(Date.now()/1000),header=b64url(JSON.stringify({alg:'HS256',typ:'JWT'})),claims={role,aud:'authenticated',iss:jwtIssuer,iat:now,nbf:now-5,exp:now+300};if(subject)claims.sub=subject;if(familyID)claims.family_id=familyID;const payload=b64url(JSON.stringify(claims)),unsigned=`${header}.${payload}`;return `${unsigned}.${createHmac('sha256',secret).update(unsigned).digest('base64url')}`}
async function secret(){const value=configured('GOTRUE_JWT_SECRET');if(!value)throw new Error('GOTRUE_JWT_SECRET is required');return value}
async function post(url,body,bearer='',timeout=15000){const headers={'content-type':'application/json'};if(bearer)headers.authorization=`Bearer ${bearer}`;const response=await fetch(url,{method:'POST',headers,body:JSON.stringify(body),signal:AbortSignal.timeout(timeout)}),parsed=await response.json().catch(()=>({}));if(!response.ok){const error=new Error(parsed.error||'service request failed');error.status=response.status;throw error}return parsed}
const rpc=(name,body,bearer)=>post(`${api}/rpc/${name}`,body,bearer);
const gatewayPost=(path,body,bearer,timeout)=>post(`${gateway}${path}`,body,bearer,timeout);
function parts(update){const e=update.envelope||{},message=e.message,callback=e.callback_query;if(message)return{message,user:String(message.from?.id||''),chat:String(message.chat?.id||''),text:String(message.text||message.caption||'').trim()};return{callback,user:String(callback?.from?.id||''),chat:String(callback?.message?.chat?.id||''),text:''}}
function reply(updateID,text,buttons,suffix='reply'){const result={request_key:`telegram:${updateID}:${suffix}`,text:String(text).slice(0,2000)};if(buttons?.length)result.buttons=buttons.slice(0,8);return result}
const outcomeMessage=(outcome,fallback='I need a little more information.')=>String(outcome?.result?.message||outcome?.message||fallback).slice(0,2000);
const extension=mime=>mime==='application/pdf'?'pdf':mime==='image/png'?'png':'jpg';
async function safeUnlink(path){try{await unlink(path)}catch(error){if(error.code!=='ENOENT')throw error}}

async function downloadAttachment(record){
  if(!record)return null;
  if(Number(record.declared_size||0)>TELEGRAM_MAX_FILE_BYTES)throw Object.assign(new Error('file too large'),{attachmentID:record.id,terminal:true,category:'too_large'});
  const metadata=await post(`${botAPI}/bot${token}/getFile`,{file_id:record.file_id},'',10000),filePath=String(metadata.result?.file_path||'');
  if(!filePath||filePath.includes('..'))throw Object.assign(new Error('download failed'),{attachmentID:record.id,category:'download_failed'});
  const remote=await fetch(`${botAPI}/file/bot${token}/${filePath}`,{signal:AbortSignal.timeout(20000)}),length=Number(remote.headers.get('content-length')||0);
  if(!remote.ok)throw Object.assign(new Error('download failed'),{attachmentID:record.id,category:'download_failed'});
  if(length>TELEGRAM_MAX_FILE_BYTES)throw Object.assign(new Error('file too large'),{attachmentID:record.id,terminal:true,category:'too_large'});
  const bytes=Buffer.from(await remote.arrayBuffer());
  if(!bytes.length||(length&&bytes.length!==length))throw Object.assign(new Error('truncated download'),{attachmentID:record.id,category:'truncated'});
  const mime=detectSupportedFile(bytes);
  if(!mime)throw Object.assign(new Error('unsupported attachment'),{attachmentID:record.id,terminal:true,category:'unsupported_type'});
  if(record.declared_mime_type&&record.declared_mime_type!==mime)throw Object.assign(new Error('mime mismatch'),{attachmentID:record.id,terminal:true,category:'mime_mismatch'});
  const key=`${record.id}.${extension(mime)}`;await mkdir(stagingDir,{recursive:true});await writeFile(join(stagingDir,key),bytes,{flag:'wx'}).catch(error=>{if(error.code!=='EEXIST')throw error});
  return{record,bytes,mime,key,sha256:checksum(bytes),name:String(record.file_name||`telegram.${extension(mime)}`).slice(0,255)};
}
async function ensureConversation(context,updateID,userToken,serviceToken,user,chat){if(context.conversation_id)return context.conversation_id;const created=await rpc('start_conversation',{request_id:`telegram-new-${updateID}`},userToken);await rpc('bind_telegram_conversation',{bot_identity:botIdentity,telegram_user:user,telegram_chat:chat,conversation:created.id},serviceToken);return created.id}
async function workspaceState(conversationID,userToken,identityLink,serviceToken){const workspace=await rpc('conversation_workspace',{conversation:conversationID},userToken),messages=workspace.messages||[],clarification=identityLink?await rpc('telegram_pending_clarification',{identity_link:identityLink},serviceToken):null,references=[];for(let i=messages.length-1;i>=0&&references.length<8;i--){const data=messages[i].data||{},derived=[['document',data.document_id,data.title||messages[i].content],['reminder',data.reminder_id,data.title||messages[i].content],['link',data.link_id,data.title||messages[i].content],['inbox',data.inbox_id,data.subject||messages[i].content]];for(const reference of [...(data.references||[]),...derived.filter(item=>item[1]).map(item=>({type:item[0],id:item[1],label:String(item[2]||item[0]).slice(0,120)}))]){if(reference?.id&&!references.some(item=>item.id===reference.id))references.push(reference)}}return{clarification,references}}
async function clarificationButtons(context,conversationID,userToken,serviceToken,state){const message=state?.clarification||(await workspaceState(conversationID,userToken,context.identity_link_id,serviceToken)).clarification;if(!message)return[];const missing=message.data?.action?.parameters?.missing_parameter;
  if(missing==='link_action'){const save=await rpc('create_telegram_callback',{identity_link:context.identity_link_id,conversation:conversationID,callback_kind:'clarification',reference:message.data.clarification_id,value:'transport:save_link'},serviceToken),cancel=await rpc('create_telegram_callback',{identity_link:context.identity_link_id,conversation:conversationID,callback_kind:'clarification',reference:message.data.clarification_id,value:'transport:cancel'},serviceToken);return[{label:'Save link',nonce:save.nonce},{label:'Cancel',nonce:cancel.nonce}]}
  let actions=message.data?.choice_actions||[],choices=message.data?.choices||[];if(missing==='category_name'){const prepared=await rpc('prepare_telegram_category_clarification',{identity_link:context.identity_link_id,clarification:message.data.clarification_id},serviceToken);actions=prepared.choice_actions||[];choices=prepared.choices||[]}
  const buttons=[];for(let j=0;j<actions.length&&j<6;j++){const callback=await rpc('create_telegram_callback',{identity_link:context.identity_link_id,conversation:conversationID,callback_kind:'clarification',reference:message.data.clarification_id,value:String(actions[j].id)},serviceToken);buttons.push({label:String(choices[j]||`Option ${j+1}`).slice(0,80),nonce:callback.nonce})}return buttons}
export function matchingChoice(clarification,text){if(!clarification)return null;const wanted=text.trim().toLowerCase(),choices=clarification.data?.choices||[],actions=clarification.data?.choice_actions||[];const index=choices.findIndex(choice=>{const label=String(choice).trim().toLowerCase();return label===wanted||(wanted==='rentals'&&label==='rental records')});return index>=0?actions[index]:null}

async function createAdapter(){
  if(!botIdentity||!token)throw new Error('Telegram worker configuration is incomplete');const jwtSecret=await secret(),serviceToken=signedJwt(jwtSecret);
  async function presentOutcome(updateID,result,context,conversationID,userToken,fallback){
    const confirmationID=result.confirmation_id||result.confirmation?.id;
    if(result.state==='awaiting_confirmation'&&confirmationID){const yes=await rpc('create_telegram_callback',{identity_link:context.identity_link_id,conversation:conversationID,callback_kind:'confirmation',reference:confirmationID,value:'confirm'},serviceToken),no=await rpc('create_telegram_callback',{identity_link:context.identity_link_id,conversation:conversationID,callback_kind:'confirmation',reference:confirmationID,value:'cancel'},serviceToken);return reply(updateID,outcomeMessage(result,'Please confirm this change.'),[{label:'Confirm',nonce:yes.nonce},{label:'Cancel',nonce:no.nonce}])}
    if(result.state==='awaiting_clarification'){const buttons=await clarificationButtons(context,conversationID,userToken,serviceToken,null);return reply(updateID,outcomeMessage(result),buttons)}
    return reply(updateID,outcomeMessage(result,fallback||'Your request was updated.'));
  }
  async function beginLinkSave(updateID,clarification,context,conversationID,userToken){const parameters=clarification?.data?.action?.parameters||{};if(!parameters.link_url)throw new Error('clarification unavailable');await gatewayPost('/conversation/clarification',{clarification_id:clarification.data.clarification_id,decision:'supersede'},userToken);const action={id:`telegram-link-clarify-${updateID}`,type:'request_clarification',version:1,parameters:{question:'Which category should I use for this link?',missing_parameter:'category_name',link_url:parameters.link_url,link_title:parameters.link_title||parameters.link_url}};const result=await gatewayPost('/conversation/action',{conversation_id:conversationID,request_key:`telegram-link-clarify-${updateID}`,action},userToken);return presentOutcome(updateID,result,context,conversationID,userToken,'Which category should I use for this link?')}
  async function clearCallbackButtons(callback){
    await post(`${botAPI}/bot${token}/editMessageReplyMarkup`,{chat_id:callback.message.chat.id,message_id:callback.message.message_id,reply_markup:{inline_keyboard:[]}},'',5000).catch(()=>{});
  }
  async function resolveAttachmentReview(context,clarification,result){
    const attachmentID=clarification?.data?.action?.parameters?.attachment_id;
    if(result?.state==='succeeded'&&attachmentID)await rpc('resolve_telegram_review',{identity_link:context.identity_link_id,conversation_attachment:attachmentID},serviceToken);
  }
  return{
    beforeCycle:()=>rpc('enqueue_telegram_job_updates',{bot_identity:botIdentity},serviceToken),
    claimUpdates:size=>rpc('claim_telegram_updates',{bot_identity:botIdentity,batch_size:size},serviceToken),
    completeUpdate:(id,lease,outcome,responses)=>rpc('complete_telegram_update',{update_record:id,worker_lease:lease,outcome,responses},serviceToken),
    failUpdate:async(id,lease,retryable,outcome,error,update)=>{if(error?.stagingPath)await safeUnlink(error.stagingPath).catch(()=>{});if(error?.attachmentID)await rpc('fail_telegram_attachment',{attachment:error.attachmentID,worker_lease:lease,category:error.category||'download_failed',terminal:Boolean(error.terminal)||!retryable||Number(update?.attempt||0)>=6},serviceToken).catch(()=>{});return rpc('fail_telegram_update',{update_record:id,worker_lease:lease,retryable,outcome},serviceToken)},
    claimOutbox:size=>rpc('claim_telegram_outbox',{bot_identity:botIdentity,batch_size:size},serviceToken),
    completeOutbox:(id,lease,message)=>rpc('complete_telegram_outbox',{outbox_record:id,worker_lease:lease,provider_message:message},serviceToken),
    failOutbox:(id,lease,retryable)=>rpc('fail_telegram_outbox',{outbox_record:id,worker_lease:lease,retryable},serviceToken),
    async send(item){const sent=await post(`${botAPI}/bot${token}/sendMessage`,{chat_id:item.chat_id,text:item.presentation?.text||'FamilyDocuments updated.',reply_markup:item.presentation?.buttons?{inline_keyboard:item.presentation.buttons.map(button=>[{text:button.label,callback_data:button.nonce}])}:undefined},'',10000);return sent.result?.message_id||'sent'},
    async handleUpdate(update){
      const p=parts(update);
      if(p.callback){
        await post(`${botAPI}/bot${token}/answerCallbackQuery`,{callback_query_id:p.callback.id},'',5000).catch(()=>{});
        let control;try{control=await rpc('apply_telegram_control_callback',{bot_identity:botIdentity,telegram_user:p.user,telegram_chat:p.chat,nonce:String(p.callback.data||'')},serviceToken)}catch(error){if([403,410].includes(error.status))return{outcome:'handled',responses:[reply(update.update_id,'That choice is no longer available.')]};if(error.status!==400)throw error}
        if(control?.type)await clearCallbackButtons(p.callback);
        if(control?.type==='family'){const userToken=signedJwt(jwtSecret,'authenticated',control.user_id,control.family_id),context=await rpc('telegram_transport_context',{bot_identity:botIdentity,telegram_user:p.user,telegram_chat:p.chat},serviceToken);await ensureConversation(context,update.update_id,userToken,serviceToken,p.user,p.chat);return{outcome:'handled',responses:[reply(update.update_id,`Active Family: ${control.family_name}.`)]}}
        if(control?.type==='disconnect')return{outcome:'handled',responses:[reply(update.update_id,'Telegram has been disconnected. Reconnect from FamilyDocuments Settings when needed.')]};
        if(control?.type==='cancel')return{outcome:'handled',responses:[reply(update.update_id,'Okay, cancelled.')]};
        let bound;try{bound=await rpc('consume_telegram_callback',{bot_identity:botIdentity,telegram_user:p.user,telegram_chat:p.chat,nonce:String(p.callback.data||'')},serviceToken)}catch(error){if([400,403,410].includes(error.status))return{outcome:'handled',responses:[reply(update.update_id,'That choice is no longer available.')]};throw error}const userToken=signedJwt(jwtSecret,'authenticated',bound.user_id,bound.family_id),confirmation=bound.type==='confirmation';
        await clearCallbackButtons(p.callback);
        if(bound.type==='clarification'&&bound.value==='transport:cancel'){const result=await gatewayPost('/conversation/clarification',{clarification_id:bound.reference_id,decision:'cancel'},userToken);return{outcome:'handled',responses:[reply(update.update_id,outcomeMessage(result,'Okay, cancelled.'))]}}
        if(bound.type==='clarification'&&bound.value==='transport:save_link'){const state=await workspaceState(bound.conversation_id,userToken,bound.identity_link_id,serviceToken);return{outcome:'handled',responses:[await beginLinkSave(update.update_id,state.clarification,{identity_link_id:bound.identity_link_id},bound.conversation_id,userToken)]}}
        const callbackState=confirmation?null:await workspaceState(bound.conversation_id,userToken,bound.identity_link_id,serviceToken),result=await gatewayPost(confirmation?'/conversation/decision':'/conversation/clarification',confirmation?{confirmation_id:bound.reference_id,decision:bound.value||'confirm'}:{clarification_id:bound.reference_id,decision:'select',option_id:bound.value},userToken);
        await resolveAttachmentReview({identity_link_id:bound.identity_link_id},callbackState?.clarification,result);
        return{outcome:'handled',responses:[await presentOutcome(update.update_id,result,{identity_link_id:bound.identity_link_id},bound.conversation_id,userToken,'Your choice was applied.')]};
      }
      if(/^\/start\s+/.test(p.text)){const raw=p.text.replace(/^\/start\s+/,'').trim();if(!/^[A-Za-z0-9_-]{40,60}$/.test(raw))return{outcome:'unlinked',responses:[reply(update.update_id,'That connection link is invalid or expired. Create a new one in FamilyDocuments Settings.')]};await rpc('consume_telegram_link_token',{bot_identity:botIdentity,link_hash:createHash('sha256').update(raw).digest('hex'),telegram_user:p.user,telegram_chat:p.chat,metadata:{display_name:[p.message.from?.first_name,p.message.from?.last_name].filter(Boolean).join(' ').slice(0,120),username:String(p.message.from?.username||'').slice(0,80)}},serviceToken);return{outcome:'handled',responses:[reply(update.update_id,'Telegram is connected to FamilyDocuments. Send /help to see what I can do.')]}}
      const context=await rpc('telegram_transport_context',{bot_identity:botIdentity,telegram_user:p.user,telegram_chat:p.chat},serviceToken);if(!context.linked)return{outcome:'unlinked',responses:[reply(update.update_id,'Sign in to FamilyDocuments and connect Telegram from Settings first.')]};
      const userToken=signedJwt(jwtSecret,'authenticated',context.user_id,context.family_id),conversationID=await ensureConversation(context,update.update_id,userToken,serviceToken,p.user,p.chat);
      if(p.text==='/help'||p.text==='/start')return{outcome:'handled',responses:[reply(update.update_id,'I can find saved information, save links and documents, read a document when asked, and help with reminders.')]};
      if(p.text==='/status')return{outcome:'handled',responses:[reply(update.update_id,`Active Family: ${context.family_name}.`)]};
      if(p.text==='/cancel'){const result=await rpc('telegram_cancel_pending',{bot_identity:botIdentity,telegram_user:p.user,telegram_chat:p.chat},serviceToken);return{outcome:'handled',responses:[reply(update.update_id,result.cancelled?'Okay, cancelled.':'There is nothing waiting to cancel.')]}}
      if(p.text==='/family'){const result=await rpc('telegram_family_choices',{bot_identity:botIdentity,telegram_user:p.user,telegram_chat:p.chat},serviceToken);return{outcome:'handled',responses:[reply(update.update_id,result.only_one?`Your only active Family is ${result.current_family}.`:`Current Family: ${result.current_family}. Choose another Family below.`,result.only_one?[]:result.choices,'family')]}}
      if(p.text==='/disconnect'){const yes=await rpc('create_telegram_callback',{identity_link:context.identity_link_id,conversation:conversationID,callback_kind:'disconnect',reference:null,value:'confirm'},serviceToken),no=await rpc('create_telegram_callback',{identity_link:context.identity_link_id,conversation:conversationID,callback_kind:'cancel',reference:null,value:'cancel'},serviceToken);return{outcome:'handled',responses:[reply(update.update_id,'Disconnect Telegram from FamilyDocuments?',[{label:'Disconnect',nonce:yes.nonce},{label:'Cancel',nonce:no.nonce}])]}}
      if(p.text==='/new'){const created=await rpc('start_conversation',{request_id:`telegram-new-${update.update_id}`},userToken);await rpc('bind_telegram_conversation',{bot_identity:botIdentity,telegram_user:p.user,telegram_chat:p.chat,conversation:created.id},serviceToken);return{outcome:'handled',responses:[reply(update.update_id,'Started a new FamilyDocuments conversation.')]}}
      const attachmentRecord=await rpc('claim_telegram_attachment',{update_record:update.id,worker_lease:update.lease_token},serviceToken);let attachment,attachmentID;
      if(attachmentRecord){try{attachment=await downloadAttachment(attachmentRecord);await rpc('stage_telegram_attachment',{attachment:attachment.record.id,worker_lease:update.lease_token,verified_type:attachment.mime,byte_size:attachment.bytes.length,file_checksum:attachment.sha256,stage_key:attachment.key},serviceToken);const staged=await gatewayPost('/conversation/attachment',{conversation_id:conversationID,file_name:attachment.name,mime_type:attachment.mime,content_base64:attachment.bytes.toString('base64')},userToken,30000);attachmentID=staged.id||staged.attachment_id;await safeUnlink(join(stagingDir,attachment.key));await rpc('finish_telegram_attachment',{attachment:attachment.record.id,worker_lease:update.lease_token,staged_attachment:attachmentID},serviceToken)}catch(error){error.attachmentID=attachmentRecord.id;if(attachment?.key)error.stagingPath=join(stagingDir,attachment.key);throw error}}
      const text=p.text||(attachment?'Save this document':'');if(!text)return{outcome:'unsupported',responses:[reply(update.update_id,'I can help organise and find information in your FamilyDocuments account.')]};
      const state=await workspaceState(conversationID,userToken,context.identity_link_id,serviceToken),choice=matchingChoice(state.clarification,text);
      const pendingMissing=state.clarification?.data?.action?.parameters?.missing_parameter;
      if(pendingMissing==='link_action'&&/^save(?: this)? link[.!]?$/i.test(text))return{outcome:'handled',responses:[await beginLinkSave(update.update_id,state.clarification,context,conversationID,userToken)]};
      if(choice){const selected=await gatewayPost('/conversation/clarification',{clarification_id:state.clarification.data.clarification_id,decision:'select',option_id:choice.id},userToken);await resolveAttachmentReview(context,state.clarification,selected);return{outcome:'handled',responses:[await presentOutcome(update.update_id,selected,context,conversationID,userToken,'Your choice was applied.')]}}
      if(state.clarification)await gatewayPost('/conversation/clarification',{clarification_id:state.clarification.data.clarification_id,decision:'supersede'},userToken).catch(()=>{});
      await rpc('append_conversation_message',{conversation:conversationID,client_message_id:`telegram-user-${update.update_id}`,message_role:'user',message_kind:attachment?'attachment':'text',message_content:text,message_data:attachmentID?{references:[],attachment_id:attachmentID,file_name:attachment.name}:{}},userToken);
      const interpreted=await gatewayPost('/conversation/interpret',{message:text,context:{has_attachment:Boolean(attachmentID),attachment_id:attachmentID||'',references:state.references}},userToken),result=await gatewayPost('/conversation/action',{conversation_id:conversationID,request_key:`telegram-action-${update.update_id}`,action:interpreted.action,proposal_token:interpreted.proposal_token},userToken);
      if(result.state==='awaiting_clarification'&&attachmentRecord)await rpc('create_telegram_review',{update_record:update.id,attachment:attachmentRecord.id,reason_value:'attachment_needs_decision'},serviceToken);
      return{outcome:'handled',responses:[await presentOutcome(update.update_id,result,context,conversationID,userToken,result.state==='succeeded'?'Done.':'I need a little more information.')]};
    }
  }
}
export async function runCycle(){return processTransportCycle(await createAdapter())}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){if(process.argv.includes('--watch')){console.log(JSON.stringify({status:'watching',transport:'telegram',poll_seconds:4}));while(true){try{const result=await runCycle();if(result.updates||result.outbound)console.log(JSON.stringify(result))}catch{console.error(JSON.stringify({status:'cycle_failed',transport:'telegram'}))}await new Promise(resolve=>setTimeout(resolve,4000))}}else console.log(JSON.stringify(await runCycle()))}
