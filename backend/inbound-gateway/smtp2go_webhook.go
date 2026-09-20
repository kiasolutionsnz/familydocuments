package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type smtp2goWebhook struct {
	api       string
	secret    string
	jwtSecret string
	client    *http.Client
}

func newSMTP2GOWebhook(api, secret, jwtSecret string, client *http.Client) (*smtp2goWebhook, error) {
	secret = strings.TrimSpace(secret)
	if secret == "" {
		return nil, nil
	}
	if len(secret) < 32 {
		return nil, fmt.Errorf("SMTP2GO webhook token must contain at least 32 characters")
	}
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	return &smtp2goWebhook{api: strings.TrimRight(api, "/"), secret: secret, jwtSecret: jwtSecret, client: client}, nil
}

func (h *smtp2goWebhook) register(mux *http.ServeMux) {
	mux.HandleFunc("POST /integrations/smtp2go/events", h.handle)
}

func (h *smtp2goWebhook) handle(w http.ResponseWriter, r *http.Request) {
	provided := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if len(provided) != len(h.secret) || subtle.ConstantTimeCompare([]byte(provided), []byte(h.secret)) != 1 {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	var event map[string]any
	decoder := json.NewDecoder(r.Body)
	if err := decoder.Decode(&event); err != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_event"})
		return
	}
	eventType := strings.ToLower(strings.TrimSpace(smtp2goStringValue(event["event"])))
	if eventType == "processed" || eventType == "open" || eventType == "click" {
		jsonReply(w, http.StatusOK, map[string]any{"accepted": true, "ignored": true})
		return
	}
	payload := map[string]any{
		"provider_event_key": strings.TrimSpace(smtp2goStringValue(event["id"])),
		"event_type":         eventType,
		"recipient":          strings.TrimSpace(smtp2goStringValue(event["rcpt"])),
		"message_id":         strings.TrimSpace(smtp2goStringValue(event["message-id"])),
		"bounce_type":        nullableString(event["bounce"]),
		"occurred_at":        smtp2goEventTime(event["time"]),
	}
	encoded, _ := json.Marshal(payload)
	req, _ := http.NewRequest(http.MethodPost, h.api+"/rpc/record_notification_provider_event", bytes.NewReader(encoded))
	req.Header.Set("Authorization", "Bearer "+jwt(h.jwtSecret))
	req.Header.Set("Content-Type", "application/json")
	resp, err := h.client.Do(req)
	if err != nil {
		jsonReply(w, http.StatusBadGateway, map[string]string{"error": "event_store_unavailable"})
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		jsonReply(w, http.StatusBadGateway, map[string]string{"error": "event_store_failed"})
		return
	}
	var result map[string]any
	if json.Unmarshal(body, &result) != nil {
		jsonReply(w, http.StatusBadGateway, map[string]string{"error": "event_store_failed"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"accepted": true, "recorded": result["recorded"], "duplicate": result["duplicate"]})
}

func smtp2goStringValue(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case json.Number:
		return typed.String()
	case float64:
		return strings.TrimSuffix(strings.TrimSuffix(time.Unix(int64(typed), 0).UTC().Format(time.RFC3339Nano), "Z"), ".000000000")
	default:
		return ""
	}
}

func nullableString(value any) any {
	text := strings.ToLower(strings.TrimSpace(smtp2goStringValue(value)))
	if text == "" {
		return nil
	}
	return text
}

func smtp2goEventTime(value any) string {
	switch typed := value.(type) {
	case float64:
		return time.Unix(int64(typed), 0).UTC().Format(time.RFC3339)
	case json.Number:
		if seconds, err := typed.Int64(); err == nil {
			return time.Unix(seconds, 0).UTC().Format(time.RFC3339)
		}
	case string:
		if parsed, err := time.Parse(time.RFC3339, typed); err == nil {
			return parsed.UTC().Format(time.RFC3339)
		}
	}
	return time.Now().UTC().Format(time.RFC3339)
}
