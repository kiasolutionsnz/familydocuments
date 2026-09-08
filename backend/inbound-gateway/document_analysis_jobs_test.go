package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const syntheticJobID = "10000000-0000-4000-8000-000000000001"

func TestAnalysisJobCreationForwardsAuthAndReturnsAccepted(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/rpc/create_document_analysis_job" || r.Header.Get("Authorization") != "Bearer user-token" {
			t.Fatalf("unexpected upstream request: %s %s", r.URL.Path, r.Header.Get("Authorization"))
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["idempotency"] != "request-12345" || body["analysis_mode"] != "invoice" {
			t.Fatalf("unexpected body: %#v", body)
		}
		jsonReply(w, http.StatusOK, map[string]any{"job_id": syntheticJobID, "document_id": "20000000-0000-4000-8000-000000000002", "status": "queued"})
	}))
	defer upstream.Close()
	content := base64.StdEncoding.EncodeToString([]byte("%PDF-synthetic"))
	body := `{"file_name":"test.pdf","mime_type":"application/pdf","sha256":"` + strings.Repeat("a", 64) + `","content_base64":"` + content + `","mode":"invoice","idempotency_key":"request-12345"}`
	req := httptest.NewRequest(http.MethodPost, "/document-analysis/jobs", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer user-token")
	req.Header.Set("Origin", testOrigin)
	res := httptest.NewRecorder()
	documentAnalysisJobCreateHandler(upstream.URL, testOrigin)(res, req)
	if res.Code != http.StatusAccepted || !strings.Contains(res.Body.String(), `"status":"queued"`) || !strings.Contains(res.Body.String(), syntheticJobID) {
		t.Fatalf("unexpected response %d: %s", res.Code, res.Body.String())
	}
}

func TestAnalysisJobRoutesAcceptBrowserPreflight(t *testing.T) {
	mux := http.NewServeMux()
	registerDocumentAnalysisJobRoutes(mux, "http://127.0.0.1:1", testOrigin)
	for _, path := range []string{
		"/document-analysis/jobs",
		"/document-analysis/jobs/" + syntheticJobID,
		"/document-analysis/jobs/" + syntheticJobID + "/retry",
	} {
		req := httptest.NewRequest(http.MethodOptions, path, nil)
		req.Header.Set("Origin", testOrigin)
		req.Header.Set("Access-Control-Request-Method", http.MethodPost)
		req.Header.Set("Access-Control-Request-Headers", "authorization,content-type")
		res := httptest.NewRecorder()
		mux.ServeHTTP(res, req)
		if res.Code != http.StatusNoContent {
			t.Fatalf("preflight %s returned %d", path, res.Code)
		}
		if res.Header().Get("Access-Control-Allow-Origin") != testOrigin {
			t.Fatalf("preflight %s omitted the allowed origin", path)
		}
	}
}

func TestAnalysisJobEndpointsRequireAuthentication(t *testing.T) {
	create := httptest.NewRequest(http.MethodPost, "/document-analysis/jobs", strings.NewReader(`{}`))
	create.Header.Set("Origin", testOrigin)
	createResult := httptest.NewRecorder()
	documentAnalysisJobCreateHandler("http://127.0.0.1:1", testOrigin)(createResult, create)
	if createResult.Code != http.StatusUnauthorized {
		t.Fatalf("create status = %d", createResult.Code)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /document-analysis/jobs/{id}", documentAnalysisJobStatusHandler("http://127.0.0.1:1", testOrigin))
	statusResult := httptest.NewRecorder()
	mux.ServeHTTP(statusResult, httptest.NewRequest(http.MethodGet, "/document-analysis/jobs/"+syntheticJobID, nil))
	if statusResult.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d", statusResult.Code)
	}
}

func TestAnalysisJobStatusDoesNotExposeCrossFamilyDetails(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		jsonReply(w, http.StatusNotFound, map[string]string{"message": "job not found"})
	}))
	defer upstream.Close()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /document-analysis/jobs/{id}", documentAnalysisJobStatusHandler(upstream.URL, testOrigin))
	req := httptest.NewRequest(http.MethodGet, "/document-analysis/jobs/"+syntheticJobID, nil)
	req.Header.Set("Authorization", "Bearer other-family-token")
	res := httptest.NewRecorder()
	mux.ServeHTTP(res, req)
	if res.Code != http.StatusNotFound || !strings.Contains(res.Body.String(), "job_not_found") {
		t.Fatalf("response %d: %s", res.Code, res.Body.String())
	}
}
