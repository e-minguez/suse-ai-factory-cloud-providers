package creds

import (
	"errors"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/ssh"
)

// ErrKeyExists is returned when the container key is already stored.
var ErrKeyExists = errors.New("an SSH private key is already stored on the volume")

// ErrKeyPassphrase is returned for passphrase-protected private keys.
var ErrKeyPassphrase = errors.New("the private key is protected by a passphrase; remove the passphrase first (ssh-keygen -p -N \"\" -f <key>)")

// SSHKeyPath is the private key used by SSH inside the container.
func SSHKeyPath(clustersDir string) string {
	return filepath.Join(HomeDir(clustersDir), ".ssh", "id_ed25519")
}

// HasSSHKey reports whether the container private key exists.
func HasSSHKey(clustersDir string) bool { return exists(SSHKeyPath(clustersDir)) }

// StoreSSHKey writes the private key (mode 600) and, when pub is not
// empty, the public key (mode 644). Without replace an existing private
// key is never overwritten (ErrKeyExists).
func StoreSSHKey(clustersDir string, priv, pub []byte, replace bool) error {
	if err := EnsureHome(clustersDir); err != nil {
		return err
	}
	path := SSHKeyPath(clustersDir)
	if !replace {
		if _, err := os.Lstat(path); err == nil {
			return ErrKeyExists
		}
	}
	if err := writeFile(path, priv); err != nil {
		return err
	}
	if len(pub) == 0 {
		return nil
	}
	if err := writeFile(path+".pub", pub); err != nil {
		return err
	}
	return os.Chmod(path+".pub", 0o644)
}

// StorePastedSSHKey validates an OpenSSH private key without a passphrase
// and stores it with its public half.
func StorePastedSSHKey(clustersDir, text string, replace bool) error {
	text = strings.TrimSpace(strings.ReplaceAll(text, "\r\n", "\n"))
	if text == "" {
		return errors.New("paste an OpenSSH private key")
	}
	raw := []byte(text + "\n")
	key, err := ssh.ParseRawPrivateKey(raw)
	if err != nil {
		var pm *ssh.PassphraseMissingError
		if errors.As(err, &pm) {
			return ErrKeyPassphrase
		}
		return errors.New("not a valid OpenSSH private key")
	}
	signer, err := ssh.NewSignerFromKey(key)
	if err != nil {
		return errors.New("unsupported private key type")
	}
	return StoreSSHKey(clustersDir, raw, ssh.MarshalAuthorizedKey(signer.PublicKey()), replace)
}
