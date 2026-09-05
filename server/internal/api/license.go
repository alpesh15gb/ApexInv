package api

import (
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// ── License issuance ────────────────────────────────────────────────────
// Keys are Ed25519-signed payloads verified offline by the app; the private
// seed lives only in LICENSE_PRIVATE_KEY on the server. Key format:
//   AB1.<base64url(payloadJSON)>.<base64url(signature)>
// with payload {"email":…,"exp":epoch|0,"iat":epoch,"plan":…,"seats":N,"v":1}
// (exp 0 = perpetual). Field order is fixed so signatures are deterministic.

// licenseSeed loads the Ed25519 private key from the environment.
func licenseSeed() (ed25519.PrivateKey, error) {
	raw := strings.TrimSpace(os.Getenv("LICENSE_PRIVATE_KEY"))
	if raw == "" {
		return nil, fmt.Errorf("LICENSE_PRIVATE_KEY not set")
	}
	seed, err := base64.StdEncoding.DecodeString(raw)
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("LICENSE_PRIVATE_KEY must be base64 32-byte seed")
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

// mintLicense signs a license payload. expEpoch 0 = perpetual.
func mintLicense(priv ed25519.PrivateKey, plan, email string, seats int, iat, expEpoch int64) string {
	payload := fmt.Sprintf(`{"email":%q,"exp":%d,"iat":%d,"plan":%q,"seats":%d,"v":1}`,
		email, expEpoch, iat, plan, seats)
	payloadB64 := base64.RawURLEncoding.EncodeToString([]byte(payload))
	sig := ed25519.Sign(priv, []byte(payloadB64))
	return "AB1." + payloadB64 + "." + base64.RawURLEncoding.EncodeToString(sig)
}

type issueLicenseRequest struct {
	Plan   string `json:"plan"`
	Email  string `json:"email"`
	Seats  int    `json:"seats"`
	Months int    `json:"months"` // 0 = perpetual
}

// handleIssueLicense mints a key directly. Authenticated (owner/distributor
// use); the automated path is the Razorpay webhook below.
func (s *Server) handleIssueLicense(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value(ctxUserID).(string)
	var req issueLicenseRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil ||
		strings.TrimSpace(req.Plan) == "" || req.Seats < 1 || req.Seats > 100 || req.Months < 0 {
		writeErr(w, http.StatusBadRequest, "plan, seats 1-100, months >= 0 required")
		return
	}
	priv, err := licenseSeed()
	if err != nil {
		log.Printf("license issue by %s failed: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "license signing unavailable")
		return
	}
	now := time.Now().UTC()
	var exp int64
	if req.Months > 0 {
		exp = now.AddDate(0, req.Months, 0).Unix()
	}
	email := strings.ToLower(strings.TrimSpace(req.Email))
	key := mintLicense(priv, strings.TrimSpace(req.Plan), email, req.Seats, now.Unix(), exp)
	if err := s.Store.RecordLicenseIssuance(r.Context(), email, req.Plan, req.Seats, keyPrefix(key)); err != nil {
		log.Printf("license issuance record failed: %v", err)
	}
	writeJSON(w, http.StatusCreated, map[string]string{"key": key})
}

func keyPrefix(key string) string {
	if len(key) > 12 {
		return key[:12]
	}
	return key
}

// ── Razorpay webhook → automatic key ─────────────────────────────────────
// Configure https://dashboard.razorpay.com → webhook to
// POST /licenses/razorpay-webhook with secret in RAZORPAY_WEBHOOK_SECRET.
// The Razorpay payment link / checkout must carry notes:
//   plan (e.g. "pro"), email, seats (default 1), months (default 12, 0 = perpetual).

func (s *Server) handleRazorpayWebhook(w http.ResponseWriter, r *http.Request) {
	secret := strings.TrimSpace(os.Getenv("RAZORPAY_WEBHOOK_SECRET"))
	if secret == "" {
		writeErr(w, http.StatusInternalServerError, "webhook not configured")
		return
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(raw)
	expected := hex.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(strings.TrimSpace(r.Header.Get("X-Razorpay-Signature"))), []byte(expected)) {
		writeErr(w, http.StatusUnauthorized, "bad signature")
		return
	}
	var event struct {
		Event   string `json:"event"`
		Payload struct {
			Payment struct {
				Entity struct {
					ID     string            `json:"id"`
					Status string            `json:"status"`
					Notes  map[string]string `json:"notes"`
				} `json:"entity"`
			} `json:"payment"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(raw, &event); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	// Acknowledge non-payment events without action.
	if !strings.HasPrefix(event.Event, "payment.") {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
		return
	}
	entity := event.Payload.Payment.Entity
	if entity.Status != "" && entity.Status != "captured" && entity.Status != "authorized" {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
		return
	}
	plan := strings.TrimSpace(entity.Notes["plan"])
	email := strings.ToLower(strings.TrimSpace(entity.Notes["email"]))
	if plan == "" || email == "" || !validEmail(email) {
		writeErr(w, http.StatusBadRequest, "payment notes must carry plan and email")
		return
	}
	seats := 1
	if n, err := fmt.Sscanf(strings.TrimSpace(entity.Notes["seats"]), "%d", &seats); err != nil || n != 1 || seats < 1 {
		seats = 1
	}
	if seats > 100 {
		seats = 100
	}
	months := 12
	if n, err := fmt.Sscanf(strings.TrimSpace(entity.Notes["months"]), "%d", &months); err != nil || n != 1 || months < 0 {
		months = 12
	}
	priv, err := licenseSeed()
	if err != nil {
		log.Printf("razorpay webhook %s: %v", entity.ID, err)
		writeErr(w, http.StatusInternalServerError, "license signing unavailable")
		return
	}
	now := time.Now().UTC()
	var exp int64
	if months > 0 {
		exp = now.AddDate(0, months, 0).Unix()
	}
	key := mintLicense(priv, plan, email, seats, now.Unix(), exp)
	if err := s.Store.RecordLicenseIssuance(r.Context(), email, plan, seats, keyPrefix(key)); err != nil {
		log.Printf("license issuance record failed: %v", err)
	}
	log.Printf("license issued via razorpay %s: %s plan=%s seats=%d", entity.ID, email, plan, seats)
	writeJSON(w, http.StatusOK, map[string]string{"key": key})
}
