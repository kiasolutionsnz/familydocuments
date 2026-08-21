(function attachFamilyPassportData(global) {
  "use strict";
  const baseUrl = "http://127.0.0.1:55322";
  async function rpc(name, payload = {}) {
    const token = global.familyPassportAuth.getAccessToken();
    if (!token) throw new Error("Sign in is required.");
    const response = await fetch(`${baseUrl}/rpc/${name}`, {
      method: "POST",
      headers: {authorization: `Bearer ${token}`, "content-type": "application/json", accept: "application/json"},
      body: JSON.stringify(payload)
    });
    const body = await response.json().catch(() => ({}));
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
    bootstrap: (householdName, displayName) => rpc("bootstrap_household", {household_name: householdName, display_name: displayName}),
    acceptInvitation: () => rpc("accept_my_invitation"),
    createCategory: categoryName => rpc("create_category", {category_name: categoryName}),
    inviteMember: (email, role) => rpc("invite_member", {invitee_email: email, member_role: role}),
    createDocument: (title, categoryId) => rpc("create_document", {document_title: title, category: categoryId}),
    confirmExtraction: value => rpc("confirm_extraction", value),
    setDocumentAccess: (documentId, memberId, access) => rpc("set_document_access", {document: documentId, member: memberId, access})
  });
})(window);
