package creds

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/tfvars"
)

func ociTestKey(t *testing.T) string {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}

func TestOCI(t *testing.T) {
	d := t.TempDir()
	key := ociTestKey(t)
	if st, err := Status(d, "oci"); err != nil || anySet(st) || len(st) != len(Fields("oci")) {
		t.Fatalf("before save: %v %v", st, err)
	}

	// Without a region the tfvars are written, the CLI config is not.
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(Save(d, "oci", map[string]string{
		"oci_tenancy_ocid": "ocid1.tenancy.oc1..t", "oci_user_ocid": "ocid1.user.oc1..u",
		"oci_fingerprint": "aa:bb", "private_key": key,
	}))
	keyPath := filepath.Join(d, ociKeyRel)
	vals, err := tfvars.Read(filepath.Join(d, "common-oci.tfvars"))
	must(err)
	if vals["oci_private_key_path"] != keyPath || vals["oci_user_ocid"] != "ocid1.user.oc1..u" {
		t.Fatalf("tfvars %v", vals)
	}
	if mode(t, keyPath) != 0o600 || mode(t, filepath.Join(d, "common-oci.tfvars")) != 0o600 {
		t.Fatal("modes")
	}
	if exists(filepath.Join(d, ociConfigRel)) {
		t.Fatal("config written without a region")
	}
	if st, _ := Status(d, "oci"); st["cli_region"] || !st["private_key"] || !st["oci_fingerprint"] {
		t.Fatalf("status %v", st)
	}

	// The region alone completes the CLI config from the stored values.
	must(Save(d, "oci", map[string]string{"cli_region": "eu-frankfurt-1"}))
	cfg, err := os.ReadFile(filepath.Join(d, ociConfigRel))
	must(err)
	for _, want := range []string{"[DEFAULT]\n", "user=ocid1.user.oc1..u\n", "fingerprint=aa:bb\n", "tenancy=ocid1.tenancy.oc1..t\n", "region=eu-frankfurt-1\n", "key_file=" + keyPath + "\n"} {
		if !strings.Contains(string(cfg), want) {
			t.Errorf("config lacks %q:\n%s", want, cfg)
		}
	}
	if mode(t, filepath.Join(d, ociConfigRel)) != 0o600 {
		t.Fatal("config mode")
	}
	st, _ := Status(d, "oci")
	for k, ok := range st {
		if !ok {
			t.Errorf("%s not set", k)
		}
	}

	// A later fingerprint change rewrites the config and keeps the region.
	must(Save(d, "oci", map[string]string{"oci_fingerprint": "cc:dd"}))
	cfg, _ = os.ReadFile(filepath.Join(d, ociConfigRel))
	if !strings.Contains(string(cfg), "fingerprint=cc:dd\n") || !strings.Contains(string(cfg), "region=eu-frankfurt-1\n") {
		t.Fatalf("config not updated:\n%s", cfg)
	}

	if v, err := SecretValues(d, "oci"); err != nil || len(v) != 1 || v[0] != strings.TrimSpace(key) {
		t.Fatalf("secrets %d %v", len(v), err)
	}
	if Env(d, "oci") != nil {
		t.Fatal("env")
	}
}

func TestOCIRejects(t *testing.T) {
	d := t.TempDir()
	for name, k := range map[string]string{
		"not pem":          "hello",
		"public":           "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n",
		"encrypted":        "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n",
		"legacy encrypted": "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAAAA\n-----END RSA PRIVATE KEY-----\n",
		"trailing":         ociTestKey(t) + "junk\n",
	} {
		if err := Save(d, "oci", map[string]string{"private_key": k}); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if err := Save(d, "oci", map[string]string{"oci_user_ocid": "a\nb"}); err == nil {
		t.Error("newline accepted")
	}
	if exists(filepath.Join(d, ociKeyRel)) {
		t.Error("rejected key written")
	}
}
