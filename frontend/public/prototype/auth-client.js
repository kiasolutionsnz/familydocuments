(function attachFamilyPassportAuth(global) {
  "use strict";
  const baseUrl = "https://api-familydocuments.servicehub.co.nz/auth";
  const refreshStorageKey = "familydocuments.refresh-token";
  let session = null;
  let refreshPromise = null;
  function storedRefreshToken() { try { return sessionStorage.getItem(refreshStorageKey) || null; } catch { return null; } }
  function persistRefreshToken(value) { try { if (value) sessionStorage.setItem(refreshStorageKey, value); else sessionStorage.removeItem(refreshStorageKey); } catch {} }
  function setSession(body) {
    if (!body?.access_token || !body?.user?.email) throw new Error("Authentication response was incomplete.");
    session = {accessToken: body.access_token, refreshToken: body.refresh_token || session?.refreshToken || storedRefreshToken(), user: body.user};
    persistRefreshToken(session.refreshToken);
    return {user: {id: body.user.id, email: body.user.email}};
  }
  function clearSession() { session = null; persistRefreshToken(null); }
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
  async function googleAvailable(){const response=await fetch(`${baseUrl}/settings`,{headers:{accept:"application/json"}});if(!response.ok)return false;const body=await response.json().catch(()=>({}));return Boolean(body.external?.google)}
  async function signInWithGoogle(){
    if(!await googleAvailable()){const error=new Error("Google sign-in is not configured.");error.code="google_not_configured";throw error}
    const redirect=`${location.origin}/prototype/oauth-callback.html`,popup=window.open(`${baseUrl}/authorize?provider=google&redirect_to=${encodeURIComponent(redirect)}`,"family-passport-google","popup,width=520,height=680");
    if(!popup){const error=new Error("Google sign-in popup was blocked.");error.code="popup_blocked";throw error}
    return new Promise((resolve,reject)=>{const timer=setTimeout(()=>finish(new Error("Google sign-in timed out.")),120000);function finish(error,payload){clearTimeout(timer);window.removeEventListener("message",receive);try{popup.close()}catch{}if(error)reject(error);else resolve(payload)}async function receive(event){if(event.origin!==location.origin||event.source!==popup||event.data?.type!=="family-passport-google-oauth")return;if(event.data.error||!event.data.access_token)return finish(new Error(event.data.error_description||"Google sign-in failed."));try{const response=await request("/user",{headers:{authorization:`Bearer ${event.data.access_token}`}});if(!response.id||!response.email)throw new Error("Google identity response was incomplete.");setSession({access_token:event.data.access_token,refresh_token:event.data.refresh_token,user:response});finish(null,{user:{id:response.id,email:response.email}})}catch(error){finish(error)}}window.addEventListener("message",receive)})
  }
  async function signUp({email, password, name}) {
    return request("/signup", {method: "POST", body: JSON.stringify({email, password, data: name ? {display_name: name} : {}})});
  }
  async function signIn({email, password}) {
    const body = await request("/token?grant_type=password", {method: "POST", body: JSON.stringify({email, password})});
    return setSession(body);
  }
  async function refreshSession() {
    if (refreshPromise) return refreshPromise;
    refreshPromise = (async () => {
      const refreshToken = session?.refreshToken || storedRefreshToken();
      if (!refreshToken) { const error = new Error("No saved session."); error.status = 401; throw error; }
      try {
        const body = await request("/token?grant_type=refresh_token", {method: "POST", body: JSON.stringify({refresh_token: refreshToken})});
        return setSession(body);
      } catch (error) { clearSession(); throw error; }
    })();
    try { return await refreshPromise; } finally { refreshPromise = null; }
  }
  function accessTokenExpiresSoon() {
    try {
      const payload = JSON.parse(atob((session?.accessToken || "").split(".")[1].replaceAll("-", "+").replaceAll("_", "/")));
      return !payload.exp || (payload.exp * 1000) <= Date.now() + 30000;
    } catch { return true; }
  }
  async function authenticatedRequest(path, options = {}, retry = true) {
    if (!session?.accessToken) throw new Error("Sign in is required.");
    if (accessTokenExpiresSoon()) await refreshSession();
    try {
      return await request(path, {...options, headers: {...(options.headers || {}), authorization: `Bearer ${session.accessToken}`}});
    } catch (error) {
      if (retry && [401, 403].includes(error.status) && error.code === "bad_jwt") {
        await refreshSession();
        return authenticatedRequest(path, options, false);
      }
      throw error;
    }
  }
  async function restoreSession() {
    if (!storedRefreshToken()) return null;
    try { return await refreshSession(); } catch { return null; }
  }
  async function signOut() {
    const current = session;
    clearSession();
    if (!current?.accessToken) return;
    try { await request("/logout", {method: "POST", headers: {authorization: `Bearer ${current.accessToken}`}}); } catch {}
  }
  async function signOutAll() {
    const current=session;clearSession();if(!current?.accessToken)return;
    try{await request("/logout?scope=global",{method:"POST",headers:{authorization:`Bearer ${current.accessToken}`}})}catch{}
  }
  async function recover(email) { return request("/recover",{method:"POST",body:JSON.stringify({email})}); }
  async function enrollTotp() {
    const user=await authenticatedRequest("/user"),existing=(user.factors||[]).find(x=>x.factor_type==="totp"&&x.status==="verified");
    if(existing)return {id:existing.id,existing:true,totp:{secret:""}};
    return authenticatedRequest("/factors",{method:"POST",body:JSON.stringify({factor_type:"totp",friendly_name:"Family Documents"})});
  }
  async function verifyTotp(factorId,code) {
    const challenge=await authenticatedRequest(`/factors/${factorId}/challenge`,{method:"POST",body:"{}"});
    const verified=await authenticatedRequest(`/factors/${factorId}/verify`,{method:"POST",body:JSON.stringify({challenge_id:challenge.id,code})});
    if(verified.access_token)setSession({access_token:verified.access_token,refresh_token:verified.refresh_token||session.refreshToken,user:verified.user||session.user});
    return verified;
  }
  function assuranceLevel(){try{return JSON.parse(atob((session?.accessToken||"").split(".")[1].replaceAll("-","+").replaceAll("_","/"))).aal||"aal1"}catch{return "aal1"}}
  function getAccessToken() { return session?.accessToken || null; }
  function getUser() { return session?.user ? {id: session.user.id, email: session.user.email} : null; }
  global.familyPassportAuth = Object.freeze({baseUrl, health, googleAvailable, signInWithGoogle, signUp, signIn, refreshSession, restoreSession, clearSession, signOut, signOutAll, recover, enrollTotp, verifyTotp, assuranceLevel, getAccessToken, getUser});
})(window);
