package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

const (
	gcpCatalog = "internal/provider/gcp/testdata/skus.json"
	gcpExample = "../../examples/gcp/terraform.tfvars.example"
	gcpTfvars  = "testdata/gcp.tfvars"
)

// TestGCPExampleGolden runs the whole pipeline against a cost-relevant
// tfvars subset with the fixture price list, in text and JSON.
func TestGCPExampleGolden(t *testing.T) {
	base := []string{"--provider", "gcp", "--no-network", "--catalog", gcpCatalog, "--var-file", gcpTfvars}

	code, out, errOut := exec(base...)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if lines[0] != pricing.Disclaimer || lines[len(lines)-1] != pricing.Disclaimer {
		t.Error("the text report must start and end with the disclaimer")
	}
	for _, want := range []string{"USD", "Region: europe-west4", "image target disk", "outbound traffic"} {
		if !strings.Contains(out, want) {
			t.Errorf("report lacks %q:\n%s", want, out)
		}
	}
	compareGolden(t, "gcp-example.txt", out)

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
	compareGolden(t, "gcp-example.json", out)
}

// TestGCPUnknownTypeExitsPrice: a machine type without a price
// fails with exit code 3 unless --allow-unknown-plans is set.
func TestGCPUnknownTypeExitsPrice(t *testing.T) {
	base := []string{"--provider", "gcp", "--no-network", "--catalog", gcpCatalog, "--var-file", gcpTfvars}
	bad := filepath.Join(t.TempDir(), "t.tfvars")
	if err := os.WriteFile(bad, []byte("deploy_nodes = true\nworker_pools = { w = { instance_type = \"n2-nope-4\", count = 1 } }"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code, _, errOut := exec(append(base, "--var-file", bad)...); code != exitPrice || !strings.Contains(errOut, "n2-nope-4") {
		t.Errorf("exit %d, stderr %q; want exit %d naming the type", code, errOut, exitPrice)
	}
	if code, _, errOut := exec(append(base, "--var-file", bad, "--allow-unknown-plans")...); code != exitOK {
		t.Errorf("--allow-unknown-plans: exit %d: %s", code, errOut)
	}
}

// TestGCPSyntaxErrorExitsConfig: a fractional G4 size is a config problem (exit 2), like the
// module's input check.
func TestGCPSyntaxErrorExitsConfig(t *testing.T) {
	bad := filepath.Join(t.TempDir(), "t.tfvars")
	if err := os.WriteFile(bad, []byte(`control_plane_instance_type = "g4-standard-12"`), 0o600); err != nil {
		t.Fatal(err)
	}
	code, _, errOut := exec("--provider", "gcp", "--no-network", "--catalog", gcpCatalog, "--var-file", gcpTfvars, "--var-file", bad)
	if code != exitConfig || !strings.Contains(errOut, "fractional") {
		t.Errorf("exit %d, stderr %q; want exit %d", code, errOut, exitConfig)
	}
}

// TestGCPNodesPriced: with nodes deployed the report prices flex and GPU
// machine types and boot disks.
func TestGCPNodesPriced(t *testing.T) {
	f := filepath.Join(t.TempDir(), "t.tfvars")
	body := `deploy_nodes = true
gpu_pools = { g = { instance_type = "g2-standard-8", count = 1 } }`
	if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	code, out, errOut := exec("--provider", "gcp", "--no-network", "--catalog", gcpCatalog, "--var-file", gcpTfvars, "--var-file", f)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	for _, want := range []string{"g2-standard-8", "n2-standard-4", "disk:pd-balanced"} {
		if !strings.Contains(out, want) {
			t.Errorf("report lacks %q:\n%s", want, out)
		}
	}
	compareGolden(t, "gcp-nodes.txt", out)
}

// TestGCPShippedExampleParses: the shipped example tfvars price without a
// config error (warnings about undeclared variables are not failures).
func TestGCPShippedExampleParses(t *testing.T) {
	if code, _, errOut := exec("--provider", "gcp", "--no-network", "--catalog", gcpCatalog, "--var-file", gcpExample); code != exitOK {
		t.Errorf("exit %d: %s", code, errOut)
	}
}
