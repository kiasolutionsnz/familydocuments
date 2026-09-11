package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestAccessTokenVerifierRejectsMalformedForgedAndExpiredTokens(t *testing.T) {
	verifier := accessTokenVerifier{secret: []byte("correct-secret"), issuer: "supabase", audience: "authenticated", now: func() time.Time { return time.Unix(2_000, 0) }}
	for name, token := range map[string]string{
		"malformed": "not-a-jwt",
		"forged":    conversationTestToken("wrong-secret", time.Unix(3_000, 0)),
		"expired":   conversationTestToken("correct-secret", time.Unix(1_999, 0)),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := verifier.verifyAuthorization("Bearer " + token); err == nil {
				t.Fatal("invalid access token was accepted")
			}
		})
	}
}

func TestInterpreterRejectsInvalidJWTBeforeRateLimitOrModel(t *testing.T) {
	var upstreamCalls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { upstreamCalls.Add(1) }))
	defer upstream.Close()
	verifier := accessTokenVerifier{secret: []byte("correct"), issuer: "supabase", audience: "authenticated"}
	handler := newConversationInterpreter("https://familydocuments.app", upstream.URL, "qwen3:4b", upstream.URL, verifier, []byte("proposal"), nil)
	req := httptest.NewRequest(http.MethodPost, "/conversation/interpret", strings.NewReader(`{"message":"find passport","context":{"has_attachment":false,"references":[]}}`))
	req.Header.Set("Authorization", "Bearer "+conversationTestToken("forged", time.Now().Add(time.Hour)))
	req.Header.Set("CF-Connecting-IP", "203.0.113.22")
	response := httptest.NewRecorder()
	handler(response, req)
	if response.Code != http.StatusUnauthorized || upstreamCalls.Load() != 0 {
		t.Fatalf("unauthenticated request reached an upstream: code=%d calls=%d", response.Code, upstreamCalls.Load())
	}
}

func TestInterpreterUsesSharedUserFamilyRateLimitAndIgnoresForwardedSpoofing(t *testing.T) {
	var modelCalls atomic.Int32
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("CF-Connecting-IP") != "" {
			t.Fatal("untrusted forwarded header was propagated")
		}
		jsonReply(w, http.StatusOK, map[string]any{"allowed": false, "family_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"})
	}))
	defer api.Close()
	model := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { modelCalls.Add(1) }))
	defer model.Close()
	secret := "correct"
	verifier := accessTokenVerifier{secret: []byte(secret), issuer: "supabase", audience: "authenticated"}
	handler := newConversationInterpreter("https://familydocuments.app", model.URL, "qwen3:4b", api.URL, verifier, []byte(secret), nil)
	req := httptest.NewRequest(http.MethodPost, "/conversation/interpret", strings.NewReader(`{"message":"find passport","context":{"has_attachment":false,"references":[]}}`))
	req.Header.Set("Authorization", "Bearer "+conversationTestToken(secret, time.Now().Add(time.Hour)))
	req.Header.Set("CF-Connecting-IP", "198.51.100.99")
	response := httptest.NewRecorder()
	handler(response, req)
	if response.Code != http.StatusTooManyRequests || modelCalls.Load() != 0 {
		t.Fatalf("rate-limited request reached model: code=%d calls=%d", response.Code, modelCalls.Load())
	}
}

func TestConversationActionStrictEnvelopeAndProposalBinding(t *testing.T) {
	var bodiesMu sync.Mutex
	var bodies []map[string]any
	var upstreamAuthorization string
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstreamAuthorization = r.Header.Get("Authorization")
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		bodiesMu.Lock()
		bodies = append(bodies, body)
		bodiesMu.Unlock()
		jsonReply(w, http.StatusOK, map[string]any{"execution_id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "state": "awaiting_confirmation", "action_type": "save_link", "result": map[string]any{}})
	}))
	defer api.Close()
	secret := "correct"
	verifier := accessTokenVerifier{secret: []byte(secret), issuer: "supabase", audience: "authenticated"}
	service := newTrustedConversationAPI("https://familydocuments.app", api.URL, verifier, []byte(secret), nil)
	action := modelActionEnvelope{ID: "proposal-action-0001", Type: "save_link", Version: 1, Parameters: map[string]any{"url": "https://example.com/path", "category_name": "Travel"}}
	token := signProposalToken(testConversationUser, action, true, []byte(secret), time.Now().Add(time.Minute))
	body, _ := json.Marshal(actionEnvelope{ConversationID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", RequestKey: "action-request-0001", Action: action, ProposalToken: token})
	req := httptest.NewRequest(http.MethodPost, "/conversation/action", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+conversationTestToken(secret, time.Now().Add(time.Hour)))
	response := httptest.NewRecorder()
	service.action(response, req)
	if response.Code != http.StatusOK || len(bodies) != 1 || bodies[0]["model_derived"] != true {
		t.Fatalf("bound model proposal was not submitted authoritatively: %d %#v", response.Code, bodies)
	}
	if upstreamAuthorization == req.Header.Get("Authorization") {
		t.Fatalf("trusted RPC did not use a short-lived user-bound internal token")
	}
	parts := strings.Split(strings.TrimPrefix(upstreamAuthorization, "Bearer "), ".")
	if len(parts) != 3 {
		t.Fatalf("trusted RPC token was malformed")
	}
	payload, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var claims map[string]any
	_ = json.Unmarshal(payload, &claims)
	provided, _ := base64.RawURLEncoding.DecodeString(parts[2])
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(parts[0] + "." + parts[1]))
	if claims["sub"] != testConversationUser || claims["role"] != "service_role" || !hmac.Equal(provided, mac.Sum(nil)) {
		t.Fatalf("trusted RPC token did not use the service-only database role")
	}
	if _, err := verifier.verifyAuthorization(upstreamAuthorization); err == nil {
		t.Fatalf("internal service-role token was accepted as a public access token")
	}

	action.Parameters["category_name"] = "Finance"
	tampered, _ := json.Marshal(actionEnvelope{ConversationID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", RequestKey: "action-request-0002", Action: action, ProposalToken: token})
	req = httptest.NewRequest(http.MethodPost, "/conversation/action", bytes.NewReader(tampered))
	req.Header.Set("Authorization", "Bearer "+conversationTestToken(secret, time.Now().Add(time.Hour)))
	response = httptest.NewRecorder()
	service.action(response, req)
	if response.Code != http.StatusUnprocessableEntity || len(bodies) != 1 {
		t.Fatalf("proposal substitution reached backend: %d %#v", response.Code, bodies)
	}
}

func TestProposalTokenPreservesTrustedInterpretationSource(t *testing.T) {
	action := modelActionEnvelope{ID: "deterministic-action-0001", Type: "save_document", Version: 1, Parameters: map[string]any{"attachment_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "category_name": "Rental records"}}
	key := []byte("proposal-source-test")
	for _, expected := range []bool{false, true} {
		token := signProposalToken(testConversationUser, action, expected, key, time.Now().Add(time.Minute))
		valid, derived := verifyProposalToken(token, testConversationUser, action, key, time.Now())
		if !valid || derived != expected {
			t.Fatalf("proposal source was not preserved: valid=%v derived=%v expected=%v", valid, derived, expected)
		}
	}
}

func TestConversationActionRejectsTrailingJSONAndUnsafeURL(t *testing.T) {
	secret := "correct"
	verifier := accessTokenVerifier{secret: []byte(secret), issuer: "supabase", audience: "authenticated"}
	service := newTrustedConversationAPI("https://familydocuments.app", "http://unused", verifier, []byte(secret), nil)
	for _, body := range []string{
		`{"conversation_id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","request_key":"action-request-0001","action":{"id":"proposal-action-0001","type":"save_link","version":1,"parameters":{"url":"https://user:pass@example.com","category_name":"Travel"}}}`,
		`{"conversation_id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","request_key":"action-request-0001","action":{"id":"proposal-action-0001","type":"unsupported_request","version":1,"parameters":{}}} {}`,
	} {
		req := httptest.NewRequest(http.MethodPost, "/conversation/action", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+conversationTestToken(secret, time.Now().Add(time.Hour)))
		response := httptest.NewRecorder()
		service.action(response, req)
		if response.Code < 400 {
			t.Fatalf("unsafe request was accepted: %s", body)
		}
	}
}

func TestReminderQueryUsesDedicatedAuthoritativeRPC(t *testing.T) {
	var path string
	var body map[string]any
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&body)
		jsonReply(w, http.StatusOK, map[string]any{"execution_id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "state": "succeeded", "action_type": "query_reminders", "result": map[string]any{"results": []any{}}})
	}))
	defer api.Close()
	secret := "correct"
	service := newTrustedConversationAPI("https://familydocuments.app", api.URL, accessTokenVerifier{secret: []byte(secret), issuer: "supabase", audience: "authenticated"}, []byte(secret), nil)
	action := modelActionEnvelope{ID: "reminder-query-0001", Type: "query_reminders", Version: 1, Parameters: map[string]any{"scope": "today"}}
	encoded, _ := json.Marshal(actionEnvelope{ConversationID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", RequestKey: "reminder-query-request-0001", Action: action})
	req := httptest.NewRequest(http.MethodPost, "/conversation/action", bytes.NewReader(encoded))
	req.Header.Set("Authorization", "Bearer "+conversationTestToken(secret, time.Now().Add(time.Hour)))
	response := httptest.NewRecorder()
	service.action(response, req)
	if response.Code != http.StatusOK || path != "/rpc/submit_conversation_reminder_query" || body["action_type"] != nil || body["model_derived"] != nil {
		t.Fatalf("reminder query did not use its strict RPC: code=%d path=%s body=%#v", response.Code, path, body)
	}
}

func TestClarificationDecisionSendsOnlyOpaqueIdentifiers(t *testing.T) {
	var body map[string]any
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&body)
		jsonReply(w, http.StatusOK, map[string]any{"execution_id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "state": "succeeded", "action_type": "query_reminders", "result": map[string]any{}})
	}))
	defer api.Close()
	secret := "correct"
	service := newTrustedConversationAPI("https://familydocuments.app", api.URL, accessTokenVerifier{secret: []byte(secret), issuer: "supabase", audience: "authenticated"}, []byte(secret), nil)
	req := httptest.NewRequest(http.MethodPost, "/conversation/clarification", strings.NewReader(`{"clarification_id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","decision":"select","option_id":"option-reminders-1234"}`))
	req.Header.Set("Authorization", "Bearer "+conversationTestToken(secret, time.Now().Add(time.Hour)))
	response := httptest.NewRecorder()
	service.clarification(response, req)
	if response.Code != http.StatusOK || body["clarification"] == nil || body["option_id"] != "option-reminders-1234" || body["action"] != nil {
		t.Fatalf("clarification decision was not opaque: code=%d body=%#v", response.Code, body)
	}
}

func TestTrustedGatewayAddsVisibleOptionsToEmptyClarification(t *testing.T) {
	action := modelActionEnvelope{ID: "clarification-action-0001", Type: "request_clarification", Version: 1, Parameters: map[string]any{"question": "What would you like me to do?", "missing_parameter": "intent"}}
	addTrustedClarificationOptions(&action)
	choices, choicesOK := action.Parameters["choices"].([]any)
	actions, actionsOK := action.Parameters["choice_actions"].([]any)
	if !choicesOK || !actionsOK || len(choices) != 2 || choices[0] != "Open Reminders" || len(actions) != 2 || !validateServerAction(modelProposal{Type: action.Type, Parameters: action.Parameters}) {
		t.Fatalf("trusted clarification options were not valid: %#v", action.Parameters)
	}
}
