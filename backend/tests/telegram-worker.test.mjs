import test from 'node:test';
import assert from 'node:assert/strict';
import {detectSupportedFile, processTransportCycle, TELEGRAM_MAX_FILE_BYTES} from '../telegram/worker-core.mjs';

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
  assert.deepEqual(failure,['u','l',false,'invalid_attachment']);
});
