package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestFeedbackAuthenticatedStrictTransport(t *testing.T) {
	calls := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/rpc/feedback_request" {
			t.Fatal("wrong RPC")
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["operation"] != "list" {
			t.Fatal("wrong shape")
		}
		jsonReply(w, 200, map[string]any{"tickets": []any{}})
	}))
	defer upstream.Close()
	h := newTrustedConversationAPI("https://familydocuments.app", upstream.URL, accessTokenVerifier{secret: []byte("fake"), issuer: "supabase", audience: "authenticated"}, nil, nil)
	mux := http.NewServeMux()
	h.register(mux)
	for _, tc := range []struct {
		method, body, token string
		status              int
	}{
		{"POST", `{"operation":"list"}`, "", 401},
		{"POST", `{"operation":"list"}`, conversationTestToken("wrong", time.Now().Add(time.Hour)), 401},
		{"POST", `{"operation":"list","reporter_id":"forged"}`, conversationTestToken("fake", time.Now().Add(time.Hour)), 400},
		{"POST", `{"operation":"Released"}`, conversationTestToken("fake", time.Now().Add(time.Hour)), 400},
		{"POST", `{"operation":"list"}`, conversationTestToken("fake", time.Now().Add(time.Hour)), 200},
		{"OPTIONS", ``, "", 204},
	} {
		req := httptest.NewRequest(tc.method, "/conversation/feedback", strings.NewReader(tc.body))
		if tc.token != "" {
			req.Header.Set("Authorization", "Bearer "+tc.token)
		}
		out := httptest.NewRecorder()
		mux.ServeHTTP(out, req)
		if out.Code != tc.status {
			t.Fatalf("expected %d got %d", tc.status, out.Code)
		}
	}
	if calls != 1 {
		t.Fatalf("unexpected upstream calls %d", calls)
	}
}
