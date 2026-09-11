package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const telegramWebhookLimit = 128 * 1024

var telegramBotUsernamePattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{4,31}$`)

type telegramAPI struct {
	origin        string
	api           string
	botIdentity   string
	botUsername   string
	deepLinkBase  string
	webhookSecret string
	verifier      accessTokenVerifier
	client        *http.Client
}

func newTelegramAPI(origin, api, botIdentity, botUsername, webhookSecret, deepLinkBase string, verifier accessTokenVerifier, client *http.Client) *telegramAPI {
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	if deepLinkBase == "" {
		deepLinkBase = "https://t.me/" + botUsername
	}
	return &telegramAPI{origin: origin, api: strings.TrimRight(api, "/"), botIdentity: botIdentity, botUsername: botUsername, deepLinkBase: deepLinkBase, webhookSecret: webhookSecret, verifier: verifier, client: client}
}

func (h *telegramAPI) register(mux *http.ServeMux) {
	mux.HandleFunc("OPTIONS /integrations/telegram/status", h.status)
	mux.HandleFunc("POST /integrations/telegram/status", h.status)
	mux.HandleFunc("OPTIONS /integrations/telegram/connect", h.connect)
	mux.HandleFunc("POST /integrations/telegram/connect", h.connect)
	mux.HandleFunc("OPTIONS /integrations/telegram/disconnect", h.disconnect)
	mux.HandleFunc("POST /integrations/telegram/disconnect", h.disconnect)
	mux.HandleFunc("POST /integrations/telegram/webhook", h.webhook)
}

func (h *telegramAPI) authenticated(w http.ResponseWriter, r *http.Request, limit int64) (accessIdentity, bool) {
	if !conversationCORS(w, r, h.origin) {
		return accessIdentity{}, false
	}
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
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

func (h *telegramAPI) rpc(identity accessIdentity, name string, body any) ([]byte, int, error) {
	encoded, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.api+"/rpc/"+name, bytes.NewReader(encoded))
	req.Header.Set("authorization", internalServiceAuthorization(h.verifier, identity))
	req.Header.Set("content-type", "application/json")
	response, err := h.client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 128*1024))
	return data, response.StatusCode, err
}

func (h *telegramAPI) serviceRPC(name string, body any) ([]byte, int, error) {
	encoded, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.api+"/rpc/"+name, bytes.NewReader(encoded))
	req.Header.Set("authorization", "Bearer "+jwt(string(h.verifier.secret)))
	req.Header.Set("content-type", "application/json")
	response, err := h.client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 128*1024))
	return data, response.StatusCode, err
}

func (h *telegramAPI) status(w http.ResponseWriter, r *http.Request) {
	identity, ok := h.authenticated(w, r, 1024)
	if !ok {
		return
	}
	data, status, err := h.rpc(identity, "telegram_connection_status", map[string]any{})
	if err != nil || status < 200 || status >= 300 {
		jsonReply(w, http.StatusBadGateway, map[string]string{"error": "integration_unavailable"})
		return
	}
	w.Header().Set("content-type", "application/json")
	w.Header().Set("cache-control", "no-store")
	_, _ = w.Write(data)
}

func (h *telegramAPI) connect(w http.ResponseWriter, r *http.Request) {
	identity, ok := h.authenticated(w, r, 2048)
	if !ok {
		return
	}
	var input struct {
		FamilyID string `json:"family_id"`
	}
	if decodeRequestStrict(r.Body, &input) != nil || !uuidPattern.MatchString(input.FamilyID) || !telegramBotUsernamePattern.MatchString(h.botUsername) {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "integration_unavailable"})
		return
	}
	token := strings.TrimRight(base64URL(raw), "=")
	digest := sha256.Sum256([]byte(token))
	data, status, err := h.rpc(identity, "create_telegram_link_token", map[string]any{"family": input.FamilyID, "bot_identity": h.botIdentity, "link_hash": hex.EncodeToString(digest[:])})
	if err != nil || status < 200 || status >= 300 {
		jsonReply(w, http.StatusUnprocessableEntity, map[string]string{"error": "connection_not_available"})
		return
	}
	var result struct {
		ExpiresAt string `json:"expires_at"`
	}
	if json.Unmarshal(data, &result) != nil {
		jsonReply(w, http.StatusBadGateway, map[string]string{"error": "integration_unavailable"})
		return
	}
	deepLinkURL, err := url.Parse(h.deepLinkBase)
	if err != nil || deepLinkURL.Host == "" {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "integration_unavailable"})
		return
	}
	query := deepLinkURL.Query()
	query.Set("start", token)
	deepLinkURL.RawQuery = query.Encode()
	deepLink := deepLinkURL.String()
	jsonReply(w, http.StatusOK, map[string]any{"deep_link": deepLink, "expires_at": result.ExpiresAt, "bot_username": h.botUsername})
}

func base64URL(value []byte) string {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	result := make([]byte, 0, (len(value)*4+2)/3)
	var acc uint32
	bits := 0
	for _, b := range value {
		acc = (acc << 8) | uint32(b)
		bits += 8
		for bits >= 6 {
			bits -= 6
			result = append(result, alphabet[(acc>>bits)&63])
		}
	}
	if bits > 0 {
		result = append(result, alphabet[(acc<<(6-bits))&63])
	}
	return string(result)
}

func (h *telegramAPI) disconnect(w http.ResponseWriter, r *http.Request) {
	identity, ok := h.authenticated(w, r, 2048)
	if !ok {
		return
	}
	var input struct {
		FamilyID string `json:"family_id"`
		Confirm  bool   `json:"confirm"`
	}
	if decodeRequestStrict(r.Body, &input) != nil || !input.Confirm || !uuidPattern.MatchString(input.FamilyID) {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "confirmation_required"})
		return
	}
	data, status, err := h.rpc(identity, "disconnect_telegram", map[string]any{"family": input.FamilyID, "bot_identity": h.botIdentity})
	if err != nil || status < 200 || status >= 300 {
		jsonReply(w, http.StatusUnprocessableEntity, map[string]string{"error": "disconnect_failed"})
		return
	}
	w.Header().Set("content-type", "application/json")
	w.Header().Set("cache-control", "no-store")
	_, _ = w.Write(data)
}

type telegramUpdate struct {
	UpdateID int64 `json:"update_id"`
	Message  *struct {
		MessageID int64  `json:"message_id"`
		Text      string `json:"text,omitempty"`
		Caption   string `json:"caption,omitempty"`
		Chat      struct {
			ID   int64  `json:"id"`
			Type string `json:"type"`
		} `json:"chat"`
		From struct {
			ID        int64  `json:"id"`
			Username  string `json:"username,omitempty"`
			FirstName string `json:"first_name,omitempty"`
			LastName  string `json:"last_name,omitempty"`
		} `json:"from"`
		Document *struct {
			FileID       string `json:"file_id"`
			FileUniqueID string `json:"file_unique_id,omitempty"`
			FileName     string `json:"file_name"`
			MimeType     string `json:"mime_type"`
			FileSize     int64  `json:"file_size"`
		} `json:"document,omitempty"`
		Photo []struct {
			FileID       string `json:"file_id"`
			FileUniqueID string `json:"file_unique_id,omitempty"`
			FileSize     int64  `json:"file_size"`
			Width        int    `json:"width"`
			Height       int    `json:"height"`
		} `json:"photo,omitempty"`
	} `json:"message,omitempty"`
	Callback *struct {
		ID   string `json:"id"`
		Data string `json:"data"`
		From struct {
			ID int64 `json:"id"`
		} `json:"from"`
		Message struct {
			Chat struct {
				ID   int64  `json:"id"`
				Type string `json:"type"`
			} `json:"chat"`
		} `json:"message"`
	} `json:"callback_query,omitempty"`
}

func (h *telegramAPI) webhook(w http.ResponseWriter, r *http.Request) {
	provided := r.Header.Get("X-Telegram-Bot-Api-Secret-Token")
	providedHash := sha256.Sum256([]byte(provided))
	expectedHash := sha256.Sum256([]byte(h.webhookSecret))
	if h.webhookSecret == "" || !hmac.Equal(providedHash[:], expectedHash[:]) {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "webhook_authentication_failed"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, telegramWebhookLimit)
	var update telegramUpdate
	if err := decodeJSONEOF(r.Body, &update); err != nil || update.UpdateID < 0 || (update.Message == nil) == (update.Callback == nil) {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_update"})
		return
	}
	kind, userID, chatID, chatType := "message", int64(0), int64(0), ""
	if update.Message != nil {
		userID, chatID, chatType = update.Message.From.ID, update.Message.Chat.ID, update.Message.Chat.Type
		if len(update.Message.Text) > 2000 || len(update.Message.Caption) > 2000 || len(update.Message.Photo) > 12 {
			jsonReply(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "invalid_update"})
			return
		}
	} else {
		kind, userID, chatID, chatType = "callback_query", update.Callback.From.ID, update.Callback.Message.Chat.ID, update.Callback.Message.Chat.Type
		if len(update.Callback.Data) < 8 || len(update.Callback.Data) > 100 || len(update.Callback.ID) > 200 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_update"})
			return
		}
	}
	if chatType != "private" || userID <= 0 || chatID == 0 {
		jsonReply(w, http.StatusUnprocessableEntity, map[string]string{"error": "private_chat_required"})
		return
	}
	envelope, _ := json.Marshal(update)
	data, status, err := h.serviceRPC("ingest_telegram_update", map[string]any{"bot_identity": h.botIdentity, "telegram_update_id": update.UpdateID, "telegram_user": strconv.FormatInt(userID, 10), "telegram_chat": strconv.FormatInt(chatID, 10), "kind": kind, "envelope": json.RawMessage(envelope)})
	if err != nil || status < 200 || status >= 300 {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "update_not_persisted"})
		return
	}
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func validateTelegramConfiguration(botIdentity, botUsername, webhookSecret, deepLinkBase string, isolated bool) error {
	if botIdentity == "" && botUsername == "" && webhookSecret == "" {
		return nil
	}
	if len(botIdentity) < 1 || len(botIdentity) > 80 || !telegramBotUsernamePattern.MatchString(botUsername) || len(webhookSecret) < 32 || len(webhookSecret) > 256 {
		return errors.New("Telegram integration configuration is incomplete")
	}
	if deepLinkBase != "" {
		parsed, err := url.Parse(deepLinkBase)
		if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && !(isolated && parsed.Scheme == "http" && (parsed.Hostname() == "127.0.0.1" || parsed.Hostname() == "localhost"))) {
			return errors.New("Telegram deep-link configuration is invalid")
		}
	}
	return nil
}

func telegramConfigurationSummary(botIdentity, botUsername string) string {
	return fmt.Sprintf("telegram transport enabled for bot identity %q (@%s)", botIdentity, botUsername)
}
