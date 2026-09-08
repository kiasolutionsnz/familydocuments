import assert from "node:assert/strict";
import test from "node:test";
import {withDraftRetention} from "../notifications/maintenance.mjs";

test("recurring maintenance expires drafts before notification delivery",async()=>{
  const calls=[];
  const result=await withDraftRetention({
    token:"synthetic-service-token",
    rpc:async(name,payload,token,options)=>{calls.push(name);assert.equal(name,"expire_ocr_intake_drafts");assert.deepEqual(payload,{});assert.equal(token,"synthetic-service-token");assert.deepEqual(options,{timeoutMs:10000});return 2;},
    deliver:async()=>{calls.push("deliver");return {sent:1};}
  });
  assert.deepEqual(calls,["expire_ocr_intake_drafts","deliver"]);
  assert.deepEqual(result,{sent:1,expired_drafts:2});
});

test("SMTP configuration/verification failure cannot prevent draft expiry",async()=>{
  let expired=false;
  await assert.rejects(withDraftRetention({token:"synthetic",rpc:async()=>{expired=true;return 1;},deliver:async()=>{assert.equal(expired,true);throw new Error("synthetic SMTP unavailable");}}),/synthetic SMTP unavailable/);
  assert.equal(expired,true);
});

test("retention failure is safely reported without blocking due reminders",async()=>{
  const events=[];let delivered=false;
  const result=await withDraftRetention({token:"synthetic",rpc:async()=>{throw new Error("do not log private payload");},onRetentionError:event=>events.push(event),deliver:async()=>{delivered=true;return {sent:3};}});
  assert.equal(delivered,true);
  assert.deepEqual(result,{sent:3,expired_drafts:null});
  assert.deepEqual(events,[{status:"retention_failed",code:"ocr_draft_retention_failed"}]);
  assert.doesNotMatch(JSON.stringify(events),/private payload/);
});

test("an invalid cleanup result is reported, not counted as successful expiry",async()=>{
  const events=[];
  const result=await withDraftRetention({token:"synthetic",rpc:async()=>({error:"synthetic"}),onRetentionError:event=>events.push(event),deliver:async()=>({sent:0})});
  assert.equal(result.expired_drafts,null);assert.equal(events.length,1);
});
