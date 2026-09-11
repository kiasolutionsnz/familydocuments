package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestTelegramWebhookAuthenticatesBeforeParsing(t *testing.T) {
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		jsonReply(w, http.StatusOK, map[string]any{"accepted": true})
	}))
	defer upstream.Close()
	h := newTelegramAPI("https://familydocuments.app", upstream.URL, "test-bot", "FamilyDocumentsTestBot", strings.Repeat("s", 32), "", accessTokenVerifier{secret: []byte("jwt")}, nil)
	for _, secret := range []string{"", "wrong"} {
		req := httptest.NewRequest(http.MethodPost, "/integrations/telegram/webhook", strings.NewReader(`not-json`))
		req.Header.Set("X-Telegram-Bot-Api-Secret-Token", secret)
		response := httptest.NewRecorder()
		h.webhook(response, req)
		if response.Code != http.StatusUnauthorized || calls.Load() != 0 {
			t.Fatalf("invalid secret reached persistence: code=%d calls=%d", response.Code, calls.Load())
		}
	}
}

func TestTelegramWebhookPersistsPrivateUpdatesAndRejectsGroups(t *testing.T) {
	var calls atomic.Int32
	var body map[string]any
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		_ = json.NewDecoder(r.Body).Decode(&body)
		jsonReply(w, http.StatusOK, map[string]any{"accepted": true})
	}))
	defer upstream.Close()
	secret := strings.Repeat("w", 32)
	h := newTelegramAPI("https://familydocuments.app", upstream.URL, "test-bot", "FamilyDocumentsTestBot", secret, "", accessTokenVerifier{secret: []byte("jwt")}, nil)
	private := `{"update_id":42,"message":{"message_id":7,"text":"/help","chat":{"id":123,"type":"private"},"from":{"id":123}}}`
	req := httptest.NewRequest(http.MethodPost, "/integrations/telegram/webhook", strings.NewReader(private))
	req.Header.Set("X-Telegram-Bot-Api-Secret-Token", secret)
	response := httptest.NewRecorder()
	h.webhook(response, req)
	if response.Code != http.StatusOK || calls.Load() != 1 || body["telegram_update_id"] != float64(42) {
		t.Fatalf("private update not durably accepted: code=%d body=%#v", response.Code, body)
	}

	group := strings.Replace(private, `"private"`, `"group"`, 1)
	req = httptest.NewRequest(http.MethodPost, "/integrations/telegram/webhook", strings.NewReader(group))
	req.Header.Set("X-Telegram-Bot-Api-Secret-Token", secret)
	response = httptest.NewRecorder()
	h.webhook(response, req)
	if response.Code != http.StatusUnprocessableEntity || calls.Load() != 1 {
		t.Fatalf("group update was persisted: code=%d calls=%d", response.Code, calls.Load())
	}
}

func TestTelegramWebhookRetainsSafeAttachmentIdentifiers(t *testing.T) {
	var body map[string]any
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&body)
		jsonReply(w, http.StatusOK, map[string]any{"accepted": true})
	}))
	defer upstream.Close()
	secret := strings.Repeat("a", 32)
	h := newTelegramAPI("https://familydocuments.app", upstream.URL, "test-bot", "FamilyDocumentsTestBot", secret, "", accessTokenVerifier{secret: []byte("jwt")}, nil)
	payload := `{"update_id":43,"message":{"message_id":8,"chat":{"id":123,"type":"private"},"from":{"id":123},"document":{"file_id":"opaque-file","file_unique_id":"stable-file","file_name":"synthetic.pdf","mime_type":"application/pdf","file_size":123}}}`
	req := httptest.NewRequest(http.MethodPost, "/integrations/telegram/webhook", strings.NewReader(payload))
	req.Header.Set("X-Telegram-Bot-Api-Secret-Token", secret)
	response := httptest.NewRecorder()
	h.webhook(response, req)
	envelope := body["envelope"].(map[string]any)
	document := envelope["message"].(map[string]any)["document"].(map[string]any)
	if response.Code != http.StatusOK || document["file_unique_id"] != "stable-file" {
		t.Fatalf("safe durable attachment metadata was lost: code=%d document=%#v", response.Code, document)
	}
}

func TestTelegramConnectStoresOnlyHashAndReturnsDeepLink(t *testing.T) {
	var body map[string]any
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&body)
		jsonReply(w, http.StatusOK, map[string]any{"expires_at": time.Now().Add(10 * time.Minute).Format(time.RFC3339)})
	}))
	defer upstream.Close()
	secret := "correct"
	h := newTelegramAPI("https://familydocuments.app", upstream.URL, "test-bot", "FamilyDocumentsTestBot", strings.Repeat("x", 32), "", accessTokenVerifier{secret: []byte(secret), issuer: "supabase", audience: "authenticated"}, nil)
	req := httptest.NewRequest(http.MethodPost, "/integrations/telegram/connect", strings.NewReader(`{"family_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}`))
	req.Header.Set("Authorization", "Bearer "+conversationTestToken(secret, time.Now().Add(time.Hour)))
	response := httptest.NewRecorder()
	h.connect(response, req)
	var result map[string]any
	_ = json.Unmarshal(response.Body.Bytes(), &result)
	if response.Code != http.StatusOK || !strings.HasPrefix(result["deep_link"].(string), "https://t.me/FamilyDocumentsTestBot?start=") {
		t.Fatalf("safe deep link not returned: %d %s", response.Code, response.Body.String())
	}
	hash, ok := body["link_hash"].(string)
	if !ok || len(hash) != 64 || strings.Contains(response.Body.String(), hash) {
		t.Fatal("link token was not stored as a non-returned strong hash")
	}
}

func TestTelegramConfigurationRequiresCompleteSecrets(t *testing.T) {
	if validateTelegramConfiguration("", "", "", "", false) != nil {
		t.Fatal("disabled Telegram configuration should be valid")
	}
	if validateTelegramConfiguration("bot", "FamilyDocumentsTestBot", "short", "", false) == nil {
		t.Fatal("short webhook secret was accepted")
	}
}

func TestTelegramBrowserPreflightDoesNotRequireAuthentication(t *testing.T) {
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
	}))
	defer upstream.Close()
	h := newTelegramAPI("https://familydocuments.app", upstream.URL, "test-bot", "FamilyDocumentsTestBot", strings.Repeat("s", 32), "", accessTokenVerifier{secret: []byte("jwt")}, nil)
	mux := http.NewServeMux()
	h.register(mux)
	for _, path := range []string{"status", "connect", "disconnect"} {
		req := httptest.NewRequest(http.MethodOptions, "/integrations/telegram/"+path, nil)
		req.Header.Set("Origin", "https://familydocuments.app")
		req.Header.Set("Access-Control-Request-Method", http.MethodPost)
		req.Header.Set("Access-Control-Request-Headers", "authorization,content-type")
		response := httptest.NewRecorder()
		mux.ServeHTTP(response, req)
		if response.Code != http.StatusNoContent || response.Header().Get("Access-Control-Allow-Origin") != "https://familydocuments.app" {
			t.Fatalf("%s preflight failed: code=%d headers=%v", path, response.Code, response.Header())
		}
	}
	if calls.Load() != 0 {
		t.Fatalf("preflight reached the upstream RPC: calls=%d", calls.Load())
	}
}

func TestTelegramStatusPassesThroughStableTypedState(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		jsonReply(w, http.StatusOK, map[string]any{"state": "not_connected", "selection_required": false, "family_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "family_name": "Test Family", "display_name": nil, "username": nil, "connected_at": nil, "link_expires_at": nil})
	}))
	defer upstream.Close()
	secret := "correct"
	h := newTelegramAPI("https://familydocuments.app", upstream.URL, "test-bot", "FamilyDocumentsTestBot", strings.Repeat("s", 32), "", accessTokenVerifier{secret: []byte(secret), issuer: "supabase", audience: "authenticated"}, nil)
	req := httptest.NewRequest(http.MethodPost, "/integrations/telegram/status", strings.NewReader(`{}`))
	req.Header.Set("Origin", "https://familydocuments.app")
	req.Header.Set("Authorization", "Bearer "+conversationTestToken(secret, time.Now().Add(time.Hour)))
	response := httptest.NewRecorder()
	h.status(response, req)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"state":"not_connected"`) {
		t.Fatalf("stable status was not returned: code=%d body=%s", response.Code, response.Body.String())
	}
}
