(function attachFamilyPassportAuth(global) {
  "use strict";
  const baseUrl = "http://127.0.0.1:55321";
  let session = null;
  async function request(path, options = {}) {
    const response = await fetch(`${baseUrl}${path}`, {...options, headers: {"content-type": "application/json", ...(options.headers || {})}});
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = new Error("Authentication could not be completed.");
      error.code = body.code || body.error_code || "auth_failed";
      error.status = response.status;
      throw error;
    }
    return body;
  }
  async function health() {
    const response = await fetch(`${baseUrl}/health`, {headers: {accept: "application/json"}});
    if (!response.ok) throw new Error("Local authentication is unavailable.");
    return true;
  }
  async function signUp({email, password, name}) {
    return request("/signup", {method: "POST", body: JSON.stringify({email, password, data: name ? {display_name: name} : {}})});
  }
  async function signIn({email, password}) {
    const body = await request("/token?grant_type=password", {method: "POST", body: JSON.stringify({email, password})});
    if (!body.access_token || !body.user?.email) throw new Error("Authentication response was incomplete.");
    session = {accessToken: body.access_token, refreshToken: body.refresh_token, user: body.user};
    return {user: {id: body.user.id, email: body.user.email}};
  }
  async function signOut() {
    const current = session;
    session = null;
    if (!current?.accessToken) return;
    try { await request("/logout", {method: "POST", headers: {authorization: `Bearer ${current.accessToken}`}}); } catch {}
  }
  function getAccessToken() { return session?.accessToken || null; }
  function getUser() { return session?.user ? {id: session.user.id, email: session.user.email} : null; }
  global.familyPassportAuth = Object.freeze({baseUrl, health, signUp, signIn, signOut, getAccessToken, getUser});
})(window);
