package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDriveCredentialEncryptionAndDeleteReceipt(t *testing.T) {
	g := &driveGateway{key: bytes.Repeat([]byte{7}, 32)}
	ciphertext, nonce, err := g.encrypt("synthetic-refresh-token")
	if err != nil || ciphertext == "synthetic-refresh-token" {
		t.Fatalf("encryption failed: %v", err)
	}
	plain, err := g.decrypt(ciphertext, nonce)
	if err != nil || plain != "synthetic-refresh-token" {
		t.Fatalf("decryption failed: %v", err)
	}
	receipt := g.deleteReceipt("user-1", "file-1234567890", time.Now().Add(time.Minute).Unix())
	if !g.validDeleteReceipt(receipt, "user-1", "file-1234567890") {
		t.Fatal("valid receipt rejected")
	}
	if g.validDeleteReceipt(receipt, "user-2", "file-1234567890") || g.validDeleteReceipt(receipt, "user-1", "other-file-1234567890") {
		t.Fatal("receipt was not bound to user and file")
	}
}

func TestDriveGatewayDisabledWithoutAllSecrets(t *testing.T) {
	t.Setenv("GOOGLE_DRIVE_CLIENT_ID", "configured-client")
	t.Setenv("GOOGLE_DRIVE_CLIENT_SECRET", "")
	t.Setenv("GOOGLE_DRIVE_TOKEN_KEY", "")
	g, err := newDriveGateway("http://127.0.0.1", "https://familydocuments.app", "jwt-secret")
	if err != nil || g != nil {
		t.Fatalf("partial configuration should safely disable gateway: %v", err)
	}
}

func TestDriveGatewayHandlesBrowserPreflight(t *testing.T) {
	g := &driveGateway{origin: "https://familydocuments.app"}
	mux := http.NewServeMux()
	g.register(mux)

	req := httptest.NewRequest(http.MethodOptions, "/drive/connect", nil)
	req.Header.Set("Origin", "https://familydocuments.app")
	req.Header.Set("Access-Control-Request-Method", http.MethodPost)
	req.Header.Set("Access-Control-Request-Headers", "authorization,content-type,x-requested-with")
	res := httptest.NewRecorder()
	mux.ServeHTTP(res, req)

	if res.Code != http.StatusNoContent {
		t.Fatalf("preflight status %d: %s", res.Code, res.Body.String())
	}
	if got := res.Header().Get("Access-Control-Allow-Origin"); got != "https://familydocuments.app" {
		t.Fatalf("unexpected allow origin %q", got)
	}
	if got := res.Header().Get("Access-Control-Allow-Headers"); !strings.Contains(got, "x-requested-with") {
		t.Fatalf("missing CSRF header in preflight response: %q", got)
	}

	wrongOrigin := httptest.NewRequest(http.MethodOptions, "/drive/connect", nil)
	wrongOrigin.Header.Set("Origin", "https://attacker.invalid")
	wrongOriginResult := httptest.NewRecorder()
	mux.ServeHTTP(wrongOriginResult, wrongOrigin)
	if wrongOriginResult.Code != http.StatusForbidden {
		t.Fatalf("wrong-origin preflight status %d", wrongOriginResult.Code)
	}
}

func TestSearchHandlerUsesAuthorisedRPCResults(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/rpc/search_household_records" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer user-token" {
			t.Fatal("authorization was not forwarded")
		}
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`[{"id":"record-1","title":"Home insurance"}]`))
	}))
	defer upstream.Close()

	req := httptest.NewRequest(http.MethodPost, "/search/ask", strings.NewReader(`{"query":"insurance"}`))
	req.Header.Set("Origin", "https://familydocuments.app")
	req.Header.Set("Authorization", "Bearer user-token")
	res := httptest.NewRecorder()
	searchHandler(upstream.URL, "https://familydocuments.app")(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("status %d: %s", res.Code, res.Body.String())
	}
	var body struct {
		Sources []map[string]any `json:"sources"`
		Mode    string           `json:"mode"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Sources) != 1 || body.Mode != "deterministic" {
		t.Fatalf("unexpected body: %s", res.Body.String())
	}
	if res.Header().Get("Access-Control-Allow-Origin") != "https://familydocuments.app" {
		t.Fatal("production CORS origin missing")
	}
}

func TestSearchHandlerRejectsWrongOriginAndMissingAuth(t *testing.T) {
	handler := searchHandler("http://127.0.0.1:1", "https://familydocuments.app")
	wrongOrigin := httptest.NewRequest(http.MethodPost, "/search/ask", strings.NewReader(`{"query":"insurance"}`))
	wrongOrigin.Header.Set("Origin", "https://attacker.invalid")
	wrongOrigin.Header.Set("Authorization", "Bearer token")
	wrongOriginResult := httptest.NewRecorder()
	handler(wrongOriginResult, wrongOrigin)
	if wrongOriginResult.Code != http.StatusForbidden {
		t.Fatalf("wrong-origin status %d", wrongOriginResult.Code)
	}

	missingAuth := httptest.NewRequest(http.MethodPost, "/search/ask", strings.NewReader(`{"query":"insurance"}`))
	missingAuth.Header.Set("Origin", "https://familydocuments.app")
	missingAuthResult := httptest.NewRecorder()
	handler(missingAuthResult, missingAuth)
	if missingAuthResult.Code != http.StatusUnauthorized {
		t.Fatalf("missing-auth status %d", missingAuthResult.Code)
	}
}
