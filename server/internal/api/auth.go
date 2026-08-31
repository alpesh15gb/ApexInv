package api

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/argon2"
)

// ── Argon2id password hashing ───────────────────────────────────────────

const (
	argonTime    = 2
	argonMemory  = 64 * 1024 // 64 MB
	argonThreads = 2
	argonKeyLen  = 32
	argonSaltLen = 16
)

// Argon2Auth implements Authenticator with argon2id hashing and HMAC-SHA256
// JWTs (HS256 — sufficient for a single-server deployment; the secret comes
// from JWT_SECRET env).
type Argon2Auth struct{ jwtSecret []byte }

func NewArgon2Auth() (*Argon2Auth, error) {
	secret := os.Getenv("JWT_SECRET")
	if secret == "" {
		// Generate one for dev; production compose sets JWT_SECRET explicitly.
		b := make([]byte, 32)
		if _, err := randRead(b); err != nil {
			return nil, err
		}
		secret = base64.RawURLEncoding.EncodeToString(b)
	}
	return &Argon2Auth{jwtSecret: []byte(secret)}, nil
}

func (a *Argon2Auth) Hash(password string) (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := randRead(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	return "$argon2id$v=19$m=" + itoa(argonMemory) + ",t=" + itoa(argonTime) + ",p=" + itoa(argonThreads) +
		"$" + base64.RawStdEncoding.EncodeToString(salt) +
		"$" + base64.RawStdEncoding.EncodeToString(key), nil
}

func (a *Argon2Auth) Verify(encodedHash, password string) bool {
	parts := strings.Split(encodedHash, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return false
	}
	var m, t uint32
	var p uint8
	if _, err := sscanfParams(parts[3], &m, &t, &p); err != nil {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return false
	}
	key, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return false
	}
	candidate := argon2.IDKey([]byte(password), salt, t, m, p, uint32(len(key)))
	return hmac.Equal(candidate, key)
}

func sscanfParams(s string, m *uint32, t *uint32, p *uint8) (int, error) {
	n, err := parseParams(s, m, t, p)
	return n, err
}

func parseParams(s string, m *uint32, t *uint32, p *uint8) (int, error) {
	for _, kv := range strings.Split(s, ",") {
		parts := strings.SplitN(kv, "=", 2)
		if len(parts) != 2 {
			return 0, errors.New("bad param")
		}
		var v int
		for _, c := range parts[1] {
			if c < '0' || c > '9' {
				return 0, errors.New("bad number")
			}
			v = v*10 + int(c-'0')
		}
		switch parts[0] {
		case "m":
			*m = uint32(v)
		case "t":
			*t = uint32(v)
		case "p":
			*p = uint8(v)
		}
	}
	return 3, nil
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

// ── JWT (HS256) ─────────────────────────────────────────────────────────

type jwtClaims struct {
	Sub string `json:"sub"`
	Exp int64  `json:"exp"`
	Iat int64  `json:"iat"`
}

func (a *Argon2Auth) Sign(userID string, issuedAt time.Time) (string, error) {
	claims := jwtClaims{
		Sub: userID,
		Iat: issuedAt.Unix(),
		Exp: issuedAt.Add(TokenTTL).Unix(),
	}
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	payloadBytes, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	payload := base64.RawURLEncoding.EncodeToString(payloadBytes)
	signing := header + "." + payload
	mac := hmac.New(sha256.New, a.jwtSecret)
	mac.Write([]byte(signing))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return signing + "." + sig, nil
}

func (a *Argon2Auth) Parse(token string) (string, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", errors.New("malformed token")
	}
	signing := parts[0] + "." + parts[1]
	mac := hmac.New(sha256.New, a.jwtSecret)
	mac.Write([]byte(signing))
	expected, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return "", errors.New("bad signature encoding")
	}
	if !hmac.Equal(mac.Sum(nil), expected) {
		return "", errors.New("signature mismatch")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", errors.New("bad payload encoding")
	}
	var claims jwtClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return "", errors.New("bad claims")
	}
	if time.Now().Unix() > claims.Exp {
		return "", errors.New("token expired")
	}
	if claims.Sub == "" {
		return "", errors.New("missing subject")
	}
	return claims.Sub, nil
}
