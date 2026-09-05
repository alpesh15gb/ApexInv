// Package api is the HTTP surface of the Apex Books sync server.
package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"apexbooks/syncserver/internal/store"
)

// ── Errors ──────────────────────────────────────────────────────────────

var (
	ErrBadRequest = errors.New("bad request")
	ErrNotFound   = errors.New("not found")
	ErrForbidden  = errors.New("forbidden")
)

// ── Auth (JWT) ──────────────────────────────────────────────────────────

// TokenTTL balances security against devices that are offline for weeks.
const TokenTTL = 90 * 24 * time.Hour

type Authenticator interface {
	Hash(password string) (string, error)
	Verify(hash, password string) bool
	Sign(userID string, issuedAt time.Time) (string, error)
	Parse(token string) (userID string, err error)
}

// ── Server ──────────────────────────────────────────────────────────────

type Server struct {
	Store *store.Store
	Auth  Authenticator
}

// Routes returns the fully wired handler.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		if err := s.Store.Pool().Ping(r.Context()); err != nil {
			writeErr(w, http.StatusServiceUnavailable, "database unavailable")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	// Auth — open.
	mux.HandleFunc("POST /auth/register", s.handleRegister)
	mux.HandleFunc("POST /auth/login", s.handleLogin)

	// Anonymous usage telemetry — open by design (must work for unlinked
	// installs). Payload is installation UUID + platform + version only.
	mux.HandleFunc("POST /api/heartbeat", s.handleHeartbeat)

	// License issuance: manual/distributor (authenticated) and automatic
	// via Razorpay webhook (HMAC-verified, no auth header by design).
	mux.Handle("POST /licenses/issue", s.requireAuth(http.HandlerFunc(s.handleIssueLicense)))
	mux.HandleFunc("POST /licenses/razorpay-webhook", s.handleRazorpayWebhook)

	// Authenticated.
	mux.Handle("POST /companies", s.requireAuth(http.HandlerFunc(s.handleCreateCompany)))
	mux.Handle("GET /companies", s.requireAuth(http.HandlerFunc(s.handleListCompanies)))
	mux.Handle("POST /privacy/purge/company/{companyId}", s.requireAuth(http.HandlerFunc(s.handlePurgeCompany)))
	mux.Handle("GET /sync/has-data/{companyId}", s.requireAuth(http.HandlerFunc(s.handleHasData)))
	mux.Handle("POST /sync/push/{companyId}", s.requireAuth(http.HandlerFunc(s.handlePush)))
	mux.Handle("POST /sync/pull/{companyId}", s.requireAuth(http.HandlerFunc(s.handlePull)))

	return mux
}

// ── Handlers: auth ──────────────────────────────────────────────────────

type credentials struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type authResponse struct {
	Token string       `json:"token"`
	User  userResponse `json:"user"`
}

type userResponse struct {
	ID    string `json:"id"`
	Email string `json:"email"`
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var cred credentials
	if err := json.NewDecoder(r.Body).Decode(&cred); err != nil || !validEmail(cred.Email) || len(cred.Password) < 8 {
		writeErr(w, http.StatusBadRequest, "valid email and 8+ char password required")
		return
	}
	hash, err := s.Auth.Hash(cred.Password)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "hash failure")
		return
	}
	u, err := s.Store.CreateUser(r.Context(), strings.ToLower(strings.TrimSpace(cred.Email)), hash)
	if errors.Is(err, store.ErrEmailTaken) {
		writeErr(w, http.StatusConflict, "email already registered")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "create user failed")
		return
	}
	token, err := s.Auth.Sign(u.ID, time.Now())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token failure")
		return
	}
	writeJSON(w, http.StatusCreated, authResponse{
		Token: token, User: userResponse{ID: u.ID, Email: u.Email}})
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var cred credentials
	if err := json.NewDecoder(r.Body).Decode(&cred); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	u, err := s.Store.UserByEmail(r.Context(), strings.ToLower(strings.TrimSpace(cred.Email)))
	if errors.Is(err, store.ErrNotFound) {
		// Same response as wrong-password to avoid account enumeration.
		writeErr(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "lookup failed")
		return
	}
	if !s.Auth.Verify(u.PasswordHash, cred.Password) {
		writeErr(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	token, err := s.Auth.Sign(u.ID, time.Now())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token failure")
		return
	}
	writeJSON(w, http.StatusOK, authResponse{
		Token: token, User: userResponse{ID: u.ID, Email: u.Email}})
}

// ── Handlers: telemetry ─────────────────────────────────────────────────

func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	var body struct {
		InstallationID string `json:"installationId"`
		Platform       string `json:"platform"`
		AppVersion     string `json:"appVersion"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	id := strings.TrimSpace(body.InstallationID)
	if id == "" || len(id) > 128 || len(body.Platform) > 64 || len(body.AppVersion) > 64 {
		writeErr(w, http.StatusBadRequest, "invalid heartbeat")
		return
	}
	// Store only the digest, never the raw installation ID.
	sum := sha256.Sum256([]byte(id))
	hash := hex.EncodeToString(sum[:])
	day := time.Now().UTC().Format("2006-01-02")
	if err := s.Store.RecordHeartbeat(r.Context(), hash,
		strings.TrimSpace(body.Platform), strings.TrimSpace(body.AppVersion), day); err != nil {
		log.Printf("heartbeat record failed: %v", err)
		writeErr(w, http.StatusInternalServerError, "heartbeat failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// ── Handlers: companies ─────────────────────────────────────────────────

func (s *Server) handleCreateCompany(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value(ctxUserID).(string)
	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || strings.TrimSpace(body.Name) == "" {
		writeErr(w, http.StatusBadRequest, "company name required")
		return
	}
	id, err := s.Store.CreateCompany(r.Context(), strings.TrimSpace(body.Name), userID)
	if err != nil {
		log.Printf("create company failed: %v", err)
		writeErr(w, http.StatusInternalServerError, "create company failed")
		return
	}
	writeJSON(w, http.StatusCreated, store.Company{ID: id, Name: strings.TrimSpace(body.Name)})
}

func (s *Server) handleListCompanies(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value(ctxUserID).(string)
	companies, err := s.Store.UserCompanies(r.Context(), userID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "list failed")
		return
	}
	if companies == nil {
		companies = []store.Company{}
	}
	writeJSON(w, http.StatusOK, companies)
}

func (s *Server) handlePurgeCompany(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value(ctxUserID).(string)
	companyID := r.PathValue("companyId")
	var req struct {
		CompanyName        *string `json:"companyName"`
		Password           *string `json:"password"`
		RetentionConfirmed *bool   `json:"retentionConfirmed"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.CompanyName == nil || req.Password == nil || req.RetentionConfirmed == nil || *req.CompanyName == "" || *req.Password == "" || !*req.RetentionConfirmed {
		writeErr(w, http.StatusBadRequest, "companyName, password, and retention confirmation required")
		return
	}

	ownerID, companyName, err := s.Store.CompanyOwnerAndName(r.Context(), companyID)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusForbidden, "only the company owner may purge it")
		return
	}
	if err != nil {
		log.Printf("company lookup failed: %v", err)
		writeErr(w, http.StatusInternalServerError, "company lookup failed")
		return
	}
	if ownerID != userID {
		writeErr(w, http.StatusForbidden, "only the company owner may purge it")
		return
	}
	u, err := s.Store.UserByID(r.Context(), userID)
	if err != nil {
		log.Printf("user lookup failed: %v", err)
		writeErr(w, http.StatusInternalServerError, "user lookup failed")
		return
	}
	if !s.Auth.Verify(u.PasswordHash, *req.Password) {
		writeErr(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	if companyName != *req.CompanyName {
		writeErr(w, http.StatusBadRequest, "company name confirmation does not match")
		return
	}

	if err := s.Store.DeleteCompanyData(r.Context(), companyID); err != nil {
		log.Printf("company purge failed: %v", err)
		writeErr(w, http.StatusInternalServerError, "company purge failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"success": true})
}

// ── Handlers: sync ──────────────────────────────────────────────────────

func (s *Server) handleHasData(w http.ResponseWriter, r *http.Request) {
	companyID := r.PathValue("companyId")
	if !s.authorized(r, w, companyID) {
		return
	}
	ok, err := s.Store.HasData(r.Context(), companyID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "has-data failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"hasData": ok})
}

type pushRequest struct {
	DeviceID string     `json:"deviceId"`
	Ops      []store.Op `json:"ops"`
}

func (s *Server) handlePush(w http.ResponseWriter, r *http.Request) {
	companyID := r.PathValue("companyId")
	if !s.authorized(r, w, companyID) {
		return
	}
	var req pushRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	if req.DeviceID == "" {
		req.DeviceID = store.NewDeviceID()
	}
	if len(req.Ops) > 5000 {
		writeErr(w, http.StatusRequestEntityTooLarge, "batch too large")
		return
	}
	res, err := s.Store.Push(r.Context(), companyID, req.DeviceID, req.Ops)
	if err != nil {
		log.Printf("push failed (company %s): %v", companyID, err)
		writeErr(w, http.StatusInternalServerError, "push failed")
		return
	}
	writeJSON(w, http.StatusOK, res)
}

type pullRequest struct {
	Table  string `json:"table"`
	Cursor string `json:"cursor"` // opaque "ts|pk" keyset token; "" = beginning
}

func (s *Server) handlePull(w http.ResponseWriter, r *http.Request) {
	companyID := r.PathValue("companyId")
	if !s.authorized(r, w, companyID) {
		return
	}
	var req pullRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	page, err := s.Store.Pull(r.Context(), companyID, req.Table, req.Cursor)
	if err != nil {
		if errors.Is(err, store.ErrInvalidCursor) {
			writeErr(w, http.StatusBadRequest, "invalid cursor")
			return
		}
		log.Printf("pull failed (company %s, table %s): %v", companyID, req.Table, err)
		writeErr(w, http.StatusInternalServerError, "pull failed")
		return
	}
	writeJSON(w, http.StatusOK, page)
}

// authorized checks membership and writes the error response itself.
func (s *Server) authorized(r *http.Request, w http.ResponseWriter, companyID string) bool {
	userID := r.Context().Value(ctxUserID).(string)
	ok, err := s.Store.MemberOf(r.Context(), userID, companyID)
	if err != nil || !ok {
		writeErr(w, http.StatusForbidden, "not a member of this company")
		return false
	}
	return true
}

// ── Middleware & helpers ────────────────────────────────────────────────

type ctxKey int

const ctxUserID ctxKey = 1

func (s *Server) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		token, ok := strings.CutPrefix(header, "Bearer ")
		if !ok || token == "" {
			writeErr(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		userID, err := s.Auth.Parse(token)
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "invalid token")
			return
		}
		ctx := context.WithValue(r.Context(), ctxUserID, userID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func validEmail(s string) bool {
	at := strings.Index(s, "@")
	return at > 0 && at < len(s)-1 && !strings.Contains(s, " ")
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
