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
	ociCatalog = "internal/provider/oci/testdata/pricing.json"
	ociExample = "../../examples/oci/terraform.tfvars.example"
	ociTfvars  = "testdata/oci.tfvars"
)

// TestOCIExampleGolden runs the whole pipeline against a cost-relevant
// tfvars subset with the fixture price list, in text and JSON.
func TestOCIExampleGolden(t *testing.T) {
	base := []string{"--provider", "oci", "--no-network", "--catalog", ociCatalog, "--var-file", ociTfvars}

	code, out, errOut := exec(base...)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if lines[0] != pricing.Disclaimer || lines[len(lines)-1] != pricing.Disclaimer {
		t.Error("the text report must start and end with the disclaimer")
	}
	for _, want := range []string{"USD", "Region: eu-frankfurt-1", "custom image", "outbound traffic"} {
		if !strings.Contains(out, want) {
			t.Errorf("report lacks %q:\n%s", want, out)
		}
	}
	compareGolden(t, "oci-example.txt", out)

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
	compareGolden(t, "oci-example.json", out)
}

// TestOCIUnknownTypeExitsPrice: a shape without a price
// fails with exit code 3 unless --allow-unknown-plans is set.
func TestOCIUnknownTypeExitsPrice(t *testing.T) {
	base := []string{"--provider", "oci", "--no-network", "--catalog", ociCatalog, "--var-file", ociTfvars}
	bad := filepath.Join(t.TempDir(), "t.tfvars")
	if err := os.WriteFile(bad, []byte("deploy_nodes = true\nworker_pools = { w = { instance_type = \"VM.Standard.Nope.Flex:2x16\", count = 1 } }"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code, _, errOut := exec(append(base, "--var-file", bad)...); code != exitPrice || !strings.Contains(errOut, "VM.Standard.Nope.Flex:2x16") {
		t.Errorf("exit %d, stderr %q; want exit %d naming the type", code, errOut, exitPrice)
	}
	if code, _, errOut := exec(append(base, "--var-file", bad, "--allow-unknown-plans")...); code != exitOK {
		t.Errorf("--allow-unknown-plans: exit %d: %s", code, errOut)
	}
}

// TestOCISyntaxErrorExitsConfig: a flex shape without a size is a config
// problem (exit 2), like the module's input check.
func TestOCISyntaxErrorExitsConfig(t *testing.T) {
	bad := filepath.Join(t.TempDir(), "t.tfvars")
	if err := os.WriteFile(bad, []byte(`control_plane_instance_type = "VM.Standard.E5.Flex"`), 0o600); err != nil {
		t.Fatal(err)
	}
	code, _, errOut := exec("--provider", "oci", "--no-network", "--catalog", ociCatalog, "--var-file", ociTfvars, "--var-file", bad)
	if code != exitConfig || !strings.Contains(errOut, "needs a size") {
		t.Errorf("exit %d, stderr %q; want exit %d", code, errOut, exitConfig)
	}
}

// TestOCINodesPriced: with nodes deployed the report prices flex and GPU
// shapes and boot volumes.
func TestOCINodesPriced(t *testing.T) {
	f := filepath.Join(t.TempDir(), "t.tfvars")
	body := `deploy_nodes = true
gpu_pools = { g = { instance_type = "VM.GPU.A10.1", count = 1 } }`
	if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	code, out, errOut := exec("--provider", "oci", "--no-network", "--catalog", ociCatalog, "--var-file", ociTfvars, "--var-file", f)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	for _, want := range []string{"VM.GPU.A10.1", "VM.Standard.E5.Flex:4x32", "storage:boot"} {
		if !strings.Contains(out, want) {
			t.Errorf("report lacks %q:\n%s", want, out)
		}
	}
	compareGolden(t, "oci-nodes.txt", out)
}

// TestOCIShippedExampleParses: the shipped example tfvars price without a
// config error (warnings about undeclared variables are not failures).
func TestOCIShippedExampleParses(t *testing.T) {
	if code, _, errOut := exec("--provider", "oci", "--no-network", "--catalog", ociCatalog, "--var-file", ociExample); code != exitOK {
		t.Errorf("exit %d: %s", code, errOut)
	}
}
