package creds

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/sshkeys"
)

func mode(t *testing.T, p string) os.FileMode {
	t.Helper()
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return fi.Mode().Perm()
}

func TestAWS(t *testing.T) {
	d := t.TempDir()
	if err := Save(d, "aws", map[string]string{"access_key_id": "AK", "secret_access_key": "SK"}); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(d, ".aws", "credentials")
	if mode(t, p) != 0o600 || mode(t, filepath.Dir(p)) != 0o700 {
		t.Fatal("modes")
	}
	// Empty keeps; token added.
	if err := Save(d, "aws", map[string]string{"access_key_id": "", "secret_access_key": "", "session_token": "TOK"}); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p)
	for _, w := range []string{"[default]", "aws_access_key_id = AK", "aws_secret_access_key = SK", "aws_session_token = TOK"} {
		if !strings.Contains(string(b), w) {
			t.Errorf("missing %q", w)
		}
	}
	st, _ := Status(d, "aws")
	if !st["access_key_id"] || !st["secret_access_key"] || !st["session_token"] {
		t.Fatalf("%v", st)
	}
	env := strings.Join(Env(d, "aws"), "\n")
	if strings.Contains(env, "HOME=") {
		t.Fatal("HOME must not be set by creds.Env")
	}
	if !strings.Contains(env, "AWS_SHARED_CREDENTIALS_FILE="+p) || !strings.Contains(env, "AWS_PROFILE=default") || strings.Contains(env, "AWS_CONFIG_FILE") {
		t.Fatal(env)
	}
	_ = os.WriteFile(filepath.Join(d, ".aws", "config"), []byte("[default]\nregion=x\n"), 0o600)
	if !strings.Contains(strings.Join(Env(d, "aws"), "\n"), "AWS_CONFIG_FILE=") {
		t.Fatal("config env")
	}
}

func TestAWSRequiresBoth(t *testing.T) {
	if err := Save(t.TempDir(), "aws", map[string]string{"access_key_id": "AK"}); err == nil {
		t.Fatal("want error")
	}
}

func TestEvroc(t *testing.T) {
	d := t.TempDir()
	if Env(d, "evroc") != nil {
		t.Fatal("env before save")
	}
	if err := Save(d, "evroc", map[string]string{"config": "{{{"}); err == nil {
		t.Fatal("invalid yaml accepted")
	}
	if err := Save(d, "evroc", map[string]string{"config": "formatVersion: v1\ncurrentProfile: default\nprofiles:\n  default:\n    project: p\n    user:\n      refreshToken: abcdefghijkl\n"}); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(d, ".home", ".evroc", "config.yaml")
	if mode(t, p) != 0o600 {
		t.Fatal("mode")
	}
	env := strings.Join(Env(d, "evroc"), "\n")
	if env != "" {
		t.Fatal(env)
	}
	if st, _ := Status(d, "evroc"); !st["config"] {
		t.Fatal("status")
	}
	if err := Save(d, "evroc", map[string]string{"config": ""}); err != nil {
		t.Fatal(err)
	}
}

func TestTfvarsProviders(t *testing.T) {
	d := t.TempDir()
	for p, vals := range map[string]map[string]string{
		"vultr":    {"vultr_api_key": "VK"},
		"exoscale": {"exoscale_api_key": "EK", "exoscale_api_secret": "ES"},
	} {
		if st, _ := Status(d, p); anySet(st) {
			t.Fatalf("%s set before save", p)
		}
		if err := Save(d, p, vals); err != nil {
			t.Fatal(err)
		}
		st, err := Status(d, p)
		if err != nil || len(st) != len(vals) {
			t.Fatalf("%s: %v %v", p, err, st)
		}
		for k, ok := range st {
			if !ok {
				t.Errorf("%s %s not set", p, k)
			}
		}
		if mode(t, filepath.Join(d, "common-"+p+".tfvars")) != 0o600 {
			t.Error("mode")
		}
		if Env(d, p) != nil {
			t.Error("env")
		}
	}
	if err := Save(d, "exoscale", map[string]string{"exoscale_api_key": "", "exoscale_api_secret": ""}); err != nil {
		t.Fatal(err)
	}
	if _, err := Status(d, "nope"); err == nil {
		t.Fatal("unknown provider")
	}
}

func anySet(m map[string]bool) bool {
	for _, v := range m {
		if v {
			return true
		}
	}
	return false
}

func TestAWSEnvOnlyWithFiles(t *testing.T) {
	if env := Env(t.TempDir(), "aws"); len(env) != 0 {
		t.Fatalf("env without files: %v", env)
	}
}

func TestEnsureHome(t *testing.T) {
	d := t.TempDir()
	if err := EnsureHome(d); err != nil {
		t.Fatal(err)
	}
	if HomeDir(d) != filepath.Join(d, ".home") || mode(t, HomeDir(d)) != 0o700 || mode(t, filepath.Join(HomeDir(d), ".ssh")) != 0o700 {
		t.Fatal("home modes")
	}
}

func TestSecretValues(t *testing.T) {
	d := t.TempDir()
	_ = Save(d, "aws", map[string]string{"access_key_id": "AKIDVALUE", "secret_access_key": "SECRETVALUE", "session_token": "TOKENVALUE"})
	if v, err := SecretValues(d, "aws"); err != nil || len(v) != 3 {
		t.Fatalf("aws %v %v", v, err)
	}
	_ = Save(d, "evroc", map[string]string{"config": "currentProfile: default\nprofiles:\n  default:\n    project: myproject\n    user:\n      refreshToken: abcdefghijkl\n      api_key: short\nlist:\n  - password: longpassword1\n"})
	v, err := SecretValues(d, "evroc")
	got := strings.Join(v, ",")
	if err != nil || !strings.Contains(got, "abcdefghijkl") || !strings.Contains(got, "longpassword1") || strings.Contains(got, "myproject") || strings.Contains(got, "short") {
		t.Fatalf("evroc %v %v", v, err)
	}
	_ = Save(d, "exoscale", map[string]string{"exoscale_api_key": "EXOKEY", "exoscale_api_secret": "EXOSECRET"})
	if v, _ := SecretValues(d, "exoscale"); len(v) != 2 {
		t.Fatalf("exoscale %v", v)
	}
	if v, err := SecretValues(t.TempDir(), "vultr"); err != nil || len(v) != 0 {
		t.Fatalf("vultr %v %v", v, err)
	}
	if _, err := SecretValues(d, "nope"); err == nil {
		t.Fatal("unknown provider")
	}
}

func TestSSHKeyStore(t *testing.T) {
	d := t.TempDir()
	if HasSSHKey(d) {
		t.Fatal("has key")
	}
	if err := StoreSSHKey(d, []byte("PRIV\n"), []byte("PUB\n"), false); err != nil {
		t.Fatal(err)
	}
	p := SSHKeyPath(d)
	if mode(t, p) != 0o600 || mode(t, p+".pub") != 0o644 || !HasSSHKey(d) {
		t.Fatal("modes")
	}
	if err := StoreSSHKey(d, []byte("OTHER\n"), nil, false); !errors.Is(err, ErrKeyExists) {
		t.Fatalf("overwrite: %v", err)
	}
	if b, _ := os.ReadFile(p); string(b) != "PRIV\n" {
		t.Fatal("overwritten")
	}
	if err := StoreSSHKey(d, []byte("OTHER\n"), nil, true); err != nil {
		t.Fatal(err)
	}
}

func TestStorePastedSSHKey(t *testing.T) {
	d := t.TempDir()
	if err := StorePastedSSHKey(d, "garbage", false); err == nil || HasSSHKey(d) {
		t.Fatal("garbage accepted")
	}
	_, priv, _ := sshkeys.Generate("t")
	if err := StorePastedSSHKey(d, string(priv), false); err != nil {
		t.Fatal(err)
	}
	if mode(t, SSHKeyPath(d)) != 0o600 {
		t.Fatal("mode")
	}
	if b, _ := os.ReadFile(SSHKeyPath(d) + ".pub"); !strings.HasPrefix(string(b), "ssh-ed25519 ") {
		t.Fatalf("pub %q", b)
	}
	// Passphrase-protected key.
	_, sk, _ := ed25519.GenerateKey(rand.Reader)
	blk, _ := ssh.MarshalPrivateKeyWithPassphrase(sk, "", []byte("pw"))
	err := StorePastedSSHKey(t.TempDir(), string(pem.EncodeToMemory(blk)), false)
	if !errors.Is(err, ErrKeyPassphrase) {
		t.Fatalf("passphrase: %v", err)
	}
}

func TestEvrocConfigChecks(t *testing.T) {
	d := t.TempDir()
	for cfg, want := range map[string]string{
		"profiles:\n  default:\n    user:\n      refreshToken: x\n":                        "no currentProfile",
		"currentProfile: other\nprofiles:\n  default:\n    user:\n      refreshToken: x\n": `"other" is not under profiles`,
		"currentProfile: default\nprofiles:\n  default:\n    user:\n      username: u\n":   "no user.refreshToken",
	} {
		if err := Save(d, "evroc", map[string]string{"config": cfg}); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: %v", want, err)
		}
	}
}
