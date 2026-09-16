import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {telegramFetch} from '../telegram/http-transport.mjs';

test('default transport retains HTTP status and JSON body',async()=>{
  const server=createServer((req,res)=>{res.writeHead(403,{'content-type':'application/json'});res.end('{"ok":false}')});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  try {
    const response=await telegramFetch(`http://127.0.0.1:${server.address().port}`);
    assert.equal(response.status,403);
    assert.deepEqual(await response.json(),{ok:false});
  } finally {await new Promise(resolve=>server.close(resolve))}
});
test('Windows transport rejects non-Telegram destinations without exposing URLs',async()=>{
  for(const url of ['http://api.telegram.org/botSECRET','https://example.com/botSECRET','https://api.telegram.org:444/botSECRET','https://SECRET@api.telegram.org/']) {
    await assert.rejects(telegramFetch(url,{},'windows'),error=>!error.message.includes('SECRET'));
  }
});
test('unknown transports fail closed',async()=>{
  await assert.rejects(telegramFetch('https://api.telegram.org',{},'unknown'),/Unsupported/);
});
