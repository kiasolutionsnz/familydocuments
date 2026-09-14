package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func (g *driveGateway) validWorkerAuthorization(header string) bool {
	if !strings.HasPrefix(header, "Bearer ") || g.jwtSecret == "" {
		return false
	}
	parts := strings.Split(strings.TrimPrefix(header, "Bearer "), ".")
	if len(parts) != 3 {
		return false
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, []byte(g.jwtSecret))
	mac.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(signature, mac.Sum(nil)) {
		return false
	}
	headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return false
	}
	var tokenHeader struct {
		Alg string `json:"alg"`
		Typ string `json:"typ"`
	}
	if decodeStrictJSON(headerBytes, &tokenHeader) != nil || tokenHeader.Alg != "HS256" || tokenHeader.Typ != "JWT" {
		return false
	}
	claimsBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return false
	}
	var claims struct {
		Role   string `json:"role"`
		Issuer string `json:"iss"`
		Expiry int64  `json:"exp"`
		Issued int64  `json:"iat"`
	}
	if json.Unmarshal(claimsBytes, &claims) != nil || claims.Role != "service_role" || claims.Issuer != "supabase" ||
		claims.Expiry <= time.Now().Unix() || claims.Expiry > time.Now().Add(10*time.Minute).Unix() || claims.Issued > time.Now().Unix()+30 {
		return false
	}
	return true
}

func (g *driveGateway) analysisSource(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonReply(w, 405, map[string]string{"error": "method_not_allowed"})
		return
	}
	if !g.validWorkerAuthorization(r.Header.Get("Authorization")) {
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
		return
	}
	var in struct {
		Job   string `json:"job_id"`
		Lease string `json:"lease_token"`
	}
	if decodeJSON(w, r, 1024, &in) != nil || !uuidPattern.MatchString(in.Job) || !uuidPattern.MatchString(in.Lease) {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	var source struct {
		HouseholdID string `json:"household_id"`
		FileID      string `json:"file_id"`
		FolderID    string `json:"folder_id"`
		MimeType    string `json:"mime_type"`
		FileName    string `json:"file_name"`
		Size        int64  `json:"size_bytes"`
		SHA256      string `json:"sha256"`
	}
	if g.rpc("authorize_drive_analysis_source", g.serviceAuthorization(), map[string]any{"job": in.Job, "worker_lease_token": in.Lease}, &source) != nil {
		jsonReply(w, 403, map[string]string{"error": "source_unavailable"})
		return
	}
	access, _, err := g.access(source.HouseholdID)
	if err != nil {
		jsonReply(w, 409, map[string]string{"error": "drive_reconnect_required"})
		return
	}
	fileURL := "https://www.googleapis.com/drive/v3/files/" + url.PathEscape(source.FileID)
	var meta driveFile
	_, err = g.google("GET", fileURL+"?fields=id,name,mimeType,size,parents,trashed", access, "", nil, &meta)
	if err != nil || meta.ID != source.FileID || meta.Trashed || meta.Name != source.FileName || meta.MimeType != source.MimeType ||
		meta.Size != fmt.Sprint(source.Size) || !contains(meta.Parents, source.FolderID) {
		jsonReply(w, 409, map[string]string{"error": "source_changed"})
		return
	}
	response, err := g.google("GET", fileURL+"?alt=media", access, "", nil, nil)
	if err != nil {
		jsonReply(w, 502, map[string]string{"error": "drive_file_unavailable"})
		return
	}
	defer response.Body.Close()
	content, err := io.ReadAll(io.LimitReader(response.Body, (5<<20)+1))
	digest := sha256.Sum256(content)
	if err != nil || int64(len(content)) != source.Size || !validOriginalBytes(source.MimeType, content) ||
		hex.EncodeToString(digest[:]) != source.SHA256 {
		jsonReply(w, 409, map[string]string{"error": "source_integrity"})
		return
	}
	jsonReply(w, 200, map[string]string{"content_base64": base64.StdEncoding.EncodeToString(content)})
}

type conversationDriveAttachment struct {
	ConversationID string `json:"conversation_id"`
	FileName       string `json:"file_name"`
	MimeType       string `json:"mime_type"`
	ContentBase64  string `json:"content_base64"`
}

func validOriginalBytes(mimeType string, data []byte) bool {
	if len(data) < 1 || len(data) > 5<<20 {
		return false
	}
	switch mimeType {
	case "application/pdf":
		return bytes.HasPrefix(data, []byte("%PDF-"))
	case "image/jpeg":
		return bytes.HasPrefix(data, []byte{0xff, 0xd8, 0xff})
	case "image/png":
		return bytes.HasPrefix(data, []byte{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a})
	default:
		return false
	}
}

func (g *driveGateway) uploadConversationOriginal(w http.ResponseWriter, r *http.Request, identity accessIdentity, in conversationDriveAttachment) {
	if !uuidPattern.MatchString(in.ConversationID) || len(strings.TrimSpace(in.FileName)) < 1 || len(in.FileName) > 255 || len(in.ContentBase64) > 7340032 {
		jsonReply(w, 400, map[string]string{"error": "invalid_attachment"})
		return
	}
	content, err := base64.StdEncoding.DecodeString(in.ContentBase64)
	if err != nil || !validOriginalBytes(in.MimeType, content) {
		jsonReply(w, 422, map[string]string{"error": "invalid_attachment"})
		return
	}
	a, err := g.auth(r, "authorize_google_drive_member", map[string]any{})
	if err != nil || a.UserID != identity.UserID {
		jsonReply(w, 403, map[string]string{"error": "drive_not_available"})
		return
	}
	access, _, err := g.access(a.HouseholdID)
	if err != nil {
		jsonReply(w, 409, map[string]string{"error": "drive_reconnect_required"})
		return
	}
	var generated struct {
		IDs []string `json:"ids"`
	}
	_, err = g.google("GET", "https://www.googleapis.com/drive/v3/files/generateIds?count=1&space=drive", access, "", nil, &generated)
	if err != nil || len(generated.IDs) != 1 {
		jsonReply(w, 502, map[string]string{"error": "drive_unavailable"})
		return
	}
	sha := sha256.Sum256(content)
	var reservation struct {
		ID       string `json:"id"`
		FileID   string `json:"file_id"`
		FolderID string `json:"folder_id"`
		Status   string `json:"status"`
	}
	err = g.rpc("reserve_conversation_drive_upload", g.serviceAuthorization(), map[string]any{
		"conversation": in.ConversationID, "actor": identity.UserID, "family": a.HouseholdID,
		"generated_file_id": generated.IDs[0], "file_name": in.FileName, "source_mime_type": in.MimeType,
		"size_bytes": len(content), "content_sha256": hex.EncodeToString(sha[:]),
	}, &reservation)
	if err != nil || reservation.FileID == "" || reservation.FolderID != a.FolderID {
		jsonReply(w, 409, map[string]string{"error": "drive_upload_not_authorised"})
		return
	}
	var saved driveFile
	fileURL := "https://www.googleapis.com/drive/v3/files/" + url.PathEscape(reservation.FileID) + "?fields=id,name,mimeType,size,modifiedTime,version,md5Checksum,parents,trashed"
	if reservation.Status != "uploaded" {
		meta, _ := json.Marshal(map[string]any{"id": reservation.FileID, "name": strings.TrimSpace(in.FileName), "mimeType": in.MimeType, "parents": []string{reservation.FolderID}})
		boundary := "familydocuments-7MA4YWxk"
		var body bytes.Buffer
		fmt.Fprintf(&body, "--%s\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n%s\r\n--%s\r\nContent-Type: %s\r\n\r\n", boundary, meta, boundary, in.MimeType)
		body.Write(content)
		fmt.Fprintf(&body, "\r\n--%s--\r\n", boundary)
		_, err = g.google("POST", "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,mimeType,size,modifiedTime,version,md5Checksum,parents,trashed", access, "multipart/related; boundary="+boundary, &body, &saved)
		if err != nil {
			// A lost response can still mean the file was created. The reserved ID
			// lets us find it without uploading a second original.
			_, err = g.google("GET", fileURL, access, "", nil, &saved)
			if err != nil {
				jsonReply(w, 502, map[string]string{"error": "drive_upload_unconfirmed"})
				return
			}
		}
	} else {
		_, err = g.google("GET", fileURL, access, "", nil, &saved)
		if err != nil {
			jsonReply(w, 502, map[string]string{"error": "drive_file_unavailable"})
			return
		}
	}
	md5sum := md5.Sum(content)
	if saved.ID != reservation.FileID || saved.Name != strings.TrimSpace(in.FileName) || saved.MimeType != in.MimeType ||
		saved.Size != fmt.Sprint(len(content)) || saved.Version == "" || saved.Trashed ||
		!contains(saved.Parents, reservation.FolderID) ||
		!strings.EqualFold(saved.MD5Checksum, hex.EncodeToString(md5sum[:])) {
		jsonReply(w, 409, map[string]string{"error": "drive_upload_mismatch"})
		return
	}
	modified, err := time.Parse(time.RFC3339, saved.ModifiedTime)
	if err != nil {
		jsonReply(w, 502, map[string]string{"error": "drive_metadata_incomplete"})
		return
	}
	var staged any
	err = g.rpc("finish_conversation_drive_upload", g.serviceAuthorization(), map[string]any{
		"reservation": reservation.ID, "actor": identity.UserID, "family": a.HouseholdID, "conversation": in.ConversationID,
		"google_file_id": saved.ID, "google_modified_time": modified.UTC().Format(time.RFC3339),
		"google_version": saved.Version, "google_checksum": saved.MD5Checksum,
	}, &staged)
	if err != nil {
		jsonReply(w, 409, map[string]string{"error": "drive_upload_pending"})
		return
	}
	jsonReply(w, 200, staged)
}
