import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

// Explicit opt-in; secrets use stdin, never process arguments or temporary files.
export async function telegramFetch(url, options={}, transport='fetch') {
  if (transport==='fetch') return fetch(url, options);
  if (transport!=='windows' || process.platform!=='win32') throw new Error('Unsupported Telegram transport');
  const endpoint=new URL(url);
  if(endpoint.protocol!=='https:'||endpoint.hostname!=='api.telegram.org'||endpoint.port||endpoint.username||endpoint.password) throw new Error('Invalid Telegram endpoint');
  const method=options.method||'GET';
  if(!['GET','POST'].includes(method)) throw new Error('Unsupported Telegram method');
  const timeout=options.timeout||20000,maxBytes=options.maxBytes||21*1024*1024;
  return new Promise((resolve,reject)=>{
    const child=spawn('powershell.exe',['-NoProfile','-NonInteractive','-File',fileURLToPath(new URL('./windows-http.ps1',import.meta.url))],{windowsHide:true,stdio:['pipe','pipe','pipe']});
    const chunks=[];let size=0;
    const fail=()=>reject(new Error('Telegram Windows HTTPS request failed'));
    const timer=setTimeout(()=>{child.kill();fail()},timeout+5000);
    child.stdout.on('data',chunk=>{size+=chunk.length;if(size>maxBytes*1.4+1024){child.kill();fail()}else chunks.push(chunk)});
    child.stderr.resume();
    child.on('error',()=>{clearTimeout(timer);fail()});
    child.stdin.on('error',()=>{});
    child.on('close',code=>{
      clearTimeout(timer);
      try {
        const result=JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if(code!==0||result.error) return fail();
        resolve(new Response(Buffer.from(result.body,'base64'),{status:result.status}));
      }catch{fail()}
    });
    child.stdin.end(JSON.stringify({url:endpoint.href,method,body:options.body,timeout,maxBytes}));
  });
}
