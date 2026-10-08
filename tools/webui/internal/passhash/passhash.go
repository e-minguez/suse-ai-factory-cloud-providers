// Package passhash produces SHA-512 crypt ($6$) hashes with `openssl passwd -6`,
// the command the Elemental documentation gives for password hashes.
package passhash

import (
	"bytes"
	"crypto/subtle"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Hash returns `openssl passwd -6` of password (random salt). The password
// goes through stdin, never the command line.
func Hash(password string) (string, error) {
	return openssl(password)
}

// Verify reports whether password matches a $6$ hash made with the default
// rounds; hashes with rounds= or a malformed hash do not match.
func Verify(password, hash string) bool {
	rest, ok := strings.CutPrefix(hash, "$6$")
	if !ok || strings.HasPrefix(rest, "rounds=") {
		return false
	}
	salt, _, ok := strings.Cut(rest, "$")
	if !ok || salt == "" {
		return false
	}
	got, err := openssl(password, "-salt", salt)
	return err == nil && subtle.ConstantTimeCompare([]byte(got), []byte(hash)) == 1
}

func openssl(password string, args ...string) (string, error) {
	if strings.ContainsAny(password, "\r\n") {
		return "", errors.New("password must be a single line")
	}
	var out, errb bytes.Buffer
	cmd := exec.Command("openssl", append([]string{"passwd", "-6"}, append(args, "-stdin")...)...)
	cmd.Stdin = strings.NewReader(password + "\n")
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("openssl passwd: %w: %s", err, strings.TrimSpace(errb.String()))
	}
	h := strings.TrimSpace(out.String())
	if !strings.HasPrefix(h, "$6$") {
		return "", errors.New("openssl passwd: unexpected output")
	}
	return h, nil
}
