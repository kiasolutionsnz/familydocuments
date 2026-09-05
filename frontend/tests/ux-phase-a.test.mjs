import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";

async function loadModel(){
  const source=await readFile(new URL("../public/prototype/model.js",import.meta.url),"utf8");
  const context={};context.globalThis=context;
  vm.runInNewContext(source,context);
  return context.FamilyPassportModel;
}

test("reminders and notifications use separate semantics",async()=>{
  const {reminderGroups}=await loadModel();
  const items=[
    {id:"future",status:"upcoming",due_state:"upcoming",days_until:30,due_at:"2027-10-01"},
    {id:"soon",status:"upcoming",due_state:"upcoming",days_until:4,due_at:"2027-09-05"},
    {id:"late",status:"upcoming",due_state:"overdue",days_until:-2,due_at:"2027-08-30"},
    {id:"done",status:"completed",due_state:"completed",days_until:-10,due_at:"2027-08-22"},
    {id:"unknown",status:"upcoming",due_state:"upcoming",days_until:null,due_at:"2027-11-01"},
  ];
  assert.deepEqual(reminderGroups(items,"upcoming").map(x=>x.id),["soon","future","unknown"]);
  assert.deepEqual(reminderGroups(items,"due_soon").map(x=>x.id),["soon"]);
  assert.deepEqual(reminderGroups(items,"overdue").map(x=>x.id),["late"]);
  assert.deepEqual(reminderGroups(items,"completed").map(x=>x.id),["done"]);
});

test("newer feature routes have a usable loading and error state",async()=>{
  const {stateCopy}=await loadModel();
  for(const route of ["saved","rentals","travel","reminders"]){
    assert.equal(stateCopy(route,"loading")[0],"Loading your information");
    assert.equal(stateCopy(route,"error")[0],"This page could not load");
  }
});

test("storage state does not invent a failure before an attempt",async()=>{
  const {storageConnectionState}=await loadModel();
  assert.deepEqual({...storageConnectionState(null)}, {kind:"not_connected",label:"Not connected",error:""});
  assert.equal(storageConnectionState(null,{status:"connecting"}).kind,"connecting");
  assert.equal(storageConnectionState({status:"active"}).kind,"connected");
  assert.equal(storageConnectionState({status:"disconnected"}).kind,"disconnected");
  assert.equal(storageConnectionState({status:"reconnect_required"}).label,"Reconnect required");
  assert.equal(storageConnectionState({status:"reconnect_required"},{status:"connecting"}).label,"Connecting…");
  assert.match(storageConnectionState(null,{status:"failed",error:"Try again"}).error,/Try again/);
});

test("Phase A routes and state are feature-scoped",async()=>{
  const [html,app,data]=await Promise.all([
    readFile(new URL("../public/prototype/index.html",import.meta.url),"utf8"),
    readFile(new URL("../public/prototype/app.js",import.meta.url),"utf8"),
    readFile(new URL("../public/prototype/data-client.js",import.meta.url),"utf8"),
  ]);
  assert.match(html,/href="#reminders" data-route="reminders"/);
  assert.match(app,/searchState:\{message:""\}/);
  assert.match(app,/documentState:\{busyId:null,errors:\{\}\}/);
  assert.match(app,/storageState:\{status:"idle",error:""\}/);
  assert.match(app,/reminderState:\{filter:"upcoming",error:""\}/);
  assert.match(app,/if\(state\.documentState\.busyId\)return/);
  assert.match(app,/Original file is unavailable\./);
  assert.match(app,/data-route-button="reminders">View all/);
  assert.match(app,/Google Drive is not connected\./);
  assert.match(app,/data-disconnect-drive/);
  assert.match(app,/Disconnect Google Drive\?/);
  assert.doesNotMatch(app,/const connectionError=state\.dataError/);
  assert.match(data,/create_ocr_intake_draft/);
  assert.match(data,/record_ocr_intake_result/);
  assert.match(data,/confirm_ocr_intake/);
  assert.match(data,/reject_ocr_intake/);
});
