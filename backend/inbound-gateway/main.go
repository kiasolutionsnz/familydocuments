package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const maxBody = 15 * 1024 * 1024

var nonceRE = regexp.MustCompile(`^[0-9a-f]{32}$`)
var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func env(name string) string {
	v := os.Getenv(name)
	if v == "" {
		log.Fatalf("%s is required", name)
	}
	return v
}
func optionalEnv(name string) string { return strings.TrimSpace(os.Getenv(name)) }
func b64url(v []byte) string         { return strings.TrimRight(base64.URLEncoding.EncodeToString(v), "=") }
func jwt(secret string) string {
	now := time.Now().Unix()
	h := b64url([]byte(`{"alg":"HS256","typ":"JWT"}`))
	p, _ := json.Marshal(map[string]any{"role": "service_role", "iss": "supabase", "iat": now, "exp": now + 300})
	u := h + "." + b64url(p)
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(u))
	return u + "." + b64url(m.Sum(nil))
}

func publicProxy(prefix, upstream, allowedOrigin string, upstreamOrigin ...string) http.Handler {
	target, err := url.Parse(upstream)
	if err != nil {
		log.Fatalf("invalid upstream %s: %v", upstream, err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	originalDirector := proxy.Director
	proxy.Director = func(r *http.Request) {
		originalDirector(r)
		r.Header.Set("X-Forwarded-Proto", "https")
		if len(upstreamOrigin) > 0 {
			r.Header.Set("Origin", upstreamOrigin[0])
		}
	}
	proxy.ModifyResponse = func(resp *http.Response) error {
		if resp.Request.Header.Get("Origin") == allowedOrigin || len(upstreamOrigin) > 0 {
			resp.Header.Del("Access-Control-Allow-Origin")
			resp.Header.Set("Access-Control-Allow-Origin", allowedOrigin)
			resp.Header.Set("Vary", "Origin")
		}
		return nil
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		log.Printf("proxy error for %s: %v", prefix, err)
		http.Error(w, "upstream unavailable", http.StatusBadGateway)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" && origin != allowedOrigin {
			http.Error(w, "origin not allowed", http.StatusForbidden)
			return
		}
		if origin == allowedOrigin && r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Origin", allowedOrigin)
			w.Header().Set("Access-Control-Allow-Headers", "authorization, content-type")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, PUT, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Max-Age", "86400")
			w.Header().Add("Vary", "Origin")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		r.URL.Path = strings.TrimPrefix(r.URL.Path, prefix)
		if r.URL.Path == "" {
			r.URL.Path = "/"
		}
		proxy.ServeHTTP(w, r)
	})
}

func jsonReply(w http.ResponseWriter, status int, body any) {
	w.Header().Set("content-type", "application/json")
	w.Header().Set("cache-control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func searchHandler(api, allowedOrigin string) http.HandlerFunc {
	type searchRequest struct {
		Query string `json:"query"`
	}
	return func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" && origin != allowedOrigin {
			jsonReply(w, http.StatusForbidden, map[string]string{"error": "origin_denied"})
			return
		}
		if origin == allowedOrigin {
			w.Header().Set("Access-Control-Allow-Origin", allowedOrigin)
			w.Header().Add("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Headers", "authorization, content-type")
			w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodPost {
			jsonReply(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
			return
		}
		authorization := r.Header.Get("Authorization")
		if !strings.HasPrefix(authorization, "Bearer ") {
			jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		var input searchRequest
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
			return
		}
		query := strings.TrimSpace(input.Query)
		if len(query) < 2 || len(query) > 120 {
			jsonReply(w, http.StatusUnprocessableEntity, map[string]string{"error": "invalid_query"})
			return
		}
		payload, _ := json.Marshal(map[string]any{"search_query": query, "result_limit": 12})
		req, _ := http.NewRequest(http.MethodPost, strings.TrimRight(api, "/")+"/rpc/search_household_records", bytes.NewReader(payload))
		req.Header.Set("Authorization", authorization)
		req.Header.Set("Content-Type", "application/json")
		resp, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
		if err != nil {
			jsonReply(w, http.StatusBadGateway, map[string]string{"error": "search_unavailable"})
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			status := http.StatusBadGateway
			if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
				status = resp.StatusCode
			}
			jsonReply(w, status, map[string]string{"error": "search_failed"})
			return
		}
		var sources []map[string]any
		if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(&sources); err != nil {
			jsonReply(w, http.StatusBadGateway, map[string]string{"error": "search_failed"})
			return
		}
		answer := "Matching authorised records are shown below."
		if len(sources) == 0 {
			answer = "No authorised confirmed records matched your question."
		}
		jsonReply(w, http.StatusOK, map[string]any{"answer": answer, "sources": sources, "cited_ids": []string{}, "abstain": true, "mode": "deterministic"})
	}
}

func main() {
	secret, jwtSecret, api := env("INGESTION_HMAC_SECRET"), env("GOTRUE_JWT_SECRET"), env("FP_API_URL")
	allowedOrigin := env("FRONTEND_ORIGIN")
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("content-type", "application/json")
		io.WriteString(w, `{"status":"ok"}`)
	})
	authUpstream := env("AUTH_UPSTREAM_URL")
	mux.Handle("/auth/", publicProxy("/auth", authUpstream, allowedOrigin))
	mux.Handle("/verify", publicProxy("", authUpstream, allowedOrigin))
	mux.Handle("/callback", publicProxy("", authUpstream, allowedOrigin))
	mux.Handle("/rest/", publicProxy("/rest", api, allowedOrigin))
	mux.Handle("/ocr/", publicProxy("/ocr", env("OCR_UPSTREAM_URL"), allowedOrigin, "http://127.0.0.1:3300"))
	mux.HandleFunc("/documents/analyse", documentAnalysisHandler(api, env("OCR_UPSTREAM_URL"), optionalEnv("OLLAMA_BASE_URL"), optionalEnv("DOCUMENT_CLASSIFIER_MODEL"), allowedOrigin))
	mux.HandleFunc("/documents/save", documentSaveHandler(api, allowedOrigin))
	registerDocumentAnalysisJobRoutes(mux, api, allowedOrigin)
	mux.HandleFunc("/search/ask", searchHandler(api, allowedOrigin))
	mux.HandleFunc("/help/chat", newHelpChatHandler(allowedOrigin, optionalEnv("OLLAMA_BASE_URL"), optionalEnv("HELP_CHAT_MODEL"), nil))
	driveGateway, driveErr := newDriveGateway(api, allowedOrigin, jwtSecret)
	if driveErr != nil {
		log.Fatalf("Google Drive gateway configuration invalid: %v", driveErr)
	}
	if driveGateway != nil {
		driveGateway.register(mux)
	}
	mux.HandleFunc("POST /v1/inbound-email", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxBody)
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "request too large", 413)
			return
		}
		ts, err := strconv.ParseInt(r.Header.Get("x-fd-timestamp"), 10, 64)
		nonce := r.Header.Get("x-fd-nonce")
		if err != nil || !nonceRE.MatchString(nonce) || time.Since(time.Unix(ts, 0)) > 5*time.Minute || time.Until(time.Unix(ts, 0)) > time.Minute {
			http.Error(w, "invalid request freshness", 401)
			return
		}
		sum := sha256.Sum256(body)
		bodyHash := hex.EncodeToString(sum[:])
		if !hmac.Equal([]byte(bodyHash), []byte(strings.ToLower(r.Header.Get("x-fd-content-sha256")))) {
			http.Error(w, "content hash mismatch", 401)
			return
		}
		canonical := fmt.Sprintf("v1\n%d\n%s\n%s", ts, nonce, bodyHash)
		mac := hmac.New(sha256.New, []byte(secret))
		mac.Write([]byte(canonical))
		expected := hex.EncodeToString(mac.Sum(nil))
		if !hmac.Equal([]byte(expected), []byte(strings.ToLower(r.Header.Get("x-fd-signature")))) {
			http.Error(w, "invalid signature", 401)
			return
		}
		req, _ := http.NewRequest("POST", strings.TrimRight(api, "/")+"/rpc/ingest_cloudflare_message", bytes.NewReader(body))
		req.Header.Set("content-type", "application/json")
		req.Header.Set("authorization", "Bearer "+jwt(jwtSecret))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			http.Error(w, "upstream unavailable", 502)
			return
		}
		defer resp.Body.Close()
		result, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		w.Header().Set("content-type", "application/json")
		w.WriteHeader(resp.StatusCode)
		w.Write(result)
	})
	server := &http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 60 * time.Second, IdleTimeout: 60 * time.Second}
	log.Fatal(server.ListenAndServe())
}
