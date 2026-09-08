package main

import (
	"encoding/json"
	"net/http"
	"strings"
)

func registerDocumentAnalysisJobRoutes(mux *http.ServeMux, api, allowedOrigin string) {
	create := documentAnalysisJobCreateHandler(api, allowedOrigin)
	status := documentAnalysisJobStatusHandler(api, allowedOrigin)
	retry := documentAnalysisJobRetryHandler(api, allowedOrigin)
	mux.HandleFunc("POST /document-analysis/jobs", create)
	mux.HandleFunc("OPTIONS /document-analysis/jobs", create)
	mux.HandleFunc("GET /document-analysis/jobs/{id}", status)
	mux.HandleFunc("OPTIONS /document-analysis/jobs/{id}", status)
	mux.HandleFunc("POST /document-analysis/jobs/{id}/retry", retry)
	mux.HandleFunc("OPTIONS /document-analysis/jobs/{id}/retry", retry)
}

type analysisJobCreateRequest struct {
	FileName      string `json:"file_name"`
	MimeType      string `json:"mime_type"`
	SHA256        string `json:"sha256"`
	ContentBase64 string `json:"content_base64"`
	Mode          string `json:"mode"`
	Idempotency   string `json:"idempotency_key"`
}

func documentAnalysisJobCreateHandler(api, allowedOrigin string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !allowDocumentOrigin(w, r, allowedOrigin) {
			return
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
		r.Body = http.MaxBytesReader(w, r.Body, 7<<20)
		var input analysisJobCreateRequest
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil ||
			!validUpload(input.FileName, input.MimeType, input.SHA256, input.ContentBase64) ||
			(input.Mode != "document" && input.Mode != "invoice") || len(input.Idempotency) < 8 || len(input.Idempotency) > 100 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_document"})
			return
		}
		var result map[string]any
		status, err := postJSON(strings.TrimRight(api, "/")+"/rpc/create_document_analysis_job", authorization, "", map[string]any{
			"file_name": input.FileName, "source_mime_type": input.MimeType, "content_base64": input.ContentBase64,
			"analysis_mode": input.Mode, "idempotency": input.Idempotency,
		}, &result)
		if err != nil || status != http.StatusOK {
			upstreamFailure(w, status, "job_could_not_be_created")
			return
		}
		result["status_location"] = "/document-analysis/jobs/" + stringValue(result["job_id"])
		jsonReply(w, http.StatusAccepted, result)
	}
}

func documentAnalysisJobStatusHandler(api, allowedOrigin string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !allowDocumentOrigin(w, r, allowedOrigin) {
			return
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		authorization := r.Header.Get("Authorization")
		if !strings.HasPrefix(authorization, "Bearer ") {
			jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
			return
		}
		jobID := r.PathValue("id")
		if !uuidPattern.MatchString(jobID) {
			jsonReply(w, http.StatusNotFound, map[string]string{"error": "job_not_found"})
			return
		}
		var result map[string]any
		status, err := postJSON(strings.TrimRight(api, "/")+"/rpc/document_analysis_job", authorization, "", map[string]string{"job": jobID}, &result)
		if err != nil || status != http.StatusOK {
			upstreamFailure(w, status, "job_not_found")
			return
		}
		jsonReply(w, http.StatusOK, result)
	}
}

func documentAnalysisJobRetryHandler(api, allowedOrigin string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !allowDocumentOrigin(w, r, allowedOrigin) {
			return
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		authorization := r.Header.Get("Authorization")
		if !strings.HasPrefix(authorization, "Bearer ") {
			jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
			return
		}
		jobID := r.PathValue("id")
		if !uuidPattern.MatchString(jobID) {
			jsonReply(w, http.StatusNotFound, map[string]string{"error": "job_not_found"})
			return
		}
		var result map[string]any
		status, err := postJSON(strings.TrimRight(api, "/")+"/rpc/retry_document_analysis_job", authorization, "", map[string]string{"job": jobID}, &result)
		if err != nil || status != http.StatusOK {
			upstreamFailure(w, status, "job_not_retryable")
			return
		}
		jsonReply(w, http.StatusOK, result)
	}
}

func upstreamFailure(w http.ResponseWriter, upstreamStatus int, code string) {
	status := http.StatusBadGateway
	if upstreamStatus == http.StatusUnauthorized || upstreamStatus == http.StatusForbidden {
		status = upstreamStatus
	} else if upstreamStatus == http.StatusNotFound {
		status = http.StatusNotFound
	}
	jsonReply(w, status, map[string]string{"error": code})
}

func stringValue(value any) string {
	valueString, _ := value.(string)
	return strings.TrimSpace(valueString)
}
