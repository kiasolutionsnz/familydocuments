(function(root,factory){
  const api=factory();
  if(typeof module==="object"&&module.exports) module.exports=api;
  root.FamilyPassportModel=api;
})(typeof globalThis!=="undefined"?globalThis:this,function(){
  "use strict";
  const household=Object.freeze({
    name:"Harbour household",
    people:[{id:"aroha",name:"Aroha Rangi",detail:"2 confirmed records",kind:"AR"},{id:"matiu",name:"Matiu Rangi",detail:"1 confirmed record",kind:"MR"}],
    home:[{id:"te-aro",name:"Te Aro home",detail:"4 documents · 1 reminder",kind:"TH"}],
    vehicles:[{id:"corolla",name:"2021 Toyota Corolla",detail:"3 documents · rego KIA721",kind:"TC"}],
    actions:[
      {id:"insurance",title:"Confirm home insurance renewal",detail:"Suggested from Tower policy · due 28 Aug",kind:"HI",destination:"review"},
      {id:"passport",title:"Passport expires in 8 months",detail:"Aroha Rangi · 14 Apr 2027",kind:"PP",destination:"records",tab:"people"},
      {id:"wof",title:"Vehicle WOF due next month",detail:"Toyota Corolla · 22 Sep",kind:"WF",destination:"records",tab:"vehicles"}
    ]
  });
  const connectors=Object.freeze([
    {id:"google-drive",name:"Google Drive",badge:"GD",access:"Files you explicitly select",scope:"drive.file",picker:"Google Picker",status:"available"},
    {id:"one-drive",name:"Microsoft OneDrive",badge:"OD",access:"Files you explicitly select",scope:"delegated picker access",picker:"OneDrive File Picker",status:"available"}
  ]);
  const docs=[
    {id:"tower-policy",match:q=>/\b(insurance|tower|policy)\b/.test(q)||(/\b(home|house)\b/.test(q)&&/\b(renew|renews|renewal)\b/.test(q)),title:"Tower home insurance policy",answer:"Your house insurance renews on 28 August 2026.",meta:"Te Aro home · confirmed 12 Aug 2026",citation:"Tower-policy-2026.pdf · page 1 · selected Drive file"},
    {id:"toyota-wof",match:q=>/\bwof\b/.test(q)||(/\b(toyota|corolla)\b/.test(q)&&/\b(due|inspection)\b/.test(q)),title:"Toyota WOF record",answer:"The Toyota Corolla WOF is due on 22 September 2026.",meta:"Toyota Corolla · confirmed 10 Aug 2026",citation:"Toyota-WOF-2026.pdf · page 1 · selected Drive file"}
  ];
  const clone=value=>JSON.parse(JSON.stringify(value));
  class PrototypeAdapter{
    getHousehold(){return clone(household)}
    getConnectors(){return clone(connectors)}
    search(raw){
      const query=String(raw||"").trim().toLowerCase();
      if(!query)return {kind:"prompt",query,results:[]};
      const matches=docs.filter(doc=>doc.match(query));
      if(!matches.length)return {kind:"abstain",query,results:[],message:"No confirmed synthetic source answers that question."};
      if(query.includes("conflict"))return {kind:"conflict",query,results:clone(matches),message:"Two synthetic sources disagree. Compare them before relying on a date."};
      return {kind:"results",query,results:clone(matches)};
    }
    submit(){return {ok:true,notice:"Synthetic prototype data — nothing is saved."}}
  }
  function buildSearchView(result,selectedId=null){
    const safe=result&&Array.isArray(result.results)?result:{kind:"prompt",results:[]};
    const sources=clone(safe.results);
    const selectedSource=selectedId?sources.find(source=>source.id===selectedId)||null:null;
    if(safe.kind==="conflict")return {kind:"conflict",headline:"Sources disagree — compare them before relying on an answer.",sources,selectedSource};
    if(safe.kind==="results")return {kind:"results",headline:sources[0]?.answer||"No supported answer found.",sources,selectedSource};
    if(safe.kind==="abstain")return {kind:"abstain",headline:safe.message||"No supported answer found.",sources:[],selectedSource:null};
    return {kind:"prompt",headline:"Try a natural question.",sources:[],selectedSource:null};
  }
  function restoreInvoker(invoker){
    if(!invoker||invoker.isConnected===false||typeof invoker.focus!=="function")return false;
    invoker.focus();return true;
  }
  function stateCopy(route,kind,context={}){
    const query=context.query?` Your query “${context.query}” is preserved.`:"";
    const map={
      home:{loading:["Checking your next actions","Only authorised synthetic summaries are loading."],empty:["Your household is ready","Add one useful record to create your first next action."],error:["Home could not refresh","Nothing changed. Retry to return to the last confirmed synthetic view."],restricted:["Some household areas are unavailable","Only information you are permitted to see would appear here. Hidden items are not named or counted."],offline:["Home is offline","The last authorised snapshot may be out of date. Retry when connected."],conflict:["One action needs comparison","Two sources disagree. Open Review to compare before confirming."],stale:["Next actions may be out of date","Check the source connection before relying on an important date."]},
      records:{loading:["Loading authorised records","Record names and counts appear only after permission checks."],empty:["No records in this category","Choose Add record to start with one exact file."],error:["Records could not load","Your selected category is preserved. Retry without changing confirmed records."],restricted:["Records are not available","No hidden record name, category count or relationship is disclosed."],offline:["Records are offline","The last authorised category is preserved but may be stale."],conflict:["A record has conflicting evidence","Open the representative record to compare sources before confirming."],stale:["Records may be out of date","Confirmed details remain visible; reconnect before editing."]},
      add:{loading:["Preparing source choices","No provider permission or file has been stored."],empty:["Choose where to begin","Select exact Drive files or preview device capture."],error:["That source is unavailable","No selection was retained. Try again or choose the other source."],restricted:["Adding is not available","Your household role does not allow new sources. No account details are disclosed."],offline:["Add is offline","No upload is queued. Retry or cancel without storing a file."],conflict:["A duplicate may exist","Compare the proposed synthetic file with the existing record before adding."],stale:["Source status needs refreshing","Reconnect before selecting files; no new scope has been granted."]},
      review:{loading:["Loading source evidence","Your unconfirmed correction is preserved locally in this visual state."],empty:["Nothing needs review","No suggestion was committed automatically. Return to Records or add information."],error:["Suggestion could not be saved","The proposed date 28 August 2026 remains unconfirmed. Retry, skip or mark it incorrect."],restricted:["This suggestion is unavailable","No source name, field or relationship is disclosed."],offline:["Review is offline","The proposed date remains unconfirmed. Retry when connected or skip for now."],conflict:["Renewal sources disagree","One source says 28 August; another says 30 August. Compare evidence, then confirm neither silently."],stale:["Source version changed","Reload the exact source before confirming the preserved proposed date."]},
      search:{loading:["Searching authorised sources","Permission filtering happens before any result or count is shown."],empty:["Ask a household question","Try a question about the synthetic home insurance or Toyota WOF."],error:["Search could not finish",`No answer was generated.${query} Retry or refine it.`],restricted:["Search is unavailable","No hidden result, count, snippet or citation is revealed."],offline:["Search is offline",`No new answer was generated.${query} Retry when connected.`],conflict:["Sources disagree",`Compare exact cited versions before relying on an answer.${query}`],stale:["Search index may be out of date",`Open an exact source before relying on the result.${query}`]},
      connections:{loading:["Checking connection status","No provider token or file detail is shown until account and household permissions pass."],empty:["No storage provider connected","Choose Google Drive or OneDrive when you are ready; originals stay with that provider."],error:["Connection could not be checked","No new access was granted. Retry without changing existing provider files."],restricted:["Connections are unavailable","Only a household owner or authorised admin can manage provider access."],offline:["Connections are offline","No provider request is queued. Existing originals remain unchanged."],conflict:["Connection ownership needs review","The provider account does not match the expected household owner; do not continue."],stale:["Connection needs reconfirmation","Future access is paused until the provider permission is verified again."]}
    };
    return map[route][kind];
  }
  return {PrototypeAdapter,buildSearchView,restoreInvoker,stateCopy};
});
