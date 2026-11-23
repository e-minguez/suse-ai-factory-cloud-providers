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
	azureCatalog = "internal/provider/azure/testdata/prices.json"
	azureVars    = "../../modules/azure/variables.tf"
	azureTfvars  = "testdata/azure.tfvars"
)

// skipWithoutAzureModule skips the pipeline tests until modules/azure exists:
// the CLI reads its variables.tf.
func skipWithoutAzureModule(t *testing.T) {
	t.Helper()
	if _, err := os.Stat(azureVars); err != nil {
		t.Skipf("%s does not exist yet", azureVars)
	}
}

// TestAzureExampleGolden runs the whole pipeline against a cost-relevant
// tfvars subset with the fixture price list, in text and JSON.
func TestAzureExampleGolden(t *testing.T) {
	skipWithoutAzureModule(t)
	base := []string{"--provider", "azure", "--no-network", "--catalog", azureCatalog, "--var-file", azureTfvars}

	code, out, errOut := exec(base...)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if lines[0] != pricing.Disclaimer || lines[len(lines)-1] != pricing.Disclaimer {
		t.Error("the text report must start and end with the disclaimer")
	}
	for _, want := range []string{"USD", "Region: westeurope", "nat gateway", "outbound traffic"} {
		if !strings.Contains(out, want) {
			t.Errorf("report lacks %q:\n%s", want, out)
		}
	}
	compareGolden(t, "azure-example.txt", out)

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
	compareGolden(t, "azure-example.json", out)
}

// TestAzureUnknownTypeExitsPrice: a VM size without a price fails with exit
// code 3 unless --allow-unknown-plans is set.
func TestAzureUnknownTypeExitsPrice(t *testing.T) {
	skipWithoutAzureModule(t)
	base := []string{"--provider", "azure", "--no-network", "--catalog", azureCatalog, "--var-file", azureTfvars}
	bad := filepath.Join(t.TempDir(), "t.tfvars")
	if err := os.WriteFile(bad, []byte("deploy_nodes = true\nworker_pools = { w = { instance_type = \"Standard_Nope_v9\", count = 1 } }"), 0o600); err != nil {
		t.Fatal(err)
	}
	if code, _, errOut := exec(append(base, "--var-file", bad)...); code != exitPrice || !strings.Contains(errOut, "Standard_Nope_v9") {
		t.Errorf("exit %d, stderr %q; want exit %d naming the size", code, errOut, exitPrice)
	}
	if code, _, errOut := exec(append(base, "--var-file", bad, "--allow-unknown-plans")...); code != exitOK {
		t.Errorf("--allow-unknown-plans: exit %d: %s", code, errOut)
	}
}

// TestAzureNodesPriced: with nodes deployed the report prices VMs and the
// Premium SSD tiers of their disks.
func TestAzureNodesPriced(t *testing.T) {
	skipWithoutAzureModule(t)
	f := filepath.Join(t.TempDir(), "t.tfvars")
	body := `deploy_nodes = true
gpu_pools = { g = { instance_type = "Standard_NC24ads_A100_v4", count = 1 } }`
	if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	code, out, errOut := exec("--provider", "azure", "--no-network", "--catalog", azureCatalog, "--var-file", azureTfvars, "--var-file", f)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	for _, want := range []string{"Standard_NC24ads_A100_v4", "Standard_D8s_v5", "disk:P10", "disk:P15"} {
		if !strings.Contains(out, want) {
			t.Errorf("report lacks %q:\n%s", want, out)
		}
	}
	compareGolden(t, "azure-nodes.txt", out)
}
