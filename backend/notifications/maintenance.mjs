// Run private-draft retention on the existing notification-worker cadence.
// Dependencies are injectable so tests never load secrets or send real email.
export async function withDraftRetention({rpc,token,deliver,onRetentionError=()=>{}}){
  let expiredDrafts=null;
  try{
    const count=await rpc("expire_ocr_intake_drafts",{},token,{timeoutMs:10000});
    if(!Number.isSafeInteger(count)||count<0)throw new Error("invalid retention result");
    expiredDrafts=count;
  }catch{
    // Never log document content, tokens, or arbitrary provider error messages.
    onRetentionError({status:"retention_failed",code:"ocr_draft_retention_failed"});
  }
  const delivered=await deliver();
  return {...delivered,expired_drafts:expiredDrafts};
}
