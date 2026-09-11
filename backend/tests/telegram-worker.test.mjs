import test from 'node:test';
import assert from 'node:assert/strict';
import {detectSupportedFile, processTransportCycle, TELEGRAM_MAX_FILE_BYTES} from '../telegram/worker-core.mjs';
import {matchingChoice} from '../telegram/worker.mjs';

test('typed Rentals safely selects the existing Rental records choice',()=>{
  const action={id:'save-rental-records'};
  const clarification={data:{choices:['Travel','Rental records'],choice_actions:[{id:'save-travel'},action]}};
  assert.equal(matchingChoice(clarification,'Rentals'),action);
  assert.equal(matchingChoice(clarification,'Unknown'),null);
});

test('validates PDF JPEG and PNG signatures and rejects mismatches', () => {
  assert.equal(detectSupportedFile(Buffer.from('%PDF-1.7 test')), 'application/pdf');
  assert.equal(detectSupportedFile(Buffer.from([0xff,0xd8,1,2,0xff,0xd9])), 'image/jpeg');
  assert.equal(detectSupportedFile(Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,1])), 'image/png');
  assert.equal(detectSupportedFile(Buffer.from('not a document')), null);
  assert.equal(detectSupportedFile(Buffer.alloc(TELEGRAM_MAX_FILE_BYTES + 1)), null);
});

test('leases updates and outbox exactly once through adapter boundaries', async () => {
  const calls=[];
  const adapter={
    claimUpdates: async()=>[{id:'u1',lease_token:'l1'}],
    handleUpdate: async()=>({outcome:'handled',responses:[{request_key:'telegram:1:reply',text:'Done'}]}),
    completeUpdate: async(...args)=>calls.push(['complete',...args]), failUpdate:async()=>assert.fail(),
    claimOutbox:async()=>[{id:'o1',lease_token:'l2'}],send:async()=>42,
    completeOutbox:async(...args)=>calls.push(['sent',...args]),failOutbox:async()=>assert.fail(),
  };
  const result=await processTransportCycle(adapter);
  assert.deepEqual(result,{updates:1,completed:1,retrying:0,failed:0,outbound:1,sent:1});
  assert.equal(calls.filter(x=>x[0]==='complete').length,1);
  assert.equal(calls.filter(x=>x[0]==='sent').length,1);
});

test('terminal attachment errors are not retried', async () => {
  let failure;
  const adapter={claimUpdates:async()=>[{id:'u',lease_token:'l'}],handleUpdate:async()=>{throw new Error('mime mismatch')},completeUpdate:async()=>assert.fail(),failUpdate:async(...x)=>failure=x,claimOutbox:async()=>[],send:async()=>{},completeOutbox:async()=>{},failOutbox:async()=>{}};
  await processTransportCycle(adapter);
  assert.deepEqual(failure.slice(0,4),['u','l',false,'invalid_attachment']);
  assert.match(failure[4].message,/mime mismatch/);
});

test('retryable attachment failure retains the original error for durable recovery',async()=>{
  let failure;
  const original=Object.assign(new Error('truncated download'),{attachmentID:'a1',category:'truncated'});
  const adapter={claimUpdates:async()=>[{id:'u',lease_token:'l'}],handleUpdate:async()=>{throw original},completeUpdate:async()=>assert.fail(),failUpdate:async(...args)=>{failure=args},claimOutbox:async()=>[],send:async()=>{},completeOutbox:async()=>{},failOutbox:async()=>{}};
  const result=await processTransportCycle(adapter);
  assert.equal(result.retrying,1);
  assert.equal(result.failed,0);
  assert.equal(failure[4],original);
});

test('job bridge runs before claims and a reply timeout never replays the action',async()=>{
  const calls=[];
  const adapter={beforeCycle:async()=>calls.push('jobs'),claimUpdates:async()=>{calls.push('updates');return[]},completeUpdate:async()=>assert.fail(),failUpdate:async()=>assert.fail(),claimOutbox:async()=>[{id:'reply-1',lease_token:'lease-1'}],send:async()=>{throw new Error('Telegram timeout')},completeOutbox:async()=>assert.fail(),failOutbox:async(id,lease,retryable)=>calls.push(['retry',id,lease,retryable])};
  const result=await processTransportCycle(adapter);
  assert.deepEqual(calls.slice(0,2),['jobs','updates']);
  assert.deepEqual(calls[2],['retry','reply-1','lease-1',true]);
  assert.equal(result.updates,0);
});
