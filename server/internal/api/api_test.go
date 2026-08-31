package api_test

// Integration tests for the sync API. They require a live Postgres via
// DATABASE_URL and are skipped otherwise:
//
//	$env:DATABASE_URL = "postgres://apexbooks:pw@localhost:5432/apexbooks_test?sslmode=disable"
//	go test ./internal/api/ -v
//
// The suite exercises the exact contract the Flutter SyncEngine tests
// assert (test/sync_engine_test.dart): auth, membership authorization,
// push/pull round-trip, LWW arbitration, tombstones, cursor pagination,
// and invoice-number collision reassignment.
import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"apexbooks/syncserver/internal/api"
	"apexbooks/syncserver/internal/store"
)

const testDBURL = "postgres://apexbooks:pw@localhost:5432/apexbooks_test?sslmode=disable"

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set; integration test skipped")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	st, err := store.Open(ctx, testDBURLForTest(dbURL))
	if err != nil {
		t.Fatalf("store open: %v", err)
	}
	auth, err := api.NewArgon2Auth()
	if err != nil {
		t.Fatalf("auth: %v", err)
	}
	srv := httptest.NewServer((&api.Server{Store: st, Auth: auth}).Routes())
	t.Cleanup(func() {
		srv.Close()
		st.Close()
		// Wipe the test database between suites.
		_, _ = st.Pool().Exec(context.Background(),
			`TRUNCATE users, companies, memberships, records, tombstones CASCADE`)
	})
	return srv
}

func testDBURLForTest(env string) string {
	// Tests may run against a different DB name; default to apexbooks_test.
	if os.Getenv("TEST_DATABASE_URL") != "" {
		return os.Getenv("TEST_DATABASE_URL")
	}
	return testDBURL
}

// ── tiny client helpers ─────────────────────────────────────────────────

func postJSON(t *testing.T, srv *httptest.Server, path, token string, body interface{}) (*http.Response, map[string]interface{}) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", srv.URL+path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer res.Body.Close()
	var out map[string]interface{}
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res, out
}

func getJSON(t *testing.T, srv *httptest.Server, path, token string) (*http.Response, map[string]interface{}) {
	t.Helper()
	req, _ := http.NewRequest("GET", srv.URL+path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer res.Body.Close()
	var out map[string]interface{}
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res, out
}

func getList(t *testing.T, srv *httptest.Server, path, token string) []interface{} {
	t.Helper()
	req, _ := http.NewRequest("GET", srv.URL+path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer res.Body.Close()
	var out []interface{}
	_ = json.NewDecoder(res.Body).Decode(&out)
	return out
}

// registerAndLogin creates a user and returns the token.
func registerAndLogin(t *testing.T, srv *httptest.Server, email string) string {
	t.Helper()
	res, body := postJSON(t, srv, "/auth/register", "", map[string]string{
		"email": email, "password": "password-123"})
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("register failed: %d %v", res.StatusCode, body)
	}
	return body["token"].(string)
}

func createCompany(t *testing.T, srv *httptest.Server, token, name string) string {
	t.Helper()
	res, body := postJSON(t, srv, "/companies", token, map[string]string{"name": name})
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("create company failed: %d %v", res.StatusCode, body)
	}
	return body["id"].(string)
}

func push(t *testing.T, srv *httptest.Server, token, company string, ops []store.Op) (int, map[string]interface{}) {
	t.Helper()
	res, body := postJSON(t, srv, "/sync/push/"+company, token, map[string]interface{}{
		"deviceId": "test-device", "ops": ops})
	return res.StatusCode, body
}

func pull(t *testing.T, srv *httptest.Server, token, company, table, cursor string) map[string]interface{} {
	t.Helper()
	_, body := postJSON(t, srv, "/sync/pull/"+company, token, map[string]string{
		"table": table, "cursor": cursor})
	return body
}

func op(table, pk, opType string, changedAt time.Time, payload map[string]interface{}) store.Op {
	return store.Op{Table: table, RowPK: pk, Op: opType, ChangedAt: changedAt, Payload: payload}
}

// ── Auth & membership ───────────────────────────────────────────────────

func TestRegisterLoginCompany(t *testing.T) {
	srv := newTestServer(t)

	res, _ := postJSON(t, srv, "/auth/register", "", map[string]string{
		"email": "a@x.com", "password": "short"})
	if res.StatusCode != http.StatusBadRequest {
		t.Fatalf("short password accepted: %d", res.StatusCode)
	}

	token := registerAndLogin(t, srv, "user-a@x.com")

	// Duplicate email is rejected.
	res, _ = postJSON(t, srv, "/auth/register", "", map[string]string{
		"email": "user-a@x.com", "password": "password-123"})
	if res.StatusCode != http.StatusConflict {
		t.Fatalf("duplicate email accepted: %d", res.StatusCode)
	}

	// Login works and returns a token.
	res, body := postJSON(t, srv, "/auth/login", "", map[string]string{
		"email": "user-a@x.com", "password": "password-123"})
	if res.StatusCode != http.StatusOK {
		t.Fatalf("login failed: %d %v", res.StatusCode, body)
	}

	// Wrong password rejected.
	res, _ = postJSON(t, srv, "/auth/login", "", map[string]string{
		"email": "user-a@x.com", "password": "wrong-password"})
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong password accepted: %d", res.StatusCode)
	}

	company := createCompany(t, srv, token, "Test Co")
	if company == "" {
		t.Fatal("no company id")
	}

	// Listed companies include it.
	list := getList(t, srv, "/companies", token)
	if len(list) != 1 {
		t.Fatalf("expected 1 company, got %v", list)
	}
}

func TestAuthorizationRequiresMembership(t *testing.T) {
	srv := newTestServer(t)
	tokenA := registerAndLogin(t, srv, "owner@x.com")
	tokenB := registerAndLogin(t, srv, "intruder@x.com")
	company := createCompany(t, srv, tokenA, "A Co")

	// B cannot read A's sync data.
	res, _ := getJSON(t, srv, "/sync/has-data/"+company, tokenB)
	if res.StatusCode != http.StatusForbidden {
		t.Fatalf("intruder got has-data: %d", res.StatusCode)
	}

	// B cannot push into A's company.
	code, _ := push(t, srv, tokenB, company, []store.Op{
		op("customers", "c1", "update", time.Now(), map[string]interface{}{"name": "evil"})})
	if code != http.StatusForbidden {
		t.Fatalf("intruder pushed: %d", code)
	}

	// No token at all → 401.
	res, _ = getJSON(t, srv, "/sync/has-data/"+company, "")
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no-token request accepted: %d", res.StatusCode)
	}
}

// ── Sync contract ───────────────────────────────────────────────────────

func TestPushPullRoundTrip(t *testing.T) {
	srv := newTestServer(t)
	token := registerAndLogin(t, srv, "sync@x.com")
	company := createCompany(t, srv, token, "Sync Co")

	t0 := time.Now().UTC().Add(-time.Minute)
	code, body := push(t, srv, token, company, []store.Op{
		op("customers", "c-1", "update", t0, map[string]interface{}{
			"id": "c-1", "name": "Alice", "updated_at": t0.Format(time.RFC3339Nano)}),
	})
	if code != http.StatusOK {
		t.Fatalf("push failed: %d %v", code, body)
	}
	if rejected, ok := body["rejectedPks"].([]interface{}); ok && len(rejected) > 0 {
		t.Fatalf("unexpected rejections: %v", rejected)
	}

	// has-data flips true.
	_, hb := getJSON(t, srv, "/sync/has-data/"+company, token)
	if hb["hasData"] != true {
		t.Fatalf("hasData = %v", hb)
	}

	// Pull returns the row with a cursor.
	page := pull(t, srv, token, company, "customers", "")
	ops := page["ops"].([]interface{})
	if len(ops) != 1 {
		t.Fatalf("expected 1 op, got %v", page)
	}
	first := ops[0].(map[string]interface{})
	if first["op"] != "update" {
		t.Fatalf("expected update, got %v", first)
	}
	cursor := page["nextCursor"].(string)

	// Empty incremental pull after cursor.
	page = pull(t, srv, token, company, "customers", cursor)
	if len(page["ops"].([]interface{})) != 0 {
		t.Fatalf("incremental pull returned rows: %v", page)
	}
}

func TestLWWArbitration(t *testing.T) {
	srv := newTestServer(t)
	token := registerAndLogin(t, srv, "lww@x.com")
	company := createCompany(t, srv, token, "LWW Co")

	base := time.Now().UTC().Add(-time.Hour)

	// Older write first.
	code, _ := push(t, srv, token, company, []store.Op{
		op("products", "p-1", "update", base, map[string]interface{}{"name": "old"})})
	if code != http.StatusOK {
		t.Fatal("push1 failed")
	}
	// Stale push (older timestamp) must be rejected.
	_, body := push(t, srv, token, company, []store.Op{
		op("products", "p-1", "update", base.Add(-time.Minute), map[string]interface{}{"name": "stale"})})
	rejected := body["rejectedPks"].([]interface{})
	if len(rejected) != 1 || rejected[0] != "p-1" {
		t.Fatalf("stale push not rejected: %v", body)
	}
	// Newer push wins.
	_, body = push(t, srv, token, company, []store.Op{
		op("products", "p-1", "update", base.Add(time.Minute), map[string]interface{}{"name": "new"})})
	if rejected, ok := body["rejectedPks"].([]interface{}); ok && len(rejected) > 0 {
		t.Fatalf("newer push rejected: %v", body)
	}

	page := pull(t, srv, token, company, "products", "")
	ops := page["ops"].([]interface{})
	if len(ops) != 1 {
		t.Fatalf("expected 1 op, got %d", len(ops))
	}
	payload := ops[0].(map[string]interface{})["payload"].(map[string]interface{})
	if payload["name"] != "new" {
		t.Fatalf("LWW loser won: %v", payload)
	}
}

func TestFutureTimestampClamped(t *testing.T) {
	srv := newTestServer(t)
	token := registerAndLogin(t, srv, "clock@x.com")
	company := createCompany(t, srv, token, "Skew Co")

	// A device with a year-fast clock: its next (honest) push must still win.
	future := time.Now().UTC().Add(365 * 24 * time.Hour)
	push(t, srv, token, company, []store.Op{
		op("customers", "c-skew", "update", future, map[string]interface{}{"name": "skewed"})})

	code, body := push(t, srv, token, company, []store.Op{
		op("customers", "c-skew", "update", time.Now().UTC(),
			map[string]interface{}{"name": "honest"})})
	if code != http.StatusOK {
		t.Fatal("honest push failed")
	}
	// Without clamping the honest push would be rejected as stale.
	if rejected, ok := body["rejectedPks"].([]interface{}); ok && len(rejected) > 0 {
		t.Fatalf("clamp failed, honest push rejected: %v", body)
	}
}

func TestTombstonesPropagate(t *testing.T) {
	srv := newTestServer(t)
	token := registerAndLogin(t, srv, "tomb@x.com")
	company := createCompany(t, srv, token, "Tomb Co")

	t0 := time.Now().UTC().Add(-time.Hour)
	push(t, srv, token, company, []store.Op{
		op("customers", "c-del", "update", t0, map[string]interface{}{"name": "Dave"})})

	// Delete wins over older row.
	_, body := push(t, srv, token, company, []store.Op{
		op("customers", "c-del", "delete", t0.Add(time.Minute), nil)})
	if rejected, ok := body["rejectedPks"].([]interface{}); ok && len(rejected) > 0 {
		t.Fatalf("delete rejected: %v", body)
	}

	// Pull delivers a delete op.
	page := pull(t, srv, token, company, "customers", "")
	ops := page["ops"].([]interface{})
	if len(ops) != 1 || ops[0].(map[string]interface{})["op"] != "delete" {
		t.Fatalf("expected tombstone op, got %v", page)
	}

	// Newer upsert after delete resurrects (and clears the tombstone).
	push(t, srv, token, company, []store.Op{
		op("customers", "c-del", "update", t0.Add(2*time.Minute),
			map[string]interface{}{"name": "Dave back"})})
	page = pull(t, srv, token, company, "customers", "")
	ops = page["ops"].([]interface{})
	if len(ops) != 1 || ops[0].(map[string]interface{})["op"] != "update" {
		t.Fatalf("resurrection not delivered: %v", page)
	}
}

func TestInvoiceNumberCollisionReassigned(t *testing.T) {
	srv := newTestServer(t)
	token := registerAndLogin(t, srv, "invno@x.com")
	company := createCompany(t, srv, token, "Inv Co")

	t0 := time.Now().UTC().Add(-time.Hour)
	inv := func(pk, number string) store.Op {
		return op("invoices", pk, "update", t0, map[string]interface{}{
			"id": pk, "type": "Invoice", "invoice_number": number, "total": 100.0})
	}

	// Two devices push the same number for the same type.
	code, body := push(t, srv, token, company, []store.Op{inv("inv-1", "00000001")})
	if code != http.StatusOK {
		t.Fatal("push1 failed")
	}
	code, body = push(t, srv, token, company, []store.Op{inv("inv-2", "00000001")})
	if code != http.StatusOK {
		t.Fatal("push2 failed")
	}
	corrected, ok := body["correctedFields"].(map[string]interface{})
	if !ok || corrected["inv-2"] == "" {
		t.Fatalf("collision not corrected: %v", body)
	}
	if corrected["inv-2"] != "00000002" {
		t.Fatalf("expected reassignment to 00000002, got %v", corrected)
	}

	// Different types may share a number (legacy global sequence parity).
	push(t, srv, token, company, []store.Op{
		op("invoices", "q-1", "update", t0, map[string]interface{}{
			"id": "q-1", "type": "Quotation", "invoice_number": "00000001"})})
	_, body = push(t, srv, token, company, []store.Op{
		op("invoices", "q-2", "update", t0, map[string]interface{}{
			"id": "q-2", "type": "Quotation", "invoice_number": "00000001"})})
	if corrected, ok := body["correctedFields"].(map[string]interface{}); ok && len(corrected) > 0 {
		t.Fatalf("quotation number wrongly reassigned: %v", body)
	}
}

func TestCursorPagination(t *testing.T) {
	srv := newTestServer(t)
	token := registerAndLogin(t, srv, "page@x.com")
	company := createCompany(t, srv, token, "Page Co")

	base := time.Now().UTC().Add(-time.Hour)
	// 30 rows; page size is 500 so all arrive in one page, but the cursor
	// arithmetic is verified precisely.
	var ops []store.Op
	for i := 0; i < 30; i++ {
		ops = append(ops, op("customers", fmt.Sprintf("c-%02d", i), "update",
			base.Add(time.Duration(i)*time.Second),
			map[string]interface{}{"name": fmt.Sprintf("C%d", i)}))
	}
	push(t, srv, token, company, ops)

	page := pull(t, srv, token, company, "customers", "")
	if got := len(page["ops"].([]interface{})); got != 30 {
		t.Fatalf("expected 30 ops, got %d", got)
	}
	if page["hasMore"] != false {
		t.Fatalf("hasMore true on drained table: %v", page)
	}

	// Pulling with a mid-stream cursor returns only later rows.
	midCursor := base.Add(15 * time.Second).Format(time.RFC3339Nano)
	page = pull(t, srv, token, company, "customers", midCursor)
	if got := len(page["ops"].([]interface{})); got != 14 {
		t.Fatalf("expected 14 ops after mid cursor, got %d", got)
	}
}
