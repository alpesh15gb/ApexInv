// Package store wraps the Postgres data access for the sync API.
package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var schemaSQL string

func init() {
	b, err := os.ReadFile("schema.sql")
	if err != nil {
		// Embedded at build time via Dockerfile COPY; fall back to the
		// literal in schema_sql.go for `go test` runs from the module root.
		b = []byte(embeddedSchemaSQL)
	}
	schemaSQL = string(b)
}

// Store is a Postgres-backed data store.
type Store struct {
	pool *pgxpool.Pool
}

// Sentinel errors surfaced to the API layer.
var (
	ErrEmailTaken    = errors.New("email already registered")
	ErrNotFound      = errors.New("not found")
	ErrInvalidCursor = errors.New("invalid cursor")
)

// Open connects, applies the schema idempotently, and returns the store.
func Open(ctx context.Context, url string) (*Store, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, err
	}
	if _, err := pool.Exec(ctx, schemaSQL); err != nil {
		pool.Close()
		return nil, err
	}
	return &Store{pool: pool}, nil
}

func (s *Store) Close() { s.pool.Close() }

// Pool exposes the underlying pool for tests and maintenance tooling.
func (s *Store) Pool() *pgxpool.Pool { return s.pool }

// ── Users / companies / memberships ─────────────────────────────────────

type User struct {
	ID           string
	Email        string
	PasswordHash string
}

func (s *Store) CreateUser(ctx context.Context, email, passwordHash string) (*User, error) {
	u := &User{Email: email, PasswordHash: passwordHash}
	err := s.pool.QueryRow(ctx,
		`INSERT INTO users (email, password_hash) VALUES ($1, $2) RETURNING id`,
		email, passwordHash).Scan(&u.ID)
	if isUniqueViolation(err) {
		return nil, ErrEmailTaken
	}
	return u, err
}

func (s *Store) UserByEmail(ctx context.Context, email string) (*User, error) {
	u := &User{Email: email}
	err := s.pool.QueryRow(ctx,
		`SELECT id, password_hash FROM users WHERE email = $1`, email).
		Scan(&u.ID, &u.PasswordHash)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return u, err
}

func (s *Store) CreateCompany(ctx context.Context, name, ownerID string) (string, error) {
	// memberships has no `id` column (PK is (user_id, company_id)), so the
	// outer RETURNING must name company_id — unqualified `id` resolves
	// against the INSERT target, not the CTE.
	var id string
	err := s.pool.QueryRow(ctx, `
		WITH c AS (
		  INSERT INTO companies (name, owner_id) VALUES ($1, $2) RETURNING id
		)
		INSERT INTO memberships (user_id, company_id, role)
		SELECT $2, c.id, 'owner' FROM c RETURNING company_id`, name, ownerID).Scan(&id)
	return id, err
}

// MemberOf reports whether userID belongs to companyID.
func (s *Store) MemberOf(ctx context.Context, userID, companyID string) (bool, error) {
	var ok bool
	err := s.pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM memberships WHERE user_id = $1 AND company_id = $2)`,
		userID, companyID).Scan(&ok)
	return ok, err
}

// UserCompanies lists (company_id, name) pairs the user belongs to.
func (s *Store) UserCompanies(ctx context.Context, userID string) ([]Company, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT c.id, c.name FROM companies c
		JOIN memberships m ON m.company_id = c.id
		WHERE m.user_id = $1 ORDER BY c.created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Company
	for rows.Next() {
		var c Company
		if err := rows.Scan(&c.ID, &c.Name); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

type Company struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// ── Sync ────────────────────────────────────────────────────────────────

// Op is one change arriving from (or leaving for) a device.
type Op struct {
	Table     string                 `json:"table"`
	RowPK     string                 `json:"rowPk"`
	Op        string                 `json:"op"` // "update" (upsert) or "delete"
	ChangedAt time.Time              `json:"changedAt"`
	// LwwAt is the client-clock arbitration key (authoring device's
	// updated_at / deleting device's changed_at). Nil on push — only pull
	// responses carry it.
	LwwAt    *time.Time             `json:"lwwAt,omitempty"`
	Payload  map[string]interface{} `json:"payload,omitempty"`
}

// PushResult is the receipt the engine already consumes (SyncPushReceipt).
type PushResult struct {
	ServerTime      time.Time          `json:"serverTime"`
	RejectedPKs     []string           `json:"rejectedPks"`
	CorrectedFields map[string]string  `json:"correctedFields"`
}

const lwwClamp = 60 * time.Second // future timestamps clamped to now+clamp

// Push applies a batch transactionally: LWW arbitration with the server
// clock as authority, tombstones for deletes, invoice-number collision
// reassignment. Idempotent per row — re-pushing the same state is a no-op.
func (s *Store) Push(ctx context.Context, companyID, deviceID string, ops []Op) (*PushResult, error) {
	res := &PushResult{ServerTime: time.Now().UTC(), CorrectedFields: map[string]string{}}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	maxTS := res.ServerTime.Add(lwwClamp)

	for _, op := range ops {
		changedAt := op.ChangedAt
		if changedAt.After(maxTS) {
			changedAt = maxTS // clamp skewed device clocks
		}

		if op.Op == "delete" {
			tag, err := tx.Exec(ctx,
				`DELETE FROM records WHERE company_id=$1 AND table_name=$2 AND row_pk=$3
				 AND updated_at <= $4`,
				companyID, op.Table, op.RowPK, changedAt)
			if err != nil {
				return nil, err
			}
			// Tombstone only if the delete wins LWW (or the row never existed).
			if tag.RowsAffected() == 0 {
				var exists bool
				err := tx.QueryRow(ctx,
					`SELECT EXISTS (SELECT 1 FROM records WHERE company_id=$1 AND table_name=$2 AND row_pk=$3)`,
					companyID, op.Table, op.RowPK).Scan(&exists)
				if err != nil {
					return nil, err
				}
				if exists {
					res.RejectedPKs = append(res.RejectedPKs, op.RowPK) // newer row kept
					continue
				}
			}
			// Keep the deleting device's changed_at: it is the LWW key a
			// pulling client arbitrates against (server receive clock and the
			// clients' local clocks can be skewed — mixing domains silently
			// drops deletes).
			_, err = tx.Exec(ctx,
				`INSERT INTO tombstones (company_id, table_name, row_pk, client_changed_at, server_updated_at)
				 VALUES ($1,$2,$3,$4,$5)
				 ON CONFLICT (company_id, table_name, row_pk)
				 DO UPDATE SET client_changed_at = EXCLUDED.client_changed_at,
				   server_updated_at = EXCLUDED.server_updated_at`,
				companyID, op.Table, op.RowPK, changedAt, res.ServerTime)
			if err != nil {
				return nil, err
			}
			continue
		}

		// Upsert path. LWW: incoming must be strictly newer than stored.
		var storedAt *time.Time
		err := tx.QueryRow(ctx,
			`SELECT updated_at FROM records WHERE company_id=$1 AND table_name=$2 AND row_pk=$3`,
			companyID, op.Table, op.RowPK).Scan(&storedAt)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		if storedAt != nil && !changedAt.After(*storedAt) {
			res.RejectedPKs = append(res.RejectedPKs, op.RowPK) // stale, keep server row
			continue
		}

		// Invoice-number collision (dbplan §3.1): later arrival is reassigned.
		if op.Table == "invoices" {
			if invNo, _ := op.Payload["invoice_number"].(string); invNo != "" {
				typ, _ := op.Payload["type"].(string)
				var otherPK *string
				err := tx.QueryRow(ctx,
					`SELECT row_pk FROM records
					 WHERE company_id=$1 AND table_name='invoices'
					   AND data->>'type'=$2 AND data->>'invoice_number'=$3
					   AND row_pk <> $4 LIMIT 1`,
					companyID, typ, invNo, op.RowPK).Scan(&otherPK)
				if err != nil && !errors.Is(err, pgx.ErrNoRows) {
					return nil, err
				}
				if otherPK != nil {
					// Never reassign against a legacy global-sequence id: those
					// share numbers across types. Only true invoice_number rows.
					fixed, err := s.reassignInvoiceNumber(ctx, tx, companyID, typ, op.RowPK, invNo)
					if err != nil {
						return nil, err
					}
					op.Payload["invoice_number"] = fixed
					res.CorrectedFields[op.RowPK] = fixed
				}
			}
		}

		_, err = tx.Exec(ctx,
			`INSERT INTO records (company_id, table_name, row_pk, data, updated_at, origin_device)
			 VALUES ($1,$2,$3,$4,$5,$6)
			 ON CONFLICT (company_id, table_name, row_pk)
			 DO UPDATE SET data = EXCLUDED.data, updated_at = EXCLUDED.updated_at,
			   server_updated_at = now(), origin_device = EXCLUDED.origin_device`,
			companyID, op.Table, op.RowPK, op.Payload, changedAt, deviceID)
		if err != nil {
			return nil, err
		}
		// A resurrection after a tombstone clears the tombstone so the row
		// participates in pulls again.
		_, _ = tx.Exec(ctx,
			`DELETE FROM tombstones WHERE company_id=$1 AND table_name=$2 AND row_pk=$3`,
			companyID, op.Table, op.RowPK)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return res, nil
}

// reassignInvoiceNumber finds the next free number for type after current max.
func (s *Store) reassignInvoiceNumber(ctx context.Context, tx pgx.Tx, companyID, typ, rowPK, current string) (string, error) {
	var maxNo *int
	err := tx.QueryRow(ctx,
		`SELECT MAX(NULLIF(regexp_replace(data->>'invoice_number', '\D', '', 'g'), '')::bigint)
		 FROM records
		 WHERE company_id=$1 AND table_name='invoices' AND data->>'type'=$2
		   AND data->>'invoice_number' ~ '^[0-9]+$'`,
		companyID, typ).Scan(&maxNo)
	if err != nil {
		return "", err
	}
	next := 1
	if maxNo != nil {
		next = int(*maxNo) + 1
	}
	// Zero-pad to the app's 8-digit invoice-number convention.
	num := itoa(next)
	for len(num) < 8 {
		num = "0" + num
	}
	return num, nil
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// PullPage is one page of server changes for a table.
type PullPage struct {
	Ops []Op `json:"ops"`
	// NextCursor is opaque: "<RFC3339Nano>|<row_pk>" — the (ts, pk) keyset
	// position to resume from. The pk tiebreaker exists because a single
	// push batch commits in ONE transaction, so every row in the batch
	// shares the same server_updated_at (now() is transaction-start); a
	// ts-only cursor skipped every same-ts row beyond the first page.
	NextCursor string `json:"nextCursor"`
	HasMore    bool   `json:"hasMore"`
}

const pullPageSize = 500

// Pull returns rows and tombstones for table changed after cursor.
func (s *Store) Pull(ctx context.Context, companyID, table string, rawCursor string) (*PullPage, error) {
	page := &PullPage{Ops: []Op{}}

	// Parse the opaque cursor: "ts|pk" (current) or bare "ts" (legacy).
	var cursor time.Time
	var cursorPK string
	if rawCursor != "" {
		tsPart := rawCursor
		if i := strings.LastIndex(rawCursor, "|"); i >= 0 {
			tsPart = rawCursor[:i]
			cursorPK = rawCursor[i+1:]
		}
		var err error
		cursor, err = time.Parse(time.RFC3339Nano, tsPart)
		if err != nil {
			return nil, ErrInvalidCursor
		}
	}

	// Server_updated_at (receive clock) drives the filter and the cursor:
	// it is the only monotone, single-clock-domain quantity here. Returning
	// updated_at (client clocks) as cursor once produced a cursor AHEAD of
	// later arrivals' receive stamps — silently hiding rows.
	//
	// LwwAt carries the *client-clock* arbitration key instead: for records
	// the pushing device's updated_at, for tombstones the deleting device's
	// changed_at. Pull-side LWW must compare same-domain stamps — the local
	// row's updated_at (this device's clock) against the authoring device's
	// stamp. Arbitrating against server_updated_at silently drops deletes
	// when the pulling device's clock runs ahead of the server's.
	//
	// Keyset pagination on (server_updated_at, row_pk): deterministic order
	// with a unique tiebreaker, so same-timestamp batches never skip rows.
	rows, err := s.pool.Query(ctx, `
		SELECT * FROM (
		  (SELECT row_pk, data, server_updated_at, updated_at FROM records
		    WHERE company_id=$1 AND table_name=$2
		      AND (server_updated_at, row_pk) > ($3, $4)
		    LIMIT $5)
		  UNION ALL
		  (SELECT row_pk, NULL, server_updated_at, client_changed_at FROM tombstones
		    WHERE company_id=$1 AND table_name=$2
		      AND (server_updated_at, row_pk) > ($3, $4)
		    LIMIT $5)
		) u
		ORDER BY server_updated_at, row_pk
		LIMIT $5`,
		companyID, table, cursor, cursorPK, pullPageSize+1)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var pk string
		var data map[string]interface{}
		var ts, lwwAt *time.Time
		if err := rows.Scan(&pk, &data, &ts, &lwwAt); err != nil {
			return nil, err
		}
		op := Op{Table: table, RowPK: pk, ChangedAt: *ts, LwwAt: lwwAt}
		if data == nil {
			op.Op = "delete"
		} else {
			op.Op = "update"
			op.Payload = data
		}
		page.Ops = append(page.Ops, op)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	if len(page.Ops) > pullPageSize {
		page.Ops = page.Ops[:pullPageSize]
		page.HasMore = true
	}
	// An empty page must not advance the cursor: keep the caller's cursor
	// verbatim so the next poll re-checks.
	if len(page.Ops) > 0 {
		last := page.Ops[len(page.Ops)-1]
		page.NextCursor = last.ChangedAt.UTC().Format(time.RFC3339Nano) + "|" + last.RowPK
	} else {
		page.NextCursor = rawCursor
	}
	return page, nil
}

// HasData reports whether any business rows exist for the company — decides
// pull-before-baseline on first link (dbplan §3.5).
func (s *Store) HasData(ctx context.Context, companyID string) (bool, error) {
	var ok bool
	err := s.pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM records WHERE company_id = $1)`, companyID).Scan(&ok)
	return ok, err
}

// ── helpers ─────────────────────────────────────────────────────────────

func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	var pgErr interface{ SQLState() string }
	if errors.As(err, &pgErr) {
		return pgErr.SQLState() == "23505"
	}
	return false
}

// NewDeviceID produces a random device identifier for push receipts.
func NewDeviceID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
