import {createHash, randomBytes, timingSafeEqual} from "node:crypto";

const b64url = value => Buffer.from(value).toString("base64url");
const digest = value => createHash("sha256").update(value).digest();
const digestText = value => b64url(digest(value));
const equalDigest = (raw, expected) => {
  const actual = digest(String(raw));
  const wanted = Buffer.from(expected, "base64url");
  return actual.length === wanted.length && timingSafeEqual(actual, wanted);
};
const exactKeys = (value, expected) => {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const actual = Object.keys(value).sort(), wanted = [...expected].sort();
  return actual.length === wanted.length && actual.every((key, index) => key === wanted[index]);
};
const text = (value, name, max = 512) => {
  if (typeof value !== "string" || value.length < 1 || value.length > max || value !== value.trim() || /[\u0000-\u001f\u007f]/.test(value)) throw new Error(`invalid_${name}`);
  return value;
};
const ttl = (value, max) => {
  if (!Number.isSafeInteger(value) || value < 1_000 || value > max) throw new Error("invalid_ttl");
  return value;
};

export const PROVIDERS = Object.freeze({
  google_drive: Object.freeze({
    liveAuthorization: true,
    authorizationHost: "accounts.google.com",
    issuer: "https://accounts.google.com",
    selectionMethod: "google_picker",
    pickerOrigins: Object.freeze(["https://docs.google.com", "https://drive.google.com"]),
    scopes: Object.freeze(["openid", "email", "https://www.googleapis.com/auth/drive.file"]),
    broadScopesForbidden: Object.freeze(["https://www.googleapis.com/auth/drive", "https://www.googleapis.com/auth/drive.readonly"])
  }),
  one_drive: Object.freeze({
    liveAuthorization: false,
    authorizationHost: "login.microsoftonline.com",
    selectionMethod: "onedrive_file_picker_v8",
    pickerOrigins: Object.freeze([]),
    scopes: Object.freeze([]),
    broadScopesForbidden: Object.freeze(["Files.Read.All", "Files.ReadWrite.All"]),
    liveScopeDecision: "disabled_for_live_authorization",
    feasibilityRequired: Object.freeze(["personal_vs_work_account", "sharepoint_vs_graph_audience", "postmessage_origin_and_channel", "selected_file_access_lifetime"])
  })
});

export class AuthorizationTransactionStore {
  #transactions = new Map();
  #exchanges = new Map();
  constructor({clock = () => Date.now(), ttlMs = 5 * 60_000, redirectAllowList, clients, verifyIdToken} = {}) {
    this.clock = clock; this.ttlMs = ttl(ttlMs, 10 * 60_000);
    if (!redirectAllowList || !clients || typeof verifyIdToken !== "function") throw new Error("authorization_policy_required");
    this.redirectAllowList = Object.freeze(Object.fromEntries(Object.entries(redirectAllowList).map(([provider, values]) => [provider, Object.freeze([...values].map(value => {
      const uri = new URL(value);
      if (uri.protocol !== "https:" || uri.username || uri.password || uri.hash) throw new Error("unsafe_redirect_policy");
      return value;
    }))])));
    this.clients = Object.freeze({...clients});
    this.verifyIdToken = verifyIdToken;
  }
  issue({provider, sessionId, redirectUri}) {
    const policy = PROVIDERS[provider];
    if (!policy?.liveAuthorization) throw new Error("provider_live_authorization_disabled");
    text(sessionId, "session_id", 128); text(redirectUri, "redirect_uri", 512);
    if (!this.redirectAllowList[provider]?.includes(redirectUri)) throw new Error("redirect_not_allowed");
    if (!this.clients[provider]) throw new Error("client_not_configured");
    const state = b64url(randomBytes(32)), nonce = b64url(randomBytes(32)), verifier = b64url(randomBytes(48));
    const stateHash = digestText(state);
    this.#transactions.set(stateHash, {provider, sessionId, redirectUri, nonceHash: digestText(nonce), verifier, expiresAt: this.clock() + this.ttlMs, consumed: false});
    return Object.freeze({provider, state, nonce, codeChallenge: b64url(digest(verifier)), codeChallengeMethod: "S256", redirectUri});
  }
  consumeCallback({provider, sessionId, redirectUri, state, code}) {
    text(code, "authorization_code", 2048);
    const stateHash = digestText(text(state, "state", 128)), tx = this.#transactions.get(stateHash);
    if (!tx || tx.consumed || tx.expiresAt <= this.clock()) { this.#transactions.delete(stateHash); throw new Error("invalid_or_expired_transaction"); }
    if (tx.provider !== provider || tx.sessionId !== sessionId || tx.redirectUri !== redirectUri) throw new Error("transaction_binding_mismatch");
    tx.consumed = true; this.#transactions.delete(stateHash);
    const exchangeHandle = b64url(randomBytes(32));
    this.#exchanges.set(digestText(exchangeHandle), {...tx, codeHash: digestText(code), expiresAt: this.clock() + this.ttlMs, consumed: false});
    return Object.freeze({provider, exchangeHandle, code, codeVerifier: tx.verifier, redirectUri});
  }
  verifyTokenExchange({exchangeHandle, code, rawIdToken}) {
    const key = digestText(text(exchangeHandle, "exchange_handle", 128)), tx = this.#exchanges.get(key), policy = tx && PROVIDERS[tx.provider];
    if (!tx || tx.consumed || tx.expiresAt <= this.clock()) { this.#exchanges.delete(key); throw new Error("invalid_or_expired_exchange"); }
    if (!equalDigest(text(code, "authorization_code", 2048), tx.codeHash)) throw new Error("unverified_token_exchange");
    const claims = this.verifyIdToken(rawIdToken, Object.freeze({issuer: policy.issuer, audience: this.clients[tx.provider], nonceHash: tx.nonceHash}));
    if (!exactKeys(claims, ["issuer", "audience", "subject", "providerAccountId", "nonceClaim"])) throw new Error("unverified_token_exchange");
    if (claims.issuer !== policy.issuer || claims.audience !== this.clients[tx.provider]) throw new Error("token_claim_binding_mismatch");
    text(claims.subject, "provider_subject", 256); text(claims.providerAccountId, "provider_account_id", 256);
    if (!equalDigest(text(claims.nonceClaim, "signed_nonce_claim", 128), tx.nonceHash)) throw new Error("nonce_claim_mismatch");
    tx.consumed = true; this.#exchanges.delete(key);
    return Object.freeze({provider: tx.provider, providerSubject: claims.subject, providerAccountId: claims.providerAccountId});
  }
}

export class SelectionGrantStore {
  #grants = new Map();
  #pickerSessions = new Map();
  constructor({clock = () => Date.now(), ttlMs = 2 * 60_000, resolveConnector, verifyPickerMessage, observeProviderFile} = {}) {
    this.clock = clock; this.ttlMs = ttl(ttlMs, 5 * 60_000);
    if (typeof resolveConnector !== "function" || typeof verifyPickerMessage !== "function" || typeof observeProviderFile !== "function") throw new Error("trusted_connector_boundaries_required");
    this.resolveConnector = resolveConnector; this.verifyPickerMessage = verifyPickerMessage; this.observeProviderFile = observeProviderFile;
  }
  issuePickerSession({ownerSubject, connectorId, expectedOrigin, expectedSourceId}) {
    const connector = this.resolveConnector(connectorId);
    if (!connector || connector.ownerSubject !== ownerSubject || connector.enabled !== true || !Number.isSafeInteger(connector.authorizationEpoch) || connector.authorizationEpoch < 1) throw new Error("connector_not_available");
    if (!PROVIDERS[connector.provider]?.pickerOrigins.includes(expectedOrigin)) throw new Error("unverified_picker_origin");
    text(expectedSourceId, "picker_source", 128);
    const session = b64url(randomBytes(32)), channelNonce = b64url(randomBytes(32));
    this.#pickerSessions.set(digestText(session), {ownerSubject, connectorId, authorizationEpoch: connector.authorizationEpoch, expectedOrigin, expectedSourceId, channelNonceHash: digestText(channelNonce), expiresAt: this.clock() + this.ttlMs, consumed: false});
    return Object.freeze({session, channelNonce});
  }
  issueFromVerifiedPickerMessage({session, ownerSubject, connectorId, rawMessage}) {
    const key = digestText(text(session, "picker_session", 128)), pickerSession = this.#pickerSessions.get(key);
    if (!pickerSession || pickerSession.consumed || pickerSession.expiresAt <= this.clock()) { this.#pickerSessions.delete(key); throw new Error("invalid_or_expired_picker_session"); }
    if (pickerSession.ownerSubject !== ownerSubject || pickerSession.connectorId !== connectorId) throw new Error("picker_session_binding_mismatch");
    const connector = this.resolveConnector(connectorId);
    if (!connector || connector.ownerSubject !== ownerSubject || connector.enabled !== true || connector.authorizationEpoch !== pickerSession.authorizationEpoch) throw new Error("connector_not_available");
    const pickerOutput = this.verifyPickerMessage(rawMessage, Object.freeze({expectedOrigin: pickerSession.expectedOrigin, expectedSourceId: pickerSession.expectedSourceId, channelNonceHash: pickerSession.channelNonceHash}));
    const expected = ["providerSubject", "providerAccountId", "fileId", "fileVersion", "mimeType", "selectedAt"];
    if (!exactKeys(pickerOutput, expected)) throw new Error("unverified_picker_message");
    for (const key of expected.filter(key => key !== "selectedAt")) text(pickerOutput[key], key, 512);
    if (pickerOutput.providerSubject !== connector.providerSubject || pickerOutput.providerAccountId !== connector.providerAccountId) throw new Error("picker_account_binding_mismatch");
    if (!Number.isSafeInteger(pickerOutput.selectedAt) || pickerOutput.selectedAt > this.clock() + 30_000 || pickerOutput.selectedAt < this.clock() - this.ttlMs) throw new Error("invalid_selected_at");
    pickerSession.consumed = true; this.#pickerSessions.delete(key);
    const grant = b64url(randomBytes(32));
    this.#grants.set(digestText(grant), {ownerSubject, connectorId, authorizationEpoch: connector.authorizationEpoch, provider: connector.provider, ...pickerOutput, expiresAt: this.clock() + this.ttlMs, consumed: false});
    return grant;
  }
  async redeem({grant, ownerSubject, connectorId}) {
    const key = digestText(text(grant, "selection_grant", 128)), stored = this.#grants.get(key);
    if (!stored || stored.consumed || stored.expiresAt <= this.clock()) { this.#grants.delete(key); throw new Error("invalid_or_expired_selection_grant"); }
    if (stored.ownerSubject !== ownerSubject || stored.connectorId !== connectorId) throw new Error("selection_binding_mismatch");
    const connector = this.resolveConnector(connectorId);
    if (!connector || connector.ownerSubject !== ownerSubject || connector.enabled !== true || connector.authorizationEpoch !== stored.authorizationEpoch) { this.#grants.delete(key); throw new Error("connector_not_available"); }
    const observed = await this.observeProviderFile(Object.freeze({provider: stored.provider, connectorId, authorizationEpoch: stored.authorizationEpoch, fileId: stored.fileId}));
    const rechecked = this.resolveConnector(connectorId);
    if (!rechecked || rechecked.ownerSubject !== ownerSubject || rechecked.enabled !== true || rechecked.authorizationEpoch !== stored.authorizationEpoch) { this.#grants.delete(key); throw new Error("connector_not_available"); }
    if (!exactKeys(observed, ["providerSubject", "providerAccountId", "fileId", "fileVersion"]) || stored.providerSubject !== observed.providerSubject || stored.providerAccountId !== observed.providerAccountId || stored.fileId !== observed.fileId || stored.fileVersion !== observed.fileVersion) throw new Error("selection_binding_mismatch");
    stored.consumed = true; this.#grants.delete(key);
    return Object.freeze({provider: stored.provider, connectorId, fileId: stored.fileId, fileVersion: stored.fileVersion, mimeType: stored.mimeType});
  }
}

export class ConnectorAuthority {
  #records = new Map();
  #lastGeneration = new Map();
  add(connection) {
    if (this.#records.get(connection.id)?.enabled) throw new Error("duplicate_connection_id");
    const generation = (this.#lastGeneration.get(connection.id) || 0) + 1;
    this.#lastGeneration.set(connection.id, generation);
    const record = {...connection, enabled:true, authorizationEpoch:generation};
    this.#records.set(connection.id, record); return Object.freeze({...record});
  }
  get(id) { const record=this.#records.get(id); return record?Object.freeze({...record}):null; }
  disable({id,ownerSubject,expectedEpoch}) {
    const record=this.#records.get(id);
    if(!record||record.ownerSubject!==ownerSubject||record.enabled!==true||record.authorizationEpoch!==expectedEpoch)throw new Error("connector_not_available");
    const generation=(this.#lastGeneration.get(id)||record.authorizationEpoch)+1;this.#lastGeneration.set(id,generation);record.enabled=false;record.authorizationEpoch=generation;return Object.freeze({...record});
  }
}

export class ConnectorLifecycle {
  constructor({revokeProvider,authority=new ConnectorAuthority()}) { if (typeof revokeProvider !== "function" || !(authority instanceof ConnectorAuthority)) throw new Error("connector_dependencies_required"); this.revokeProvider = revokeProvider; this.authority=authority; this.connections = new Map(); this.operations = new Map(); }
  add(connection) {
    const allowed = ["id", "provider", "ownerSubject", "providerSubject", "providerAccountId", "tokenCiphertextRef", "version"];
    if (!exactKeys(connection, allowed) || !PROVIDERS[connection.provider]?.liveAuthorization || !Number.isSafeInteger(connection.version) || connection.version < 1) throw new Error("invalid_connection");
    for (const key of allowed.filter(key => key !== "version")) text(connection[key], key, 512);
    if (this.connections.get(connection.id)?.localEnabled) throw new Error("duplicate_connection_id");
    const authorized=this.authority.add(connection);
    this.connections.set(connection.id, {...connection, authorizationEpoch:authorized.authorizationEpoch, localEnabled: true, revokeState: "active"});
  }
  disconnect({id, ownerSubject, operationId, expectedVersion}) {
    text(operationId, "operation_id", 128);
    const connection = this.connections.get(id);
    if (!connection || connection.ownerSubject !== ownerSubject) return Promise.reject(new Error("connection_not_available"));
    const operationGeneration=connection.authorizationEpoch;
    const opKey = `${id}:${ownerSubject}:${operationGeneration}:${operationId}`;
    if (this.operations.has(opKey)) return this.operations.get(opKey);
    if (connection.revokeState === "provider_revoke_pending" && connection.activeOperation) return connection.activeOperation;
    if (["revoked"].includes(connection.revokeState)) return Promise.resolve(Object.freeze({id, localEnabled: false, revokeState: connection.revokeState, originalsChanged: false, version: connection.version}));
    if (!["active", "provider_revoke_retry_required"].includes(connection.revokeState)) return Promise.reject(new Error("invalid_revoke_state"));
    if (connection.version !== expectedVersion) return Promise.reject(new Error("stale_connection_version"));
    if(connection.revokeState==="active"){const disabled=this.authority.disable({id,ownerSubject,expectedEpoch:connection.authorizationEpoch});connection.authorizationEpoch=disabled.authorizationEpoch;}
    connection.localEnabled = false; connection.revokeState = "provider_revoke_pending"; connection.version += 1;
    const operation = (async () => {
      try { await this.revokeProvider(Object.freeze({provider: connection.provider, tokenCiphertextRef: connection.tokenCiphertextRef})); connection.revokeState = "revoked"; }
      catch { connection.revokeState = "provider_revoke_retry_required"; }
      finally { connection.activeOperation = null; }
      return Object.freeze({id, authorizationEpoch:operationGeneration, localEnabled: false, revokeState: connection.revokeState, originalsChanged: false, version: connection.version});
    })();
    connection.activeOperation = operation; this.operations.set(opKey, operation);
    return operation;
  }
  canUse(id) { return this.connections.get(id)?.localEnabled === true; }
}
