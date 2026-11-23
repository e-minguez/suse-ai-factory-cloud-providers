package azure

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
)

const fixture = "testdata/prices.json"

func catalogOpts(file string, noNetwork bool, cacheDir string) provider.CatalogOpts {
	return provider.CatalogOpts{File: file, NoNetwork: noNetwork, CacheDir: cacheDir}
}

func fixtureCatalog(t *testing.T) pricing.Catalog {
	t.Helper()
	pl, err := LoadPriceListFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	cat, err := pl.ToCatalog("westeurope", pricing.CatalogInfo{Source: "file"})
	if err != nil {
		t.Fatal(err)
	}
	return cat
}

func TestLookup(t *testing.T) {
	cat := fixtureCatalog(t)
	tests := []struct {
		id      string
		hourly  pricing.Micros
		monthly pricing.Micros
	}{
		// Linux on-demand only: not Windows (0.828), Spot or Low Priority.
		{"Standard_D8s_v5", 460000, 0},
		{"standard_d4s_v5", 230000, 0},
		{"Standard_NC24ads_A100_v4", 4775000, 0},
		// Disks: tier monthly price divided by the tier size in GiB.
		{"disk:P10", 0, 169375}, // 21.68 / 128
		{"disk:P15", 0, 163326}, // 41.811428 / 256
		{"disk:P30", 0, 145195}, // 148.68 / 1024
		{rateIP, 5000, 0},
		{rateLB, 25000, 0}, // not the "- Free" or overage meters
		{rateNAT, 45000, 0},
	}
	for _, tt := range tests {
		p, ok := cat.Lookup(tt.id)
		if !ok || p.Hourly != tt.hourly || p.GBMonthly != tt.monthly {
			t.Errorf("Lookup(%q) = %+v, %v; want hourly %d monthly %d", tt.id, p, ok, tt.hourly, tt.monthly)
		}
	}
	for _, id := range []string{"Standard_Nope_v9", "disk:P99", "disk:P5", "nope"} {
		if _, ok := cat.Lookup(id); ok {
			t.Errorf("Lookup(%q) must miss", id)
		}
	}
	if cat.Currency() != "USD" {
		t.Errorf("currency = %q", cat.Currency())
	}
}

func TestOtherRegionMisses(t *testing.T) {
	pl, err := LoadPriceListFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	cat, err := pl.ToCatalog("northeurope", pricing.CatalogInfo{})
	if err != nil {
		t.Fatal(err) // the global LB and NAT meters remain
	}
	for _, id := range []string{"Standard_D8s_v5", "disk:P10", rateIP} {
		if _, ok := cat.Lookup(id); ok {
			t.Errorf("Lookup(%q) must miss in another region", id)
		}
	}
	if _, ok := cat.Lookup(rateLB); !ok {
		t.Error("the global load balancer rate applies to every region")
	}
}

func TestTierFor(t *testing.T) {
	for gb, want := range map[float64]string{1: "P1", 4: "P1", 5: "P2", 100: "P10", 128: "P10", 129: "P15", 200: "P15", 500: "P20", 1024: "P30", 1025: "P40", 32767: "P80"} {
		if got, ok := tierFor(gb); !ok || got.Name != want {
			t.Errorf("tierFor(%v) = %v, %v; want %s", gb, got, ok, want)
		}
	}
	if _, ok := tierFor(32768); ok {
		t.Error("32768 GiB fits no tier")
	}
}

func TestPriceListErrors(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{
		"empty.json":  `{"Items": []}`,
		"syntax.json": `{`,
	} {
		f := filepath.Join(dir, name)
		if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadPriceListFile(f); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
	pl := PriceList{Items: []Item{{ServiceName: "Virtual Machines", Type: "Consumption", ArmRegionName: "x", ArmSkuName: "a", SkuName: "a", RetailPrice: "1", UnitOfMeasure: "1 Hour"}}}
	if _, err := pl.ToCatalog("westeurope", pricing.CatalogInfo{}); err == nil {
		t.Error("a list with nothing for the region must fail")
	}
}

func TestCacheRoundTrip(t *testing.T) {
	pl, err := LoadPriceListFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "c", "azure-pricing-westeurope.json")
	at := time.Date(2026, 11, 23, 10, 0, 0, 0, time.UTC)
	if err := SaveCache(path, "westeurope", pl, at); err != nil {
		t.Fatal(err)
	}
	got, gotAt, err := LoadCache(path)
	if err != nil {
		t.Fatal(err)
	}
	if !gotAt.Equal(at) || len(got.Items) != len(pl.Items) {
		t.Errorf("cache round trip lost data: %v %d", gotAt, len(got.Items))
	}
	if _, err := got.ToCatalog("westeurope", pricing.CatalogInfo{}); err != nil {
		t.Error(err)
	}
}

func TestCatalogSources(t *testing.T) {
	ctx := t.Context()
	cat, err := azure{}.Catalog(ctx, "westeurope", catalogOpts(fixture, true, ""))
	if err != nil || cat.Info().Source != "file" {
		t.Fatalf("--catalog: %v, %+v", err, cat)
	}

	dir := t.TempDir()
	if _, err := (azure{}).Catalog(ctx, "westeurope", catalogOpts("", true, dir)); err == nil || !strings.Contains(err.Error(), "no warm cache") {
		t.Errorf("--no-network with a cold cache: %v", err)
	}
	pl, _ := LoadPriceListFile(fixture)
	if err := SaveCache(cachePath(dir, "westeurope"), "westeurope", pl, time.Now().Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	// "West Europe" is normalised to the armRegionName.
	cat, err = azure{}.Catalog(ctx, "West Europe", catalogOpts("", true, dir))
	if err != nil || cat.Info().Source != "cache" || !strings.Contains(cat.Info().Age, "2h0m0s old") {
		t.Errorf("warm cache: %v, %+v", err, cat)
	}
	if _, err := (azure{}).Catalog(ctx, "northeurope", catalogOpts("", true, dir)); err == nil {
		t.Error("the cache is per region")
	}
}
