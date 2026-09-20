package main

import (
	"io"
	"net/http"
)

// Explicit user transport only. Never invoked by model proposals or stored content.
func (h *trustedConversationAPI) feedback(w http.ResponseWriter, r *http.Request) {
	actor, ok := h.prepare(w, r, 12000)
	if !ok {
		return
	}
	var input struct {
		Operation    string  `json:"operation"`
		RequestKey   *string `json:"request_key"`
		Message      *string `json:"message"`
		Ticket       *string `json:"ticket"`
		Conversation *string `json:"conversation"`
		AppVersion   *string `json:"app_version"`
	}
	body, err := io.ReadAll(r.Body)
	if err != nil || decodeStrictJSON(body, &input) != nil || (input.Conversation != nil && !uuidPattern.MatchString(*input.Conversation)) {
		jsonReply(w, 400, map[string]string{"error": "invalid_feedback_request"})
		return
	}
	switch input.Operation {
	case "create", "reply", "list", "detail", "mark_read", "withdraw":
	default:
		jsonReply(w, 400, map[string]string{"error": "invalid_feedback_operation"})
		return
	}
	h.proxyTrustedRPC(w, actor, "feedback_request_v2", input)
}
