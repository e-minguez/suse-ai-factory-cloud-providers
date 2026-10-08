// Package sshkeys parses, validates, fetches and generates SSH public keys.
package sshkeys

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

var (
	ErrPrivateKey = errors.New("this looks like a private key; paste the public key (.pub) instead")
	ErrNoKeys     = errors.New("no public keys found")
	ErrBadUser    = errors.New("invalid GitHub user name")
)

// githubBase is overridden by tests only.
var githubBase = "https://github.com"

const fetchLimit = 64 << 10

var userRe = regexp.MustCompile(`^[A-Za-z0-9-]{1,39}$`)

// Key is one authorized_keys line with derived metadata.
type Key struct {
	Line, Type, Fingerprint, Comment, Source string
	Bits, Size                               int
}

// Parse reads one key per line, skipping blanks and # comments.
func Parse(text, source string) ([]Key, error) {
	if strings.Contains(text, "PRIVATE KEY") {
		return nil, ErrPrivateKey
	}
	var keys []Key
	for i, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, err := parseLine(line, source)
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", i+1, err)
		}
		keys = append(keys, k)
	}
	return keys, nil
}

func parseLine(line, source string) (Key, error) {
	pub, comment, opts, _, err := ssh.ParseAuthorizedKey([]byte(line))
	if err != nil {
		return Key{}, errors.New("not a valid SSH public key")
	}
	if len(opts) > 0 {
		return Key{}, errors.New("key options are not supported")
	}
	return Key{
		Line: line, Type: pub.Type(), Fingerprint: ssh.FingerprintSHA256(pub),
		Comment: comment, Source: source, Bits: bits(pub), Size: len(line),
	}, nil
}

func bits(pub ssh.PublicKey) int {
	cp, ok := pub.(ssh.CryptoPublicKey)
	if !ok {
		return 0
	}
	switch k := cp.CryptoPublicKey().(type) {
	case *rsa.PublicKey:
		return k.N.BitLen()
	case *ecdsa.PublicKey:
		return k.Curve.Params().BitSize
	case ed25519.PublicKey:
		return 256
	}
	return 0
}

// FetchGitHub downloads https://github.com/<user>.keys.
func FetchGitHub(ctx context.Context, client *http.Client, user string) ([]Key, error) {
	user = strings.TrimSpace(user)
	if !userRe.MatchString(user) {
		return nil, ErrBadUser
	}
	if client == nil {
		client = http.DefaultClient
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, githubBase+"/"+url.PathEscape(user)+".keys", nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetching keys: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("github.com returned %s for user %q", resp.Status, user)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, fetchLimit))
	if err != nil {
		return nil, fmt.Errorf("reading keys: %w", err)
	}
	keys, err := Parse(string(body), "github.com/"+user)
	if err != nil {
		return nil, err
	}
	if len(keys) == 0 {
		return nil, ErrNoKeys
	}
	return keys, nil
}

// Generate creates an ed25519 key pair; privPEM is OpenSSH format.
func Generate(comment string) (pub Key, privPEM []byte, err error) {
	pk, sk, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return Key{}, nil, err
	}
	sp, err := ssh.NewPublicKey(pk)
	if err != nil {
		return Key{}, nil, err
	}
	block, err := ssh.MarshalPrivateKey(sk, comment)
	if err != nil {
		return Key{}, nil, err
	}
	line := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(sp)))
	if comment != "" {
		line += " " + comment
	}
	pub, err = parseLine(line, "generated")
	if err != nil {
		return Key{}, nil, err
	}
	return pub, pem.EncodeToMemory(block), nil
}

// Dedupe drops repeated keys (same blob), keeping the first.
func Dedupe(keys []Key) []Key {
	seen := map[string]bool{}
	out := make([]Key, 0, len(keys))
	for _, k := range keys {
		id := k.Type + " " + Blob(k.Line)
		if seen[id] {
			continue
		}
		seen[id] = true
		out = append(out, k)
	}
	return out
}

// Blob returns the base64 key blob of an authorized_keys line (the whole
// line if it has no second field).
func Blob(line string) string {
	f := strings.Fields(line)
	if len(f) >= 2 {
		return f[1]
	}
	return line
}

// UserDataLimit is the user_data byte budget used for the key-size warning.
func UserDataLimit(provider string) int {
	switch provider {
	case "aws":
		return 16384
	case "exoscale":
		return 24576
	case "vultr":
		return 32768
	case "evroc":
		return 786432
	}
	return 16384
}
