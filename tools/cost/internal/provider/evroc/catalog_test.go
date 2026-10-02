package evroc

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
)

func TestEmbeddedCatalog(t *testing.T) {
	cat, err := EmbeddedCatalog()
	if err != nil {
		t.Fatal(err)
	}
	if cat.Currency() != "EUR" {
		t.Errorf("Currency = %q", cat.Currency())
	}
	info := cat.Info()
	if info.AsOf != "2026-09-11" || !strings.Contains(info.Source, "public calculator") || !strings.Contains(info.Source, "no pricing API") {
		t.Errorf("Info = %+v", info)
	}
	for id, want := range map[string]pricing.Micros{
		"c1a.m": 206_000, "C1A.M": 206_000, "a1a.xs": 69_000, "gn-b200.s": 8_000_000,
		"gn-b200.xl": 64_000_000, "gn-l40s.l": 6_000_000, ratePublicIP: 10_000, rateDisk: 137,
	} {
		p, ok := cat.Lookup(id)
		if !ok || p.Hourly != want {
			t.Errorf("Lookup(%q) = %+v, %v; want hourly %d", id, p, ok, want)
		}
	}
	if _, ok := cat.Lookup("c1a.nope"); ok {
		t.Error("unknown SKU found")
	}
}

func TestCatalogFileOverrides(t *testing.T) {
	f := filepath.Join(t.TempDir(), "card.json")
	card := `{"currency":"EUR","as_of":"2030-01-01","source_url":"x","instances":{"X1.S":1.5},"storage_gb_hour":0.5,"public_ip_hour":0.25}`
	if err := os.WriteFile(f, []byte(card), 0o600); err != nil {
		t.Fatal(err)
	}
	cat, err := evroc{}.Catalog(t.Context(), "r", provider.CatalogOpts{File: f})
	if err != nil {
		t.Fatal(err)
	}
	if p, ok := cat.Lookup("x1.s"); !ok || p.Hourly != 1_500_000 {
		t.Errorf("x1.s = %+v, %v", p, ok)
	}
	if _, ok := cat.Lookup("c1a.m"); ok {
		t.Error("the embedded card leaked into a --catalog file")
	}
	if !strings.Contains(cat.Info().Source, "no pricing API") || cat.Info().AsOf != "2030-01-01" {
		t.Errorf("Info = %+v", cat.Info())
	}
}

func TestCatalogFileInvalid(t *testing.T) {
	for name, body := range map[string]string{
		"malformed":    `{`,
		"no currency":  `{"instances":{"a":1},"storage_gb_hour":1,"public_ip_hour":1}`,
		"no instances": `{"currency":"EUR","instances":{},"storage_gb_hour":1,"public_ip_hour":1}`,
		"no storage":   `{"currency":"EUR","instances":{"a":1},"public_ip_hour":1}`,
		"unknown key":  `{"currency":"EUR","instances":{"a":1},"storage_gb_hour":1,"public_ip_hour":1,"x":1}`,
		"bad number":   `{"currency":"EUR","instances":{"a":"abc"},"storage_gb_hour":1,"public_ip_hour":1}`,
	} {
		f := filepath.Join(t.TempDir(), "c.json")
		_ = os.WriteFile(f, []byte(body), 0o600)
		if _, err := LoadCatalogFile(f); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
	if _, err := LoadCatalogFile("/nonexistent.json"); err == nil {
		t.Error("missing file: want an error")
	}
}

// TestRateCardCoversModuleSKUs: every SKU that locals.tf and the
// example tfvars name must be priced, so a default never prices as unknown.
func TestRateCardCoversModuleSKUs(t *testing.T) {
	cat, err := EmbeddedCatalog()
	if err != nil {
		t.Fatal(err)
	}
	skus := map[string]bool{}
	for _, name := range []string{"control_plane_instance_type", "jumphost_instance_type"} {
		skus[defaults[name]] = true
	}
	// Instance types quoted in the example tfvars and the module's own
	// validation messages ("c1a.m", "gn-l40s.s").
	sku := regexp.MustCompile(`"((?:[acm]1a|gn-[a-z0-9]+)\.(?:xs|s|m|l|xl|2xl))"`)
	for _, path := range []string{
		"../../../../../examples/evroc/terraform.tfvars.example",
		"../../../../../modules/evroc/network.tf",
	} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range sku.FindAllStringSubmatch(string(data), -1) {
			skus[m[1]] = true
		}
	}
	if len(skus) < 3 {
		t.Fatalf("found only %v; the scan is broken", skus)
	}
	for s := range skus {
		if _, ok := cat.Lookup(s); !ok {
			t.Errorf("SKU %q used by the module is not in ratecard.json", s)
		}
	}
}
