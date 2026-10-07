package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

const (
	vultrCatalog   = "internal/provider/vultr/testdata/plans.json"
	vultrExample   = "../../examples/vultr/terraform.tfvars.example"
	goldenDir      = "testdata/golden"
	updateGoldenEv = "UPDATE_GOLDEN"
)

// fakeSecrets are fabricated values shaped like real credentials in the
// testdata/redact_*.tfvars fixtures. They prove no secret-shaped value is
// echoed, not merely one specific real secret.
var fakeSecrets = []string{
	"F3C9A18B2D6E4F0A9B7C5D3E1F0A2B4C6D8E1F3A5B7C9D0E2F4A6B8C0D2E4F6A",
	"rounds=656000$aVeryFakeSaltStr",
	"rounds=656000$anotherFakeSalt",
	"AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderFakeKeyMaterial",
	"nvapi-FAKEkQ1w2E3r4T5y6U7i8O9p0AsDfGhJkLzXcVbNmQwErTyUiOpAsDfGhJk",
	"fake-appco-token-Zm9vYmFyYmF6cXV1eA==",
	"FAKE-1234-5678-9ABC-DEF0",
	"fake-suse-registry-password-9f8e7d6c5b4a",
}

func assertNoSecrets(t *testing.T, label string, output []byte) {
	t.Helper()
	for _, secret := range fakeSecrets {
		if strings.Contains(string(output), secret) {
			t.Errorf("%s leaked a secret-shaped substring %q:\n%s", label, secret, output)
		}
	}
}

func exec(args ...string) (code int, stdout, stderr string) {
	var out, errb bytes.Buffer
	code = run(args, &out, &errb)
	return code, out.String(), errb.String()
}

func compareGolden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join(goldenDir, name)
	if os.Getenv(updateGoldenEv) != "" {
		if err := os.MkdirAll(goldenDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v (set %s=1 to create it)", path, err, updateGoldenEv)
	}
	if diff := cmp.Diff(string(want), got); diff != "" {
		t.Errorf("%s mismatch (-want +got):\n%s", path, diff)
	}
}

// TestVultrExampleGolden runs the whole pipeline against the shipped example
// tfvars with a fixture catalog, in text and JSON.
func TestVultrExampleGolden(t *testing.T) {
	base := []string{"--provider", "vultr", "--no-network", "--catalog", vultrCatalog, "--var-file", vultrExample}

	code, out, errOut := exec(base...)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if lines[0] != pricing.Disclaimer || lines[len(lines)-1] != pricing.Disclaimer {
		t.Error("the text report must start and end with the disclaimer")
	}
	compareGolden(t, "vultr-example.txt", out)

	code, out, errOut = exec(append([]string{"--json"}, base...)...)
	if code != exitOK {
		t.Fatalf("json: exit %d: %s", code, errOut)
	}
	var doc struct {
		Disclaimer string `json:"disclaimer"`
		Currency   string `json:"currency"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil || doc.Disclaimer != pricing.Disclaimer || doc.Currency != "USD" {
		t.Errorf("JSON disclaimer/currency wrong: %+v, %v", doc, err)
	}
	compareGolden(t, "vultr-example.json", out)
}

func TestLayeredVarFilesLaterWins(t *testing.T) {
	dir := t.TempDir()
	first := filepath.Join(dir, "a.tfvars")
	second := filepath.Join(dir, "b.tfvars")
	_ = os.WriteFile(first, []byte("region = \"ams\"\ncluster_name = \"first\"\n"), 0o600)
	_ = os.WriteFile(second, []byte("cluster_name = \"second\"\n"), 0o600)
	code, out, errOut := exec("--provider", "vultr", "--no-network", "--catalog", vultrCatalog, "--var-file", first, "--var-file", second)
	if code != exitOK || !strings.Contains(out, "Cluster: second") {
		t.Fatalf("exit %d, want the later file to win:\n%s\n%s", code, out, errOut)
	}
}

func TestMissingRegionExitsConfig(t *testing.T) {
	code, _, errOut := exec("--provider", "vultr", "--no-network", "--catalog", vultrCatalog)
	if code != exitConfig || !strings.Contains(errOut, "--region") {
		t.Errorf("exit %d, stderr %q; want exit 2 mentioning --region", code, errOut)
	}
	code, out, errOut := exec("--provider", "vultr", "--region", "ams", "--no-network", "--catalog", vultrCatalog)
	if code != exitOK || !strings.Contains(out, "Region: ams") {
		t.Errorf("--region alone should suffice: exit %d %s", code, errOut)
	}
}

func TestFlagErrorsExitConfig(t *testing.T) {
	for name, args := range map[string][]string{
		"no provider":      {},
		"unknown provider": {"--provider", "nope"},
		"bad duration":     {"--provider", "vultr", "--durations", "5m"},
		"positional arg":   {"--provider", "vultr", "x.tfvars"},
		"missing var-file": {"--provider", "vultr", "--var-file", "/nonexistent.tfvars"},
	} {
		if code, _, _ := exec(args...); code != exitConfig {
			t.Errorf("%s: exit %d, want %d", name, code, exitConfig)
		}
	}
}

func TestUnknownPlanExitsPrice(t *testing.T) {
	f := filepath.Join(t.TempDir(), "t.tfvars")
	_ = os.WriteFile(f, []byte("region = \"ams\"\ncontrol_plane_instance_type = \"vx1-does-not-exist\"\n"), 0o600)
	base := []string{"--provider", "vultr", "--no-network", "--catalog", vultrCatalog, "--var-file", f}
	if code, _, _ := exec(base...); code != exitPrice {
		t.Errorf("exit %d, want %d", code, exitPrice)
	}
	code, out, _ := exec(append(base, "--allow-unknown-plans")...)
	if code != exitOK || !strings.Contains(out, "floor") {
		t.Errorf("--allow-unknown-plans: exit %d, want 0 with the floor note:\n%s", code, out)
	}
}

func TestNoNetworkWithoutCatalogOrCacheExitsPrice(t *testing.T) {
	empty := t.TempDir()
	t.Setenv("HOME", empty)
	t.Setenv("XDG_CACHE_HOME", empty)
	if code, _, _ := exec("--provider", "vultr", "--region", "ams", "--no-network"); code != exitPrice {
		t.Errorf("exit %d, want %d", code, exitPrice)
	}
}

// TestNotImplementedProvidersExitPrice documents the stub behaviour; delete
// each case when the provider lands.
var redactLayers = []string{
	"--var-file", "testdata/redact_all.tfvars",
	"--var-file", "testdata/redact_provider.tfvars",
	"--var-file", "testdata/redact_cluster.tfvars",
}

// TestRedactionLayeredTFVars runs the pipeline over layered tfvars carrying
// every sensitive variable, in text and JSON, and checks stdout and stderr.
func TestRedactionLayeredTFVars(t *testing.T) {
	for _, jsonMode := range []bool{false, true} {
		args := append([]string{"--provider", "vultr", "--no-network", "--catalog", vultrCatalog}, redactLayers...)
		if jsonMode {
			args = append([]string{"--json"}, args...)
		}
		code, out, errOut := exec(args...)
		if code != exitOK {
			t.Fatalf("json=%v: exit %d: %s", jsonMode, code, errOut)
		}
		assertNoSecrets(t, "stdout", []byte(out))
		assertNoSecrets(t, "stderr", []byte(errOut))
	}
}

// TestRedactionAcrossProviders: a provider that fails (stub, or one that does
// not declare the variables) must not echo the credentials either.
func TestRedactionAcrossProviders(t *testing.T) {
	for _, p := range []string{"aws", "evroc", "exoscale", "vultr"} {
		args := append([]string{"--provider", p, "--region", "x", "--no-network"}, redactLayers...)
		_, out, errOut := exec(args...)
		assertNoSecrets(t, p+" stdout", []byte(out))
		assertNoSecrets(t, p+" stderr", []byte(errOut))
	}
}

// TestRedactionMalformedTFVars: an HCL syntax error on a secret value must
// not put the partially scanned token into any output.
func TestRedactionMalformedTFVars(t *testing.T) {
	for _, jsonMode := range []bool{false, true} {
		args := []string{"--provider", "vultr", "--no-network", "--catalog", vultrCatalog, "--var-file", "testdata/redact_all.tfvars", "--var-file", "testdata/redact_malformed.tfvars"}
		if jsonMode {
			args = append([]string{"--json"}, args...)
		}
		code, out, errOut := exec(args...)
		if code != exitConfig {
			t.Fatalf("json=%v: exit %d, want %d", jsonMode, code, exitConfig)
		}
		assertNoSecrets(t, "stdout", []byte(out))
		assertNoSecrets(t, "stderr", []byte(errOut))
	}
}

// TestDropZeroQty: quantity-0 rows go; the note names deploy_nodes only when
// node rows went, and a disabled public IP alone adds no note.
func TestDropZeroQty(t *testing.T) {
	node := pricing.Resource{Kind: pricing.KindCompute, Role: "gpu", Qty: 0}
	ip := pricing.Resource{Kind: pricing.KindFixed, Role: "control_plane", Qty: 0}
	jump := pricing.Resource{Kind: pricing.KindCompute, Role: "jumphost", Qty: 1}
	free := pricing.Resource{Kind: pricing.KindFree, Role: "network", Qty: 1}

	out, notes := dropZeroQty([]pricing.Resource{node, ip, jump, free}, false)
	if len(out) != 2 || len(notes) != 1 || !strings.Contains(notes[0], "deploy_nodes = false") {
		t.Errorf("deploy_nodes=false: got %d rows, notes %q", len(out), notes)
	}
	if _, notes := dropZeroQty([]pricing.Resource{node, jump}, true); len(notes) != 1 || !strings.Contains(notes[0], "count = 0") {
		t.Errorf("count=0 pool: notes %q", notes)
	}
	if _, notes := dropZeroQty([]pricing.Resource{ip, jump}, true); notes != nil {
		t.Errorf("disabled public IP must add no note, got %q", notes)
	}
}
