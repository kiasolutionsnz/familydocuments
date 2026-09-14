package main

import (
	"bytes"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

type driveTestTransport func(*http.Request) (*http.Response, error)

func (fn driveTestTransport) RoundTrip(r *http.Request) (*http.Response, error) { return fn(r) }

func driveTestResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}
}

func TestConversationDriveUploadRetryKeepsOneOriginal(t *testing.T) {
	const actor = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	const family = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	const conversation = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
	const fileID = "google-file-synthetic-001"
	const folderID = "google-folder-synthetic-001"
	content := []byte("%PDF-1.4\nsynthetic test document")
	contentMD5 := md5.Sum(content)
	key := bytes.Repeat([]byte{7}, 32)
	g := &driveGateway{clientID: "synthetic-client", clientSecret: "synthetic-secret", key: key, jwtSecret: "synthetic-jwt-secret"}
	ciphertext, nonce, err := g.encrypt("synthetic-refresh")
	if err != nil {
		t.Fatal(err)
	}
	uploads := 0
	reservations := 0
	completed := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch strings.TrimPrefix(r.URL.Path, "/rpc/") {
		case "authorize_google_drive_member":
			if r.Header.Get("Authorization") != "Bearer synthetic-user-token" {
				t.Error("missing user authorization")
			}
			jsonReply(w, 200, map[string]string{"household_id": family, "user_id": actor, "folder_id": folderID})
		case "google_drive_credential":
			jsonReply(w, 200, map[string]string{"ciphertext": ciphertext, "nonce": nonce})
		case "reserve_conversation_drive_upload":
			reservations++
			var body map[string]any
			if json.NewDecoder(r.Body).Decode(&body) != nil || body["actor"] != actor || body["family"] != family || body["conversation"] != conversation {
				t.Error("reservation authority mismatch")
			}
			jsonReply(w, 200, map[string]string{"id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "file_id": fileID, "folder_id": folderID, "status": map[bool]string{true: "uploaded", false: "reserved"}[completed > 0]})
		case "finish_conversation_drive_upload":
			completed++
			jsonReply(w, 200, map[string]string{"id": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"})
		default:
			t.Errorf("unexpected RPC %s", r.URL.Path)
			jsonReply(w, 404, map[string]string{"error": "not_found"})
		}
	}))
	defer api.Close()
	g.api = api.URL
	g.http = &http.Client{Transport: driveTestTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host == strings.TrimPrefix(api.URL, "http://") {
			return http.DefaultTransport.RoundTrip(r)
		}
		switch {
		case r.URL.Host == "oauth2.googleapis.com":
			return driveTestResponse(200, `{"access_token":"synthetic-access"}`), nil
		case strings.HasSuffix(r.URL.Path, "/generateIds"):
			return driveTestResponse(200, `{"ids":["google-file-synthetic-001"]}`), nil
		case r.Method == http.MethodPost && strings.Contains(r.URL.Path, "/upload/drive/"):
			uploads++
			payload, _ := io.ReadAll(r.Body)
			if !bytes.Contains(payload, content) || !bytes.Contains(payload, []byte(`"id":"`+fileID+`"`)) {
				t.Error("upload missing original or reserved ID")
			}
			return driveTestResponse(200, driveTestFileJSON(fileID, folderID, len(content), hex.EncodeToString(contentMD5[:]))), nil
		case r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/files/"+fileID):
			return driveTestResponse(200, driveTestFileJSON(fileID, folderID, len(content), hex.EncodeToString(contentMD5[:]))), nil
		default:
			t.Errorf("unexpected Google request %s", r.URL.Path)
			return driveTestResponse(404, `{}`), nil
		}
	})}
	request := httptest.NewRequest("POST", "/conversation/attachment", nil)
	request.Header.Set("Authorization", "Bearer synthetic-user-token")
	input := conversationDriveAttachment{ConversationID: conversation, FileName: "synthetic.pdf", MimeType: "application/pdf", ContentBase64: base64.StdEncoding.EncodeToString(content)}
	for i := 0; i < 2; i++ {
		out := httptest.NewRecorder()
		g.uploadConversationOriginal(out, request, accessIdentity{UserID: actor}, input)
		if out.Code != 200 || !strings.Contains(out.Body.String(), "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee") {
			t.Fatalf("upload attempt %d: status %d, category %s", i, out.Code, out.Body.String())
		}
	}
	if uploads != 1 || reservations != 2 || completed != 2 {
		t.Fatalf("retry duplicated original: uploads=%d reservations=%d completed=%d", uploads, reservations, completed)
	}
}

func driveTestFileJSON(fileID, folderID string, size int, md5sum string) string {
	value, _ := json.Marshal(map[string]any{"id": fileID, "name": "synthetic.pdf", "mimeType": "application/pdf", "size": strconv.Itoa(size), "modifiedTime": time.Date(2026, 9, 14, 1, 0, 0, 0, time.UTC).Format(time.RFC3339), "version": "1", "md5Checksum": md5sum, "parents": []string{folderID}})
	return string(value)
}
