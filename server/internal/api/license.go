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

	"apexbooks/syncserver/internal/store"
)

// ── License issuance ────────────────────────────────────────────────────
// Keys are Ed25519-signed payloads verified offline by the app; the private
// seed lives only in LICENSE_PRIVATE_KEY on the server. Key format:
//   AB1.<base64url(payloadJSON)>.<base64url(signature)>
// with payload {"email":…,"exp":epoch|0,"iat":epoch,"plan":…,"seats":N,"v":1}
// (exp 0 = perpetual). Field order is fixed so signatures are deterministic.
//
// Key rotation (2026-09-06, key-2026-09): the previous seed was treated as
// exposed and retired. The app now embeds the rotated public key; keys from
// the retired seed no longer verify. See server/LICENSE_ROTATION.md.

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

// licenseIssuerAllowlist parses LICENSE_ISSUER_ALLOWLIST (comma-separated
// emails, case-insensitive). Empty/missing = NOBODY may issue (deny by
// default — fail closed rather than letting any authenticated user mint).
func licenseIssuerAllowlist() map[string]bool {
	raw := strings.TrimSpace(os.Getenv("LICENSE_ISSUER_ALLOWLIST"))
	out := map[string]bool{}
	for _, part := range strings.Split(raw, ",") {
		e := strings.ToLower(strings.TrimSpace(part))
		if e != "" {
			out[e] = true
		}
	}
	return out
}

type issueLicenseRequest struct {
	Plan   string `json:"plan"`
	Email  string `json:"email"`
	Seats  int    `json:"seats"`
	Months int    `json:"months"` // 0 = perpetual
}

// handleIssueLicense mints a key directly. Authenticated + allowlisted
// (LICENSE_ISSUER_ALLOWLIST) only — distributors/support use; the automated
// path is the Razorpay webhook below. Denied by default.
func (s *Server) handleIssueLicense(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value(ctxUserID).(string)
	u, err := s.Store.UserByID(r.Context(), userID)
	if err != nil {
		log.Printf("license issue: user lookup failed: %v", err)
		writeErr(w, http.StatusForbidden, "license issuance restricted")
		return
	}
	if !licenseIssuerAllowlist()[strings.ToLower(strings.TrimSpace(u.Email))] {
		log.Printf("license issue denied for %s (not in LICENSE_ISSUER_ALLOWLIST)", u.Email)
		writeErr(w, http.StatusForbidden, "license issuance restricted")
		return
	}
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
// Configure https://dashboard.razorpay.com → Settings → Webhooks to
// POST https://api.apexbooks.in/licenses/razorpay-webhook with the secret
// stored in RAZORPAY_WEBHOOK_SECRET (see server/README.md "License payments
// (Razorpay)" for the exact dashboard steps).
// The Razorpay payment link / checkout must carry notes:
//   plan (e.g. "pro"), email, seats (default 1), months (default 12,
//   0 = perpetual), installation_id (optional, for support).
//
// Idempotency: Razorpay retries deliveries. Each processed event id is
// stored in razorpay_events (UNIQUE); redeliveries return the ORIGINAL key
// (duplicate:true) without minting again. The full key is stored in
// license_deliveries keyed by payment id for the "I already paid" retrieval
// endpoint below.

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
			PaymentLink struct {
				Entity struct {
					ID     string            `json:"id"`
					Status string            `json:"status"`
					Notes  map[string]string `json:"notes"`
				} `json:"entity"`
			} `json:"payment_link"`
			Order struct {
				Entity struct {
					ID     string            `json:"id"`
					Status string            `json:"status"`
					Notes  map[string]string `json:"notes"`
				} `json:"entity"`
			} `json:"order"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(raw, &event); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}
	// Acknowledge non-payment events without action.
	if !strings.HasPrefix(event.Event, "payment.") && !strings.HasPrefix(event.Event, "payment_link.") && !strings.HasPrefix(event.Event, "order.") {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
		return
	}
	payment := event.Payload.Payment.Entity
	linkNotes := event.Payload.PaymentLink.Entity.Notes
	orderNotes := event.Payload.Order.Entity.Notes
	// payment_link.paid carries the payment under payload.payment.entity
	// with notes on the link; fall back to link/order notes when the
	// payment itself has none.
	notes := payment.Notes
	if len(notes) == 0 {
		notes = linkNotes
	}
	if len(notes) == 0 {
		notes = orderNotes
	}
	if payment.ID == "" {
		// Nothing to fulfill (e.g. order.created notifications).
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
		return
	}
	if payment.Status != "" && payment.Status != "captured" && payment.Status != "authorized" && payment.Status != "paid" {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
		return
	}
	plan := strings.TrimSpace(notes["plan"])
	email := strings.ToLower(strings.TrimSpace(notes["email"]))
	if plan == "" || email == "" || !validEmail(email) {
		writeErr(w, http.StatusBadRequest, "payment notes must carry plan and email")
		return
	}
	seats := 1
	if n, err := fmt.Sscanf(strings.TrimSpace(notes["seats"]), "%d", &seats); err != nil || n != 1 || seats < 1 {
		seats = 1
	}
	if seats > 100 {
		seats = 100
	}
	months := 12
	if n, err := fmt.Sscanf(strings.TrimSpace(notes["months"]), "%d", &months); err != nil || n != 1 || months < 0 {
		months = 12
	}
	installationID := strings.TrimSpace(notes["installation_id"])
	if installationID == "" {
		installationID = strings.TrimSpace(notes["installationId"])
	}
	if len(installationID) > 128 {
		installationID = installationID[:128]
	}

	// Idempotency key: prefer Razorpay's event id header when present so
	// distinct events for the same payment stay distinguishable; fall back
	// to event+payment so retries without the header still dedupe.
	eventID := strings.TrimSpace(r.Header.Get("X-Razorpay-Event-Id"))
	if eventID == "" {
		eventID = event.Event + ":" + payment.ID
	}
	if len(eventID) > 256 {
		eventID = eventID[:256]
	}

	ctx := r.Context()
	if seen, err := s.Store.RazorpayEventSeen(ctx, eventID); err != nil {
		log.Printf("razorpay dedupe lookup failed: %v", err)
		writeErr(w, http.StatusInternalServerError, "dedupe lookup failed")
		return
	} else if seen {
		if d, found, err := s.Store.DeliveryByPayment(ctx, payment.ID); err == nil && found {
			writeJSON(w, http.StatusOK, map[string]interface{}{"key": d.Key, "duplicate": true})
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true, "duplicate": true})
		return
	}
	// Same payment retried under a NEW event id (header present on retry):
	// return the original key instead of minting a second one.
	if d, found, err := s.Store.DeliveryByPayment(ctx, payment.ID); err != nil {
		log.Printf("razorpay delivery lookup failed: %v", err)
		writeErr(w, http.StatusInternalServerError, "delivery lookup failed")
		return
	} else if found {
		_ = s.Store.RecordRazorpayEvent(ctx, eventID, payment.ID, email, keyPrefix(d.Key))
		writeJSON(w, http.StatusOK, map[string]interface{}{"key": d.Key, "duplicate": true})
		return
	}

	priv, err := licenseSeed()
	if err != nil {
		log.Printf("razorpay webhook %s: %v", payment.ID, err)
		writeErr(w, http.StatusInternalServerError, "license signing unavailable")
		return
	}
	now := time.Now().UTC()
	var exp int64
	if months > 0 {
		exp = now.AddDate(0, months, 0).Unix()
	}
	key := mintLicense(priv, plan, email, seats, now.Unix(), exp)
	if err := s.Store.RecordDelivery(ctx, store.LicenseDelivery{
		PaymentID: payment.ID, Email: email, InstallationID: installationID,
		Plan: plan, Seats: seats, Key: key,
	}); err != nil {
		log.Printf("license delivery record failed: %v", err)
	}
	if err := s.Store.RecordRazorpayEvent(ctx, eventID, payment.ID, email, keyPrefix(key)); err != nil {
		log.Printf("razorpay event record failed: %v", err)
	}
	if err := s.Store.RecordLicenseIssuance(ctx, email, plan, seats, keyPrefix(key)); err != nil {
		log.Printf("license issuance record failed: %v", err)
	}
	log.Printf("license issued via razorpay %s: %s plan=%s seats=%d", payment.ID, email, plan, seats)
	writeJSON(w, http.StatusOK, map[string]string{"key": key})
}

// ── Key retrieval ("I already paid") ─────────────────────────────────────
// GET|POST /licenses/retrieve?email=…&payment_id=… (POST accepts the same as
// JSON, plus optional installation_id for support logging). No account/JWT:
// knowledge of the exact (payment_id, purchase email) pair IS the credential
// (both are on the Razorpay receipt). Unknown pairs get 404 — identical for
// "no such payment" and "wrong email" so pairs cannot be enumerated by the
// difference.

func (s *Server) handleRetrieveLicense(w http.ResponseWriter, r *http.Request) {
	var email, paymentID string
	if r.Method == http.MethodPost {
		var body struct {
			Email          string `json:"email"`
			PaymentID      string `json:"payment_id"`
			PaymentIDCamel string `json:"paymentId"`
			InstallID      string `json:"installation_id"`
		}
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body)
		email = body.Email
		paymentID = body.PaymentID
		if paymentID == "" {
			paymentID = body.PaymentIDCamel
		}
	} else {
		q := r.URL.Query()
		email = q.Get("email")
		paymentID = q.Get("payment_id")
		if paymentID == "" {
			paymentID = q.Get("paymentId")
		}
	}
	email = strings.ToLower(strings.TrimSpace(email))
	paymentID = strings.TrimSpace(paymentID)
	if email == "" || paymentID == "" || !validEmail(email) || len(paymentID) > 128 {
		writeErr(w, http.StatusBadRequest, "email and payment_id required")
		return
	}
	d, found, err := s.Store.DeliveryByPayment(r.Context(), paymentID)
	if err != nil {
		log.Printf("license retrieve lookup failed: %v", err)
		writeErr(w, http.StatusInternalServerError, "lookup failed")
		return
	}
	if !found || !hmac.Equal([]byte(strings.ToLower(strings.TrimSpace(d.Email))), []byte(email)) {
		writeErr(w, http.StatusNotFound, "no key found for that email + payment id")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"key": d.Key, "plan": d.Plan, "email": d.Email,
	})
}
