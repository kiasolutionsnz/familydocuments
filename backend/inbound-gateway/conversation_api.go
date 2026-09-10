package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"
)

type accessIdentity struct {
	UserID string
	Expiry time.Time
}

type accessTokenVerifier struct {
	secret   []byte
	issuer   string
	audience string
	now      func() time.Time
}

func (v accessTokenVerifier) verifyAuthorization(header string) (accessIdentity, error) {
	if !strings.HasPrefix(header, "Bearer ") {
		return accessIdentity{}, errors.New("missing bearer token")
	}
	parts := strings.Split(strings.TrimSpace(strings.TrimPrefix(header, "Bearer ")), ".")
	if len(parts) != 3 {
		return accessIdentity{}, errors.New("malformed token")
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return accessIdentity{}, errors.New("malformed token")
	}
	var tokenHeader struct {
		Algorithm string `json:"alg"`
		Type      string `json:"typ"`
	}
	if decodeStrictJSON(headerBytes, &tokenHeader) != nil || tokenHeader.Algorithm != "HS256" || tokenHeader.Type != "JWT" {
		return accessIdentity{}, errors.New("unsupported token")
	}
	provided, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return accessIdentity{}, errors.New("malformed token")
	}
	mac := hmac.New(sha256.New, v.secret)
	_, _ = mac.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(provided, mac.Sum(nil)) {
		return accessIdentity{}, errors.New("invalid token signature")
	}
	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return accessIdentity{}, errors.New("malformed token")
	}
	var claims struct {
		Subject   string          `json:"sub"`
		Role      string          `json:"role"`
		Issuer    string          `json:"iss"`
		Audience  json.RawMessage `json:"aud"`
		Expiry    int64           `json:"exp"`
		NotBefore int64           `json:"nbf"`
	}
	if decodeStrictJSON(payloadBytes, &claims) != nil || !uuidPattern.MatchString(claims.Subject) || claims.Role != "authenticated" || claims.Issuer != v.issuer || !audienceContains(claims.Audience, v.audience) {
		return accessIdentity{}, errors.New("invalid token claims")
	}
	now := time.Now()
	if v.now != nil {
		now = v.now()
	}
	if claims.Expiry <= now.Unix() || claims.NotBefore > now.Unix()+30 {
		return accessIdentity{}, errors.New("expired token")
	}
	return accessIdentity{UserID: claims.Subject, Expiry: time.Unix(claims.Expiry, 0)}, nil
}

func audienceContains(raw json.RawMessage, expected string) bool {
	var one string
	if json.Unmarshal(raw, &one) == nil {
		return one == expected
	}
	var many []string
	if json.Unmarshal(raw, &many) != nil {
		return false
	}
	for _, value := range many {
		if value == expected {
			return true
		}
	}
	return false
}

func decodeStrictJSON(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return errors.New("trailing JSON content")
	}
	return nil
}

type trustedConversationAPI struct {
	origin      string
	api         string
	client      *http.Client
	verifier    accessTokenVerifier
	proposalKey []byte
}

func newTrustedConversationAPI(origin, api string, verifier accessTokenVerifier, proposalKey []byte, client *http.Client) *trustedConversationAPI {
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	return &trustedConversationAPI{origin: origin, api: strings.TrimRight(api, "/"), verifier: verifier, proposalKey: proposalKey, client: client}
}

func (h *trustedConversationAPI) register(mux *http.ServeMux) {
	mux.HandleFunc("/conversation/action", h.action)
	mux.HandleFunc("/conversation/decision", h.decision)
	mux.HandleFunc("/conversation/attachment", h.attachment)
}

func (h *trustedConversationAPI) prepare(w http.ResponseWriter, r *http.Request, limit int64) (accessIdentity, bool) {
	if !conversationCORS(w, r, h.origin) {
		return accessIdentity{}, false
	}
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return accessIdentity{}, false
	}
	if r.Method != http.MethodPost {
		jsonReply(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
		return accessIdentity{}, false
	}
	identity, err := h.verifier.verifyAuthorization(r.Header.Get("Authorization"))
	if err != nil {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return accessIdentity{}, false
	}
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	return identity, true
}

func conversationCORS(w http.ResponseWriter, r *http.Request, origin string) bool {
	requestOrigin := r.Header.Get("Origin")
	if requestOrigin != "" && requestOrigin != origin {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "origin_denied"})
		return false
	}
	if requestOrigin == origin {
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Add("Vary", "Origin")
		w.Header().Set("Access-Control-Allow-Headers", "authorization, content-type")
		w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	}
	return true
}

type actionEnvelope struct {
	ConversationID string              `json:"conversation_id"`
	RequestKey     string              `json:"request_key"`
	Action         modelActionEnvelope `json:"action"`
	ProposalToken  string              `json:"proposal_token,omitempty"`
}

type modelActionEnvelope struct {
	ID         string         `json:"id"`
	Type       string         `json:"type"`
	Version    int            `json:"version"`
	Parameters map[string]any `json:"parameters"`
}

func (h *trustedConversationAPI) action(w http.ResponseWriter, r *http.Request) {
	identity, ok := h.prepare(w, r, 16*1024)
	if !ok {
		return
	}
	var input actionEnvelope
	if decodeRequestStrict(r.Body, &input) != nil || !uuidPattern.MatchString(input.ConversationID) || !safeActionID.MatchString(input.RequestKey) || input.Action.Version != 1 || !safeActionID.MatchString(input.Action.ID) {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	proposal := modelProposal{Type: input.Action.Type, Parameters: input.Action.Parameters}
	if !validateServerAction(proposal) {
		jsonReply(w, http.StatusUnprocessableEntity, map[string]string{"error": "action_rejected"})
		return
	}
	modelDerived := false
	if input.ProposalToken != "" {
		if !verifyProposalToken(input.ProposalToken, identity.UserID, input.Action, h.proposalKey, time.Now()) {
			jsonReply(w, http.StatusUnprocessableEntity, map[string]string{"error": "action_rejected"})
			return
		}
		modelDerived = true
	}
	payload := map[string]any{"conversation": input.ConversationID, "action_id": input.Action.ID, "action_type": input.Action.Type, "action_version": input.Action.Version, "parameters": input.Action.Parameters, "request_key": input.RequestKey, "model_derived": modelDerived}
	h.proxyTrustedRPC(w, identity, "submit_conversation_action", payload)
}

func (h *trustedConversationAPI) decision(w http.ResponseWriter, r *http.Request) {
	identity, ok := h.prepare(w, r, 2048)
	if !ok {
		return
	}
	var input struct {
		ConfirmationID string `json:"confirmation_id"`
		Decision       string `json:"decision"`
	}
	if decodeRequestStrict(r.Body, &input) != nil || !uuidPattern.MatchString(input.ConfirmationID) || (input.Decision != "confirm" && input.Decision != "cancel") {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	h.proxyTrustedRPC(w, identity, "decide_conversation_confirmation", map[string]any{"confirmation": input.ConfirmationID, "decision": input.Decision})
}

func (h *trustedConversationAPI) attachment(w http.ResponseWriter, r *http.Request) {
	identity, ok := h.prepare(w, r, 8*1024*1024)
	if !ok {
		return
	}
	var input struct {
		ConversationID string `json:"conversation_id"`
		FileName       string `json:"file_name"`
		MimeType       string `json:"mime_type"`
		ContentBase64  string `json:"content_base64"`
	}
	if decodeRequestStrict(r.Body, &input) != nil || !uuidPattern.MatchString(input.ConversationID) || len(input.FileName) < 1 || len(input.FileName) > 255 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	h.proxyTrustedRPC(w, identity, "stage_conversation_attachment", map[string]any{"conversation": input.ConversationID, "file_name": input.FileName, "source_mime_type": input.MimeType, "content_base64": input.ContentBase64})
}

func decodeRequestStrict(reader io.Reader, target any) error {
	decoder := json.NewDecoder(reader)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return errors.New("trailing JSON content")
	}
	return nil
}

func decodeJSONEOF(reader io.Reader, target any) error {
	decoder := json.NewDecoder(reader)
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return errors.New("trailing JSON content")
	}
	return nil
}

func (h *trustedConversationAPI) proxyTrustedRPC(w http.ResponseWriter, identity accessIdentity, name string, payload any) {
	encoded, _ := json.Marshal(payload)
	req, _ := http.NewRequest(http.MethodPost, h.api+"/rpc/"+name, bytes.NewReader(encoded))
	req.Header.Set("Authorization", h.internalAuthorization(identity))
	req.Header.Set("Content-Type", "application/json")
	resp, err := h.client.Do(req)
	if err != nil {
		jsonReply(w, http.StatusBadGateway, map[string]string{"error": "service_unavailable"})
		return
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		jsonReply(w, http.StatusBadGateway, map[string]string{"error": "service_unavailable"})
		return
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		status := http.StatusUnprocessableEntity
		if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
			status = resp.StatusCode
		}
		jsonReply(w, status, map[string]string{"error": "action_rejected"})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func (h *trustedConversationAPI) internalAuthorization(identity accessIdentity) string {
	return internalServiceAuthorization(h.verifier, identity)
}

func internalServiceAuthorization(verifier accessTokenVerifier, identity accessIdentity) string {
	now := time.Now()
	if verifier.now != nil {
		now = verifier.now()
	}
	expires := now.Add(time.Minute)
	if identity.Expiry.Before(expires) {
		expires = identity.Expiry
	}
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{
		"sub": identity.UserID, "role": "service_role", "iss": verifier.issuer,
		"aud": verifier.audience, "iat": now.Unix(), "nbf": now.Add(-5 * time.Second).Unix(),
		"exp": expires.Unix(),
	})
	payload := base64.RawURLEncoding.EncodeToString(claims)
	unsigned := header + "." + payload
	mac := hmac.New(sha256.New, verifier.secret)
	_, _ = mac.Write([]byte(unsigned))
	return "Bearer " + unsigned + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func validateServerAction(proposal modelProposal) bool {
	context := interpreterContext{HasAttachment: true}
	if value, ok := proposal.Parameters["attachment_id"].(string); ok {
		context.AttachmentID = value
	}
	for key, kind := range map[string]string{"document_id": "document", "reminder_id": "reminder", "inbox_id": "inbox"} {
		if value, ok := proposal.Parameters[key].(string); ok {
			context.References = append(context.References, interpreterReference{Type: kind, ID: value, Label: "Server validated target"})
		}
	}
	message, _ := proposal.Parameters["url"].(string)
	return validateModelProposal(proposal, context, message)
}

type proposalClaims struct {
	Subject string              `json:"sub"`
	Action  modelActionEnvelope `json:"action"`
	Expiry  int64               `json:"exp"`
}

func signProposalToken(subject string, action modelActionEnvelope, key []byte, expires time.Time) string {
	payload, _ := json.Marshal(proposalClaims{Subject: subject, Action: action, Expiry: expires.Unix()})
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(encoded))
	return encoded + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func verifyProposalToken(token, subject string, action modelActionEnvelope, key []byte, now time.Time) bool {
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return false
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(parts[0]))
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return false
	}
	var claims proposalClaims
	if decodeStrictJSON(payload, &claims) != nil || claims.Subject != subject || claims.Expiry <= now.Unix() {
		return false
	}
	want, _ := json.Marshal(claims.Action)
	got, _ := json.Marshal(action)
	return hmac.Equal(want, got)
}
