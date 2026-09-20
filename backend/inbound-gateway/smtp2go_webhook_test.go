package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSMTP2GOWebhookRejectsUnsignedRequest(t *testing.T) {
	h, err := newSMTP2GOWebhook("http://example.invalid", strings.Repeat("s", 32), "jwt-secret", nil)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/integrations/smtp2go/events", strings.NewReader(`{"event":"bounce"}`))
	response := httptest.NewRecorder()
	h.handle(response, req)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", response.Code)
	}
}

func TestSMTP2GOWebhookStoresContentMinimisedEvent(t *testing.T) {
	var received map[string]any
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/rpc/record_notification_provider_event" || !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			t.Fatalf("unexpected upstream request")
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		jsonReply(w, http.StatusOK, map[string]any{"recorded": true, "duplicate": false})
	}))
	defer upstream.Close()
	secret := strings.Repeat("s", 32)
	h, err := newSMTP2GOWebhook(upstream.URL, secret, "jwt-secret", upstream.Client())
	if err != nil {
		t.Fatal(err)
	}
	body := `{"event":"bounce","id":"evt-1","rcpt":"member@example.test","message-id":"<fp-11111111-1111-4111-8111-111111111111@familydocuments.app>","bounce":"hard","time":1789852800,"subject":"must not be forwarded","message":"must not be forwarded"}`
	req := httptest.NewRequest(http.MethodPost, "/integrations/smtp2go/events", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+secret)
	response := httptest.NewRecorder()
	h.handle(response, req)
	if response.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", response.Code, response.Body.String())
	}
	if received["event_type"] != "bounce" || received["bounce_type"] != "hard" || received["provider_event_key"] != "evt-1" {
		t.Fatalf("unexpected payload: %#v", received)
	}
	if _, exists := received["subject"]; exists {
		t.Fatal("subject leaked upstream")
	}
	if _, exists := received["message"]; exists {
		t.Fatal("provider error text leaked upstream")
	}
}

func TestSMTP2GOWebhookIgnoresTrackingEvents(t *testing.T) {
	secret := strings.Repeat("s", 32)
	h, err := newSMTP2GOWebhook("http://example.invalid", secret, "jwt-secret", nil)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/integrations/smtp2go/events", strings.NewReader(`{"event":"open","id":"evt-tracking"}`))
	req.Header.Set("Authorization", "Bearer "+secret)
	response := httptest.NewRecorder()
	h.handle(response, req)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"ignored":true`) {
		t.Fatalf("tracking event was not ignored: %d %s", response.Code, response.Body.String())
	}
}
