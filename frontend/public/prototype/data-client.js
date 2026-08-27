(function attachFamilyPassportData(global) {
  "use strict";
  const baseUrl = "https://api-familydocuments.servicehub.co.nz/rest";
  async function rpc(name, payload = {}, retry = true) {
    const token = global.familyPassportAuth.getAccessToken();
    if (!token) throw new Error("Sign in is required.");
    const response = await fetch(`${baseUrl}/rpc/${name}`, {
      method: "POST",
      headers: {authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json"},
      body: JSON.stringify(payload)
    });
    const body = await response.json().catch(() => ({}));
    if (response.status === 401 && retry) {
      await global.familyPassportAuth.refreshSession();
      return rpc(name, payload, false);
    }
    if (!response.ok) {
      const error = new Error(body.message || "The household request could not be completed.");
      error.status = response.status;
      error.code = body.code || "data_failed";
      throw error;
    }
    return body;
  }
  global.familyPassportData = Object.freeze({
    baseUrl,
    snapshot: () => rpc("household_snapshot"),
    recordAppHit: hitId => rpc("record_app_hit", {hit_id: hitId}),
    bootstrap: (householdName, displayName) => rpc("bootstrap_household", {household_name: householdName, display_name: displayName}),
    acceptInvitation: () => rpc("accept_my_invitation"),
    createCategory: categoryName => rpc("create_category", {category_name: categoryName}),
    inviteMember: (email, role) => rpc("invite_member", {invitee_email: email, member_role: role}),
    createDocument: (title, categoryId) => rpc("create_document", {document_title: title, category: categoryId}),
    createManualDocument: value => rpc("create_manual_document", value),
    confirmExtraction: async value => {const result=await rpc("confirm_extraction",value),source=global.familyPassportPendingDriveSource;if(result.document_id&&source)await rpc("link_google_drive_source",{document:result.document_id,external_source:source});global.familyPassportPendingDriveSource=null;return result},
    rotateInbox: () => rpc("rotate_household_inbox"),
    setInboxAlias: preferred => rpc("set_household_inbox_alias", {preferred_local_part: preferred}),
    disableInbox: () => rpc("disable_household_inbox"),
    enableInbox: () => rpc("enable_household_inbox"),
    inboundEmails: () => rpc("inbound_email_summaries"),
    classificationProposals: () => rpc("email_classification_summaries"),
    classificationJobs: () => rpc("classification_job_summaries"),
    documentLifecycle: () => rpc("document_lifecycle_summaries"),
    setDocumentLifecycle: (document, action) => rpc("set_document_lifecycle", {document, action}),
    reminderDashboard: () => rpc("reminder_dashboard"),
    configureReminder: (reminder, repeat) => rpc("configure_reminder", {reminder, repeat}),
    actOnReminder: (reminder, action, snoozeUntil = null) => rpc("act_on_reminder", {reminder, action, snooze_until: snoozeUntil}),
    setReminderAudience: (reminder, audience, emailEveryone = false) => rpc("set_reminder_audience", {reminder, new_audience: audience, email_everyone: emailEveryone}),
    respondToFamilyReminder: (reminder, action) => rpc("respond_to_family_reminder", {reminder, response_action: action}),
    searchRecords: query => rpc("search_household_records", {search_query: query, result_limit: 20}),
    entities: () => rpc("entity_summaries"),
    createEntity: (kind, name, customKind = null) => rpc("create_entity", {kind, entity_name: name, custom_kind: customKind}),
    linkDocumentEntity: (document, entity, linkAction = "link") => rpc("link_document_entity", {document, entity, link_action: linkAction}),
    archiveEntity: entity => rpc("archive_entity", {entity}),
    askSearchAssistant: async query => {
      const token=global.familyPassportAuth.getAccessToken();if(!token)throw new Error("Sign in is required.");
      const response=await fetch("https://api-familydocuments.servicehub.co.nz/search/ask",{method:"POST",headers:{authorization:`Bearer ${token}`,"content-type":"application/json"},body:JSON.stringify({query})});
      const body=await response.json().catch(()=>({}));if(!response.ok)throw new Error(body.error||"Search assistant unavailable.");return body;
    },
    retryClassification: job => rpc("retry_classification_job", {job}),
    confirmEmailClassification: async value => {
      const result=await rpc("confirm_email_classification",value),choice=global.familyPassportPendingAccess||{};
      if(result.document_id&&choice.privacy==="shared_by_rules")await rpc("set_document_privacy",{document:result.document_id,mode:"shared_by_rules"});
      if(result.document_id&&choice.member)await rpc("set_document_access",{document:result.document_id,member:choice.member,access:"view"});
      global.familyPassportPendingAccess=null;
      return result;
    },
    rejectEmailClassification: proposal => rpc("reject_email_classification", {proposal}),
    setDocumentAccess: (documentId, memberId, access) => rpc("set_document_access", {document: documentId, member: memberId, access}),
    setDocumentPrivacy: (documentId, mode) => rpc("set_document_privacy", {document: documentId, mode}),
    accessRules: () => rpc("access_rule_summaries"),
    setAccessRule: (scope, scopeId, member, access) => rpc("set_access_rule", {rule_scope: scope, scope_id: scopeId, member, access}),
    permissionAudit: () => rpc("permission_audit_summaries", {result_limit: 20})
    ,documentSource: document => rpc("document_source", {document})
    ,purgeDocument: document => rpc("purge_document", {document, confirmation:"PURGE"})
    ,manageMember: (member, action, newRole = null) => rpc("manage_member", {member, action, new_role:newRole})
    ,revokeInvitation: invitation => rpc("revoke_invitation", {invitation})
    ,transferOwnership: member => rpc("transfer_household_ownership", {member})
    ,securityAudit: () => rpc("security_audit_summaries", {result_limit:30})
    ,registerGoogleDriveSource: value => rpc("register_google_drive_source", value)
    ,googleDriveSources: () => rpc("google_drive_source_summaries")
    ,updateGoogleDriveSource: (source, metadata, observedStatus="active") => rpc("update_google_drive_source", {source,new_file_name:metadata.name||"Unavailable Drive file",mime_type:metadata.mimeType||"application/pdf",size_bytes:Number(metadata.size||1),modified_time:metadata.modifiedTime||new Date(0).toISOString(),provider_version:String(metadata.version||"unknown"),provider_checksum:metadata.md5Checksum||null,new_parent_ids:metadata.parents||[],observed_status:observedStatus})
    ,disconnectGoogleDrive: () => rpc("disconnect_google_drive")
    ,googleDriveConnection: () => rpc("household_google_drive_connection_summary")
    ,setGoogleDriveFolder: value => rpc("set_google_drive_folder",value)
    ,disconnectGoogleDriveStorage: () => rpc("disconnect_google_drive_storage")
    ,createGoogleDriveDocument: value => rpc("create_google_drive_document",value)
    ,editDocumentMetadata: value => rpc("edit_document_metadata",value)
    ,mergeDocuments: (primaryDocument, duplicateDocument) => rpc("merge_documents",{primary_document:primaryDocument,duplicate_document:duplicateDocument})
    ,explainDocumentAccess: (document, member=null) => rpc("explain_document_access",{document,member})
    ,householdExport: () => rpc("household_export")
    ,savedLinkWorkspace: (searchQuery=null,category=null,visibility="all",resultLimit=100) => rpc("saved_link_workspace",{search_query:searchQuery,category,visibility,result_limit:resultLimit})
    ,ensureSavedLinkDefaults: () => rpc("ensure_saved_link_defaults")
    ,createSavedLinkCategory: categoryName => rpc("create_saved_link_category",{category_name:categoryName})
    ,createSavedLink: value => rpc("create_saved_link",value)
    ,updateSavedLink: value => rpc("update_saved_link",value)
    ,setSavedLinkShares: (link,memberIds) => rpc("set_saved_link_shares",{link,member_ids:memberIds})
    ,deleteSavedLink: link => rpc("delete_saved_link",{link})
    ,restoreSavedLink: link => rpc("restore_saved_link",{link})
    ,rentalWorkspace: () => rpc("rental_property_workspace")
    ,createRentalProperty: value => rpc("create_rental_property",value)
    ,createRentalBill: value => rpc("create_rental_bill",value)
    ,setRentalBillStatus: (bill,newStatus,paidOn=null) => rpc("set_rental_bill_status",{bill,new_status:newStatus,paid_on:paidOn})
    ,rentalPropertyExport: () => rpc("rental_property_export")
  });
})(window);
