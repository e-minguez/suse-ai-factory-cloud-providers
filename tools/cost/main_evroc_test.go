package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

const evrocExample = "../../examples/evroc/terraform.tfvars.example"

// TestEvrocExampleGolden runs the whole pipeline against the shipped example
// tfvars with the embedded rate card, in text and JSON. The example leaves
// region null, so --region is required.
func TestEvrocExampleGolden(t *testing.T) {
	base := []string{"--provider", "evroc", "--region", "eu-central", "--no-network", "--var-file", evrocExample}

	code, out, errOut := exec(base...)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if lines[0] != pricing.Disclaimer || lines[len(lines)-1] != pricing.Disclaimer {
		t.Error("the text report must start and end with the disclaimer")
	}
	for _, want := range []string{"EUR", "load balancer", "no pricing API", "outbound transfer"} {
		if !strings.Contains(out, want) {
			t.Errorf("report lacks %q:\n%s", want, out)
		}
	}
	compareGolden(t, "evroc-example.txt", out)

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
	compareGolden(t, "evroc-example.json", out)
}

func TestEvrocNullRegionIsLabelled(t *testing.T) {
	code, out, errOut := exec("--provider", "evroc", "--no-network", "--var-file", evrocExample)
	if code != exitOK || !strings.Contains(out, "Region: (evroc CLI context)") {
		t.Errorf("exit %d, stderr %q; want exit 0 and the CLI context label", code, errOut)
	}
}

// TestEvrocImageIDsSkipBuild: image_ids means no builders, no target disks
// and no snapshots, so the build-only section and the snapshot exclusion go.
func TestEvrocImageIDsSkipBuild(t *testing.T) {
	f := filepath.Join(t.TempDir(), "t.tfvars")
	body := "region = \"eu-central\"\nimage_ids = { a = \"x\", b = \"y\", c = \"z\" }\n"
	if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	code, out, errOut := exec("--provider", "evroc", "--no-network", "--var-file", evrocExample, "--var-file", f)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	if strings.Contains(out, "image snapshots") {
		t.Errorf("image_ids set but snapshots are listed:\n%s", out)
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "image ") && strings.Contains(line, "(build only)") && !strings.Contains(line, "--") {
			t.Errorf("image_ids set but a build row is priced: %s", line)
		}
	}
}

func TestEvrocCatalogFile(t *testing.T) {
	f := filepath.Join(t.TempDir(), "card.json")
	card := `{"currency":"EUR","as_of":"2030-01-01","source_url":"x","instances":{"a1a.m":1,"c1a.m":2},"storage_gb_hour":0.001,"public_ip_hour":0.5}`
	if err := os.WriteFile(f, []byte(card), 0o600); err != nil {
		t.Fatal(err)
	}
	code, out, errOut := exec("--provider", "evroc", "--region", "x", "--no-network", "--catalog", f, "--var-file", evrocExample)
	if code != exitOK || !strings.Contains(out, "2030-01-01") {
		t.Fatalf("exit %d: %s\n%s", code, errOut, out)
	}
}

func TestEvrocUnknownSKUExitsPrice(t *testing.T) {
	f := filepath.Join(t.TempDir(), "t.tfvars")
	_ = os.WriteFile(f, []byte("region = \"x\"\ncontrol_plane_instance_type = \"c1a.nope\"\n"), 0o600)
	if code, _, _ := exec("--provider", "evroc", "--no-network", "--var-file", evrocExample, "--var-file", f); code != exitPrice {
		t.Errorf("exit %d, want %d", code, exitPrice)
	}
}
