package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const driveScope = "https://www.googleapis.com/auth/drive.file"

type driveGateway struct {
	api, origin, clientID, clientSecret string
	key                                 []byte
	serviceToken                        string
	http                                *http.Client
}
type driveAuth struct {
	HouseholdID string `json:"household_id"`
	UserID      string `json:"user_id"`
	FolderID    string `json:"folder_id"`
	FolderName  string `json:"folder_name"`
	FileID      string `json:"file_id"`
	FileName    string `json:"file_name"`
	MimeType    string `json:"mime_type"`
}
type googleToken struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	Scope        string `json:"scope"`
}
type driveFile struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	MimeType     string   `json:"mimeType"`
	Size         string   `json:"size"`
	ModifiedTime string   `json:"modifiedTime"`
	Version      string   `json:"version"`
	MD5Checksum  string   `json:"md5Checksum"`
	WebViewLink  string   `json:"webViewLink"`
	Parents      []string `json:"parents"`
	Trashed      bool     `json:"trashed"`
}

func envOptional(name string) string { return strings.TrimSpace(os.Getenv(name)) }
func newDriveGateway(api, origin, jwtSecret string) (*driveGateway, error) {
	id, secret, encoded := envOptional("GOOGLE_DRIVE_CLIENT_ID"), envOptional("GOOGLE_DRIVE_CLIENT_SECRET"), envOptional("GOOGLE_DRIVE_TOKEN_KEY")
	if id == "" || secret == "" || encoded == "" {
		return nil, nil
	}
	key, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(key) != 32 {
		return nil, errors.New("GOOGLE_DRIVE_TOKEN_KEY must be a base64-encoded 32-byte key")
	}
	return &driveGateway{strings.TrimRight(api, "/"), origin, id, secret, key, "Bearer " + jwt(jwtSecret), &http.Client{Timeout: 30 * time.Second}}, nil
}
func (g *driveGateway) rpc(name, authorization string, input, output any) error {
	payload, _ := json.Marshal(input)
	req, _ := http.NewRequest("POST", g.api+"/rpc/"+name, bytes.NewReader(payload))
	req.Header.Set("Authorization", authorization)
	req.Header.Set("Content-Type", "application/json")
	resp, err := g.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var problem struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		}
		_ = json.Unmarshal(raw, &problem)
		log.Printf("drive RPC %s failed: status=%d code=%q message=%q", name, resp.StatusCode, problem.Code, problem.Message)
		return fmt.Errorf("rpc %s returned %d", name, resp.StatusCode)
	}
	if output != nil && len(bytes.TrimSpace(raw)) > 0 {
		return json.Unmarshal(raw, output)
	}
	return nil
}
func (g *driveGateway) encrypt(value string) (string, string, error) {
	block, err := aes.NewCipher(g.key)
	if err != nil {
		return "", "", err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return "", "", err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err = rand.Read(nonce); err != nil {
		return "", "", err
	}
	sealed := aead.Seal(nil, nonce, []byte(value), []byte("familydocuments/google-drive/v1"))
	return base64.StdEncoding.EncodeToString(sealed), base64.StdEncoding.EncodeToString(nonce), nil
}
func (g *driveGateway) decrypt(ciphertext, nonce string) (string, error) {
	sealed, err := base64.StdEncoding.DecodeString(ciphertext)
	if err != nil {
		return "", err
	}
	n, err := base64.StdEncoding.DecodeString(nonce)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(g.key)
	if err != nil {
		return "", err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	plain, err := aead.Open(nil, n, sealed, []byte("familydocuments/google-drive/v1"))
	return string(plain), err
}
func (g *driveGateway) exchange(code string) (googleToken, error) {
	form := url.Values{"code": {code}, "client_id": {g.clientID}, "client_secret": {g.clientSecret}, "redirect_uri": {g.origin}, "grant_type": {"authorization_code"}}
	resp, err := g.http.PostForm("https://oauth2.googleapis.com/token", form)
	if err != nil {
		return googleToken{}, err
	}
	defer resp.Body.Close()
	var token googleToken
	if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&token) != nil || resp.StatusCode != 200 || token.AccessToken == "" || token.RefreshToken == "" {
		return token, errors.New("offline credential unavailable")
	}
	if !strings.Contains(token.Scope, driveScope) {
		return token, errors.New("Drive scope missing")
	}
	return token, nil
}
func (g *driveGateway) access(household string) (string, string, error) {
	var stored struct {
		Ciphertext string `json:"ciphertext"`
		Nonce      string `json:"nonce"`
	}
	if err := g.rpc("google_drive_credential", g.serviceToken, map[string]any{"target_household": household}, &stored); err != nil {
		return "", "", err
	}
	refresh, err := g.decrypt(stored.Ciphertext, stored.Nonce)
	if err != nil {
		return "", "", err
	}
	form := url.Values{"client_id": {g.clientID}, "client_secret": {g.clientSecret}, "refresh_token": {refresh}, "grant_type": {"refresh_token"}}
	resp, err := g.http.PostForm("https://oauth2.googleapis.com/token", form)
	if err != nil {
		return "", refresh, err
	}
	defer resp.Body.Close()
	var token googleToken
	_ = json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&token)
	if resp.StatusCode != 200 || token.AccessToken == "" {
		return "", refresh, errors.New("authorization expired")
	}
	return token.AccessToken, refresh, nil
}
func (g *driveGateway) google(method, endpoint, access, contentType string, body io.Reader, output any) (*http.Response, error) {
	req, _ := http.NewRequest(method, endpoint, body)
	req.Header.Set("Authorization", "Bearer "+access)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := g.http.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		defer resp.Body.Close()
		io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
		return nil, fmt.Errorf("Drive returned %d", resp.StatusCode)
	}
	if output != nil {
		defer resp.Body.Close()
		if err := json.NewDecoder(io.LimitReader(resp.Body, 2<<20)).Decode(output); err != nil {
			return nil, err
		}
	}
	return resp, nil
}
func (g *driveGateway) auth(r *http.Request, name string, input any) (driveAuth, error) {
	authorization := r.Header.Get("Authorization")
	if !strings.HasPrefix(authorization, "Bearer ") {
		return driveAuth{}, errors.New("authentication required")
	}
	var result driveAuth
	err := g.rpc(name, authorization, input, &result)
	return result, err
}
func (g *driveGateway) deleteReceipt(userID, fileID string, expires int64) string {
	message := fmt.Sprintf("%s\n%s\n%d", userID, fileID, expires)
	mac := hmac.New(sha256.New, g.key)
	mac.Write([]byte(message))
	return fmt.Sprintf("%d.%s", expires, base64.RawURLEncoding.EncodeToString(mac.Sum(nil)))
}
func (g *driveGateway) validDeleteReceipt(receipt, userID, fileID string) bool {
	parts := strings.Split(receipt, ".")
	if len(parts) != 2 {
		return false
	}
	expires, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || time.Now().Unix() > expires || expires > time.Now().Add(15*time.Minute).Unix() {
		return false
	}
	return hmac.Equal([]byte(receipt), []byte(g.deleteReceipt(userID, fileID, expires)))
}
func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
func (g *driveGateway) cors(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" && origin != g.origin {
			jsonReply(w, 403, map[string]string{"error": "origin_denied"})
			return
		}
		if origin == g.origin {
			w.Header().Set("Access-Control-Allow-Origin", g.origin)
			w.Header().Add("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Headers", "authorization,content-type,x-requested-with")
			w.Header().Set("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS")
		}
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		next(w, r)
	}
}
func decodeJSON(w http.ResponseWriter, r *http.Request, limit int64, out any) error {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	return json.NewDecoder(r.Body).Decode(out)
}
func (g *driveGateway) register(m *http.ServeMux) {
	m.HandleFunc("OPTIONS /drive/", g.cors(func(http.ResponseWriter, *http.Request) {}))
	m.HandleFunc("POST /drive/connect", g.cors(g.connect))
	m.HandleFunc("GET /drive/folders", g.cors(g.folders))
	m.HandleFunc("POST /drive/folders", g.cors(g.createFolder))
	m.HandleFunc("POST /drive/folders/select", g.cors(g.selectFolder))
	m.HandleFunc("POST /drive/upload", g.cors(g.upload))
	m.HandleFunc("DELETE /drive/files/{id}", g.cors(g.remove))
	m.HandleFunc("POST /drive/open", g.cors(g.open))
	m.HandleFunc("POST /drive/disconnect", g.cors(g.disconnect))
}
func (g *driveGateway) connect(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("X-Requested-With") != "XmlHttpRequest" {
		jsonReply(w, 403, map[string]string{"error": "csrf_check_failed"})
		return
	}
	a, err := g.auth(r, "authorize_google_drive_admin", map[string]any{})
	if err != nil {
		jsonReply(w, 403, map[string]string{"error": "mfa_and_admin_required"})
		return
	}
	var in struct {
		Code string `json:"code"`
	}
	if decodeJSON(w, r, 4096, &in) != nil || len(in.Code) < 10 || len(in.Code) > 4096 {
		jsonReply(w, 400, map[string]string{"error": "invalid_code"})
		return
	}
	token, err := g.exchange(in.Code)
	if err != nil {
		jsonReply(w, 502, map[string]string{"error": "google_authorization_failed"})
		return
	}
	ciphertext, nonce, err := g.encrypt(token.RefreshToken)
	if err == nil {
		err = g.rpc("store_google_drive_credential", g.serviceToken, map[string]any{"target_household": a.HouseholdID, "ciphertext": ciphertext, "nonce": nonce, "version": 1, "account": "", "granted_scopes": token.Scope, "actor": a.UserID}, nil)
	}
	if err != nil {
		log.Printf("Google Drive credential storage failed: ciphertext_bytes=%d nonce_bytes=%d scopes_bytes=%d error=%v", len(ciphertext), len(nonce), len(token.Scope), err)
		jsonReply(w, 500, map[string]string{"error": "credential_storage_failed"})
		return
	}
	jsonReply(w, 200, map[string]string{"status": "authorised"})
}
func (g *driveGateway) folders(w http.ResponseWriter, r *http.Request) {
	a, err := g.auth(r, "authorize_google_drive_admin", map[string]any{})
	if err != nil {
		jsonReply(w, 403, map[string]string{"error": "mfa_and_admin_required"})
		return
	}
	access, _, err := g.access(a.HouseholdID)
	if err != nil {
		jsonReply(w, 409, map[string]string{"error": "drive_reconnect_required"})
		return
	}
	q := url.QueryEscape("mimeType='application/vnd.google-apps.folder' and trashed=false")
	var out struct {
		Files []driveFile `json:"files"`
	}
	_, err = g.google("GET", "https://www.googleapis.com/drive/v3/files?q="+q+"&spaces=drive&pageSize=100&orderBy=name&fields=files(id,name,mimeType,webViewLink)", access, "", nil, &out)
	if err != nil {
		jsonReply(w, 502, map[string]string{"error": "drive_folders_unavailable"})
		return
	}
	jsonReply(w, 200, out)
}
func (g *driveGateway) createFolder(w http.ResponseWriter, r *http.Request) {
	a, err := g.auth(r, "authorize_google_drive_admin", map[string]any{})
	if err != nil {
		jsonReply(w, 403, map[string]string{"error": "mfa_and_admin_required"})
		return
	}
	var in struct {
		Name string `json:"name"`
	}
	if decodeJSON(w, r, 4096, &in) != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	if len(in.Name) < 1 || len(in.Name) > 80 {
		jsonReply(w, 422, map[string]string{"error": "invalid_folder_name"})
		return
	}
	access, _, err := g.access(a.HouseholdID)
	if err != nil {
		jsonReply(w, 409, map[string]string{"error": "drive_reconnect_required"})
		return
	}
	raw, _ := json.Marshal(map[string]string{"name": in.Name, "mimeType": "application/vnd.google-apps.folder"})
	var folder driveFile
	_, err = g.google("POST", "https://www.googleapis.com/drive/v3/files?fields=id,name,mimeType,webViewLink", access, "application/json", bytes.NewReader(raw), &folder)
	if err != nil {
		jsonReply(w, 502, map[string]string{"error": "folder_create_failed"})
		return
	}
	jsonReply(w, 200, folder)
}
func (g *driveGateway) selectFolder(w http.ResponseWriter, r *http.Request) {
	a, err := g.auth(r, "authorize_google_drive_admin", map[string]any{})
	if err != nil {
		jsonReply(w, 403, map[string]string{"error": "mfa_and_admin_required"})
		return
	}
	var in struct {
		ID string `json:"id"`
	}
	if decodeJSON(w, r, 4096, &in) != nil || len(in.ID) < 10 || len(in.ID) > 200 {
		jsonReply(w, 422, map[string]string{"error": "invalid_folder"})
		return
	}
	access, _, err := g.access(a.HouseholdID)
	if err != nil {
		jsonReply(w, 409, map[string]string{"error": "drive_reconnect_required"})
		return
	}
	var folder driveFile
	_, err = g.google("GET", "https://www.googleapis.com/drive/v3/files/"+url.PathEscape(in.ID)+"?fields=id,name,mimeType,webViewLink,trashed", access, "", nil, &folder)
	if err != nil || folder.Trashed || folder.MimeType != "application/vnd.google-apps.folder" {
		jsonReply(w, 422, map[string]string{"error": "folder_unavailable"})
		return
	}
	var out any
	if g.rpc("select_household_google_drive_folder", r.Header.Get("Authorization"), map[string]any{"folder_id": folder.ID, "folder_name": folder.Name, "web_view_link": folder.WebViewLink}, &out) != nil {
		jsonReply(w, 403, map[string]string{"error": "folder_select_failed"})
		return
	}
	jsonReply(w, 200, out)
}
func (g *driveGateway) upload(w http.ResponseWriter, r *http.Request) {
	a, err := g.auth(r, "authorize_google_drive_member", map[string]any{})
	if err != nil {
		jsonReply(w, 403, map[string]string{"error": "drive_not_available"})
		return
	}
	var in struct {
		Name     string `json:"name"`
		MimeType string `json:"mime_type"`
		Content  string `json:"content_base64"`
	}
	if decodeJSON(w, r, 8<<20, &in) != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if in.MimeType != "application/pdf" && in.MimeType != "image/jpeg" && in.MimeType != "image/png" {
		jsonReply(w, 422, map[string]string{"error": "unsupported_file"})
		return
	}
	content, err := base64.StdEncoding.DecodeString(in.Content)
	if err != nil || len(content) < 1 || len(content) > 5<<20 {
		jsonReply(w, 422, map[string]string{"error": "invalid_file_size"})
		return
	}
	access, _, err := g.access(a.HouseholdID)
	if err != nil {
		jsonReply(w, 409, map[string]string{"error": "drive_reconnect_required"})
		return
	}
	meta, _ := json.Marshal(map[string]any{"name": strings.TrimSpace(in.Name), "mimeType": in.MimeType, "parents": []string{a.FolderID}})
	boundary := "familydocuments-7MA4YWxk"
	var body bytes.Buffer
	fmt.Fprintf(&body, "--%s\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n%s\r\n--%s\r\nContent-Type: %s\r\n\r\n", boundary, meta, boundary, in.MimeType)
	body.Write(content)
	fmt.Fprintf(&body, "\r\n--%s--\r\n", boundary)
	var saved driveFile
	_, err = g.google("POST", "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,mimeType,size,modifiedTime,version,md5Checksum,webViewLink,parents", access, "multipart/related; boundary="+boundary, &body, &saved)
	if err != nil {
		jsonReply(w, 502, map[string]string{"error": "drive_upload_failed"})
		return
	}
	jsonReply(w, 200, map[string]any{"id": saved.ID, "name": saved.Name, "mimeType": saved.MimeType, "size": saved.Size, "modifiedTime": saved.ModifiedTime, "version": saved.Version, "md5Checksum": saved.MD5Checksum, "webViewLink": saved.WebViewLink, "parents": saved.Parents, "delete_token": g.deleteReceipt(a.UserID, saved.ID, time.Now().Add(10*time.Minute).Unix())})
}
func (g *driveGateway) remove(w http.ResponseWriter, r *http.Request) {
	a, err := g.auth(r, "authorize_google_drive_member", map[string]any{})
	if err != nil {
		jsonReply(w, 403, map[string]string{"error": "drive_not_available"})
		return
	}
	id := r.PathValue("id")
	if !g.validDeleteReceipt(r.URL.Query().Get("receipt"), a.UserID, id) {
		jsonReply(w, 403, map[string]string{"error": "delete_not_authorised"})
		return
	}
	access, _, err := g.access(a.HouseholdID)
	if err == nil && len(id) >= 10 && len(id) <= 200 {
		_, err = g.google("DELETE", "https://www.googleapis.com/drive/v3/files/"+url.PathEscape(id), access, "", nil, nil)
	}
	if err != nil {
		jsonReply(w, 502, map[string]string{"error": "drive_delete_failed"})
		return
	}
	jsonReply(w, 200, map[string]bool{"deleted": true})
}
func (g *driveGateway) open(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Document string `json:"document"`
	}
	if decodeJSON(w, r, 4096, &in) != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	a, err := g.auth(r, "authorize_google_drive_document", map[string]any{"document": in.Document})
	if err != nil {
		jsonReply(w, 404, map[string]string{"error": "source_not_found"})
		return
	}
	access, _, err := g.access(a.HouseholdID)
	if err != nil {
		jsonReply(w, 409, map[string]string{"error": "drive_reconnect_required"})
		return
	}
	var metadata driveFile
	_, err = g.google("GET", "https://www.googleapis.com/drive/v3/files/"+url.PathEscape(a.FileID)+"?fields=id,name,mimeType,size,parents,trashed", access, "", nil, &metadata)
	if err != nil || metadata.Trashed || !contains(metadata.Parents, a.FolderID) {
		jsonReply(w, 409, map[string]string{"error": "file_outside_connected_folder"})
		return
	}
	resp, err := g.google("GET", "https://www.googleapis.com/drive/v3/files/"+url.PathEscape(a.FileID)+"?alt=media", access, "", nil, nil)
	if err != nil {
		jsonReply(w, 502, map[string]string{"error": "drive_file_unavailable"})
		return
	}
	defer resp.Body.Close()
	content, err := io.ReadAll(io.LimitReader(resp.Body, (5<<20)+1))
	if err != nil || len(content) > 5<<20 {
		jsonReply(w, 422, map[string]string{"error": "drive_file_too_large"})
		return
	}
	jsonReply(w, 200, map[string]string{"file_name": a.FileName, "mime_type": a.MimeType, "content_base64": base64.StdEncoding.EncodeToString(content)})
}
func (g *driveGateway) disconnect(w http.ResponseWriter, r *http.Request) {
	a, err := g.auth(r, "authorize_google_drive_admin", map[string]any{})
	if err != nil {
		jsonReply(w, 403, map[string]string{"error": "mfa_and_admin_required"})
		return
	}
	_, refresh, _ := g.access(a.HouseholdID)
	if refresh != "" {
		resp, _ := g.http.PostForm("https://oauth2.googleapis.com/revoke", url.Values{"token": {refresh}})
		if resp != nil {
			resp.Body.Close()
		}
	}
	if g.rpc("revoke_google_drive_credential", g.serviceToken, map[string]any{"target_household": a.HouseholdID, "actor": a.UserID}, nil) != nil {
		jsonReply(w, 500, map[string]string{"error": "disconnect_failed"})
		return
	}
	jsonReply(w, 200, map[string]string{"status": "disconnected"})
}
