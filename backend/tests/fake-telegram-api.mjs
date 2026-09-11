import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';

const port=Number(process.env.FAKE_TELEGRAM_PORT||0);
const gateway=process.env.FP_GATEWAY_URL;
const secret=process.env.TELEGRAM_WEBHOOK_SECRET;
const token=process.env.TELEGRAM_BOT_TOKEN;
const fixtures=new Map();
if(process.env.FAKE_TELEGRAM_PDF)fixtures.set('synthetic-pdf',process.env.FAKE_TELEGRAM_PDF);
if(process.env.FAKE_TELEGRAM_JPEG)fixtures.set('synthetic-jpeg',process.env.FAKE_TELEGRAM_JPEG);
if(process.env.FAKE_TELEGRAM_PNG)fixtures.set('synthetic-png',process.env.FAKE_TELEGRAM_PNG);
const sent=[];
let nextUpdate=1000,nextMessage=1;

async function jsonBody(request,limit=128*1024){const chunks=[];let size=0;for await(const chunk of request){size+=chunk.length;if(size>limit)throw new Error('too large');chunks.push(chunk)}return JSON.parse(Buffer.concat(chunks).toString('utf8')||'{}')}
function reply(response,status,value,type='application/json'){response.writeHead(status,{'content-type':type,'cache-control':'no-store'});response.end(type==='application/json'?JSON.stringify(value):value)}
async function inject(value){const update={update_id:nextUpdate++,...value};const response=await fetch(`${gateway}/integrations/telegram/webhook`,{method:'POST',headers:{'content-type':'application/json','X-Telegram-Bot-Api-Secret-Token':secret},body:JSON.stringify(update)});return {status:response.status,body:await response.json().catch(()=>({}))}}

const server=createServer(async(request,response)=>{try{
  const url=new URL(request.url,'http://127.0.0.1');
  if(url.pathname==='/health')return reply(response,200,{status:'ok'});
  if(url.pathname==='/'){return reply(response,200,`<!doctype html><meta charset="utf-8"><title>Fake Telegram</title><style>body{font:16px system-ui;max-width:700px;margin:3rem auto;padding:1rem}input,button{font:inherit;padding:.7rem;margin:.3rem}</style><h1>Disposable Fake Telegram</h1><p>Synthetic private messages only. No request contacts Telegram.</p><input id=t placeholder="Message or command"><button onclick="send()">Send</button><pre id=o></pre><script>async function send(v=t.value){o.textContent=await fetch('/inject/text',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({text:v})}).then(r=>r.text())}const s=new URLSearchParams(location.search).get('start');if(s){t.value='/start '+s;send(t.value).then(()=>history.replaceState({},'',location.pathname))}</script>`,'text/html');}
  if(url.pathname==='/inject/text'&&request.method==='POST'){const body=await jsonBody(request);const result=await inject({message:{message_id:nextMessage++,text:String(body.text||'').slice(0,2000),chat:{id:70001,type:'private'},from:{id:70001,first_name:'Synthetic',last_name:'Owner'}}});return reply(response,result.status,result.body)}
  if(url.pathname==='/inject/attachment'&&request.method==='POST'){const body=await jsonBody(request);const fileId=String(body.file_id||'synthetic-pdf');if(!fixtures.has(fileId))return reply(response,422,{error:'unknown_fixture'});const mime=fileId.endsWith('jpeg')?'image/jpeg':fileId.endsWith('png')?'image/png':'application/pdf';const size=(await readFile(fixtures.get(fileId))).length;const result=await inject({message:{message_id:nextMessage++,caption:String(body.caption||'').slice(0,2000),chat:{id:70001,type:'private'},from:{id:70001,first_name:'Synthetic',last_name:'Owner'},document:{file_id:fileId,file_name:`${fileId}.${mime==='application/pdf'?'pdf':mime==='image/png'?'png':'jpg'}`,mime_type:mime,file_size:size}}});return reply(response,result.status,result.body)}
  if(url.pathname==='/inject/replay'&&request.method==='POST'){const body=await jsonBody(request);const update={update_id:Number(body.update_id),message:{message_id:nextMessage++,text:String(body.text||'/help'),chat:{id:70001,type:'private'},from:{id:70001}}};const remote=await fetch(`${gateway}/integrations/telegram/webhook`,{method:'POST',headers:{'content-type':'application/json','X-Telegram-Bot-Api-Secret-Token':secret},body:JSON.stringify(update)});return reply(response,remote.status,await remote.json())}
  if(url.pathname==='/outbox')return reply(response,200,{messages:sent.map(({chat_id,text,reply_markup,message_id})=>({chat_id,text,reply_markup,message_id}))});
  if(url.pathname.includes(`/bot${token}/sendMessage`)){const body=await jsonBody(request);const item={...body,message_id:nextMessage++};sent.push(item);return reply(response,200,{ok:true,result:item})}
  if(url.pathname.includes(`/bot${token}/getFile`)){const body=await jsonBody(request);if(!fixtures.has(body.file_id))return reply(response,404,{ok:false});return reply(response,200,{ok:true,result:{file_path:`fixtures/${body.file_id}`}})}
  if(url.pathname.includes(`/file/bot${token}/fixtures/`)){const id=url.pathname.split('/').at(-1);const path=fixtures.get(id);if(!path)return reply(response,404,{ok:false});const bytes=await readFile(path);response.writeHead(200,{'content-type':'application/octet-stream','content-length':String(bytes.length)});return response.end(bytes)}
  return reply(response,404,{error:'not_found'});
}catch{return reply(response,400,{error:'invalid_request'})}});
server.listen(port,'127.0.0.1',()=>console.log(JSON.stringify({status:'ready',port:server.address().port})));
