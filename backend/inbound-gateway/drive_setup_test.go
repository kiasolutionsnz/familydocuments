package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDriveJSONRejectsUnknownAndTrailingContent(t *testing.T) {
	for _, body := range []string{`{"code":"safe","family_id":"forged"}`, `{"code":"safe"} {}`, `{"code":"safe"} trailing`} {
		var input struct {
			Code string `json:"code"`
		}
		if decodeJSON(httptest.NewRecorder(), httptest.NewRequest("POST", "/drive/connect", strings.NewReader(body)), 4096, &input) == nil {
			t.Fatal("unsafe request accepted")
		}
	}
}

func TestDriveExpectedFamilyIsNotAuthority(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer synthetic" {
			t.Error("actor token not forwarded")
		}
		jsonReply(w, 200, map[string]string{"household_id": "family-b", "user_id": "synthetic-user"})
	}))
	defer server.Close()
	g := &driveGateway{api: server.URL, http: server.Client()}
	request := httptest.NewRequest("POST", "/drive/connect", nil)
	request.Header.Set("Authorization", "Bearer synthetic")
	request.Header.Set("X-Family-Context", "family-a")
	if _, err := g.auth(request, "authorize_google_drive_admin", map[string]any{}); err == nil {
		t.Fatal("stale Family accepted")
	}
	request.Header.Set("X-Family-Context", "family-b")
	if _, err := g.auth(request, "authorize_google_drive_admin", map[string]any{}); err != nil {
		t.Fatal(err)
	}
}

func TestDrivePreflightAllowsContextHeaderOnlyForConfiguredOrigin(t *testing.T) {
	g := &driveGateway{origin: "http://127.0.0.1:3300"}
	for _, origin := range []string{g.origin, "https://untrusted.example"} {
		req := httptest.NewRequest("OPTIONS", "/drive/connect", nil)
		req.Header.Set("Origin", origin)
		out := httptest.NewRecorder()
		g.cors(func(http.ResponseWriter, *http.Request) { t.Error("preflight reached action") })(out, req)
		if origin == g.origin {
			if out.Code != 204 || !strings.Contains(out.Header().Get("Access-Control-Allow-Headers"), "x-family-context") {
				t.Fatal("missing preflight support")
			}
		} else if out.Code != 403 {
			t.Fatal("untrusted origin allowed")
		}
	}
}
