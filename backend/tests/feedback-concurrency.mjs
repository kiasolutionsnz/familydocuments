import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
const container=process.env.FD_TEST_CONTAINER;
if(process.env.FD_TEST_CONTEXT!=='isolated' || !/^fd-test-[a-f0-9]{12}-db$/.test(container??'')) throw new Error('Disposable context required');
function sql(input){return new Promise((resolve,reject)=>{
 const child=spawn('docker',['exec','-i',container,'psql','-U','postgres','-d','postgres','-Atq','-v','ON_ERROR_STOP=1'],{windowsHide:true,stdio:['pipe','pipe','pipe']});let out='';child.stdout.on('data',x=>out+=x);child.stderr.resume();child.on('error',reject);child.on('close',code=>code===0?resolve(out):reject(new Error('synthetic SQL failed')));child.stdin.end(input);
});}
await sql(`select set_config('request.jwt.claims','{"sub":"57000000-0000-4000-8000-000000000099","role":"authenticated"}',false);select fp.feedback_request('create','concurrent-feedback-001',E'Feedback: adjust Library title.\nExpected: readable title\nObserved: clipped title');`);
const results=await Promise.all([sql("begin;select fp.feedback_claim('worker-one');select pg_sleep(0.2);commit;"),sql("begin;select fp.feedback_claim('worker-two');select pg_sleep(0.2);commit;")]);
assert.equal(results.filter(x=>x.includes('lease_token')).length,1);
console.log('PASS: two concurrent PostgreSQL workers claimed exactly one ticket.');
