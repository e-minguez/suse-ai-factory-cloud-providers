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
	exoscaleCatalog = "internal/provider/exoscale/testdata/pricing.json"
	exoscaleExample = "../../examples/exoscale/terraform.tfvars.example"
)

// TestExoscaleExampleGolden runs the whole pipeline against the shipped
// example tfvars with the fixture price list, in text and JSON.
func TestExoscaleExampleGolden(t *testing.T) {
	base := []string{"--provider", "exoscale", "--no-network", "--catalog", exoscaleCatalog, "--var-file", exoscaleExample}

	code, out, errOut := exec(base...)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if lines[0] != pricing.Disclaimer || lines[len(lines)-1] != pricing.Disclaimer {
		t.Error("the text report must start and end with the disclaimer")
	}
	for _, want := range []string{"EUR", "Region: de-fra-1", "network load balancer", "image template", "outbound traffic"} {
		if !strings.Contains(out, want) {
			t.Errorf("report lacks %q:\n%s", want, out)
		}
	}
	compareGolden(t, "exoscale-example.txt", out)

	code, out, errOut = exec(append([]string{"--json"}, base...)...)
	if code != exitOK {
		t.Fatalf("json: exit %d: %s", code, errOut)
	}
	var doc struct {
		Disclaimer string `json:"disclaimer"`
		Currency   string `json:"currency"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil || doc.Disclaimer != pricing.Disclaimer || doc.Currency != "EUR" {
		t.Errorf("JSON disclaimer/currency wrong: %+v, %v", doc, err)
	}
	compareGolden(t, "exoscale-example.json", out)
}

// TestExoscaleUnknownTypeExitsPrice: an instance type without a price key
// fails with exit code 3 unless --allow-unknown-plans is set.
func TestExoscaleUnknownTypeExitsPrice(t *testing.T) {
	base := []string{"--provider", "exoscale", "--no-network", "--catalog", exoscaleCatalog, "--var-file", exoscaleExample}
	bad := filepath.Join(t.TempDir(), "t.tfvars")
	if err := os.WriteFile(bad, []byte(`worker_pools = { w = { instance_type = "standard.nope", count = 1 } }`), 0o600); err != nil {
		t.Fatal(err)
	}
	if code, _, errOut := exec(append(base, "--var-file", bad)...); code != exitPrice || !strings.Contains(errOut, "standard.nope") {
		t.Errorf("exit %d, stderr %q; want exit %d naming the type", code, errOut, exitPrice)
	}
	if code, _, errOut := exec(append(base, "--var-file", bad, "--allow-unknown-plans")...); code != exitOK {
		t.Errorf("--allow-unknown-plans: exit %d: %s", code, errOut)
	}
}
