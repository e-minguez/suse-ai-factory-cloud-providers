package oci

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
)

const fixture = "testdata/pricing.json"

func catalogOpts(file string, noNetwork bool, cacheDir string) provider.CatalogOpts {
	return provider.CatalogOpts{File: file, NoNetwork: noNetwork, CacheDir: cacheDir}
}

func fixtureCatalog(t *testing.T) pricing.Catalog {
	t.Helper()
	pl, err := LoadPriceListFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	cat, err := pl.ToCatalog(pricing.CatalogInfo{Source: "file"})
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
		// E5: 0.03 per OCPU-hour + 0.002 per GB-hour.
		{"VM.Standard.E5.Flex:4x32", 4*30000 + 32*2000, 0},
		{"vm.standard.e5.flex:2x16", 2*30000 + 16*2000, 0},
		{"VM.Standard.E4.Flex:1x8", 25000 + 8*1500, 0},
		// A1: the free tier is not applied.
		{"VM.Standard.A1.Flex:4x24", 4*10000 + 24*1500, 0},
		{"VM.Standard3.Flex:2x16", 2*40000 + 16*1500, 0},
		// GPU shapes: per GPU-hour, CPU and memory included.
		{"VM.GPU.A10.1", 2_000_000, 0},
		{"VM.GPU.A10.2", 4_000_000, 0},
		// Block volume 0.0255 + 10 VPU * 0.0017.
		{rateBoot, 0, 42500},
		{rateObject, 0, 25500},
	}
	for _, tt := range tests {
		p, ok := cat.Lookup(tt.id)
		if !ok || p.Hourly != tt.hourly || p.GBMonthly != tt.monthly {
			t.Errorf("Lookup(%q) = %+v, %v; want hourly %d monthly %d", tt.id, p, ok, tt.hourly, tt.monthly)
		}
	}
	for _, id := range []string{"VM.Standard.Nope.Flex:2x16", "VM.Standard.E5.Flex", "VM.Standard.E5.Flex:0x16", "VM.GPU.Nope.1", "VM.GPU.A10.1:2x16", "BM.GPU.A10.4", "lb", "nope"} {
		if _, ok := cat.Lookup(id); ok {
			t.Errorf("Lookup(%q) must miss", id)
		}
	}
	if cat.Currency() != "USD" {
		t.Errorf("currency = %q", cat.Currency())
	}
}

func TestPriceListErrors(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{
		"empty.json":  `{"items": []}`,
		"no-usd.json": `{"items": [{"partNumber": "B97384", "currencyCodeLocalizations": [{"currencyCode": "EUR", "prices": [{"model": "PAY_AS_YOU_GO", "value": 0.03}]}]}]}`,
		"syntax.json": `{`,
	} {
		f := filepath.Join(dir, name)
		if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		pl, err := LoadPriceListFile(f)
		if err == nil {
			_, err = pl.ToCatalog(pricing.CatalogInfo{})
		}
		if err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}

func TestFilteredKeepsOnlyUsedParts(t *testing.T) {
	pl, err := LoadPriceListFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	pl.Items = append(pl.Items, Item{PartNumber: "B00000"})
	got := pl.filtered()
	if len(got.Items) != len(pl.Items)-1 || got.LastUpdated != pl.LastUpdated {
		t.Errorf("filtered kept %d of %d items", len(got.Items), len(pl.Items))
	}
}

func TestCacheRoundTrip(t *testing.T) {
	pl, err := LoadPriceListFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "c", "oci-pricing.json")
	at := time.Date(2026, 11, 13, 10, 0, 0, 0, time.UTC)
	if err := SaveCache(path, pl, at); err != nil {
		t.Fatal(err)
	}
	got, gotAt, err := LoadCache(path)
	if err != nil {
		t.Fatal(err)
	}
	if !gotAt.Equal(at) || len(got.Items) != len(pl.Items) {
		t.Errorf("cache round trip lost data: %v %d", gotAt, len(got.Items))
	}
	if _, err := got.ToCatalog(pricing.CatalogInfo{}); err != nil {
		t.Error(err)
	}
}

func TestCatalogSources(t *testing.T) {
	ctx := t.Context()
	cat, err := oci{}.Catalog(ctx, "eu-frankfurt-1", catalogOpts(fixture, true, ""))
	if err != nil || cat.Info().Source != "file" || cat.Info().AsOf == "" {
		t.Fatalf("--catalog: %v, %+v", err, cat)
	}

	dir := t.TempDir()
	if _, err := (oci{}).Catalog(ctx, "", catalogOpts("", true, dir)); err == nil || !strings.Contains(err.Error(), "no warm cache") {
		t.Errorf("--no-network with a cold cache: %v", err)
	}
	pl, _ := LoadPriceListFile(fixture)
	if err := SaveCache(cachePath(dir), pl, time.Now().Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	cat, err = oci{}.Catalog(ctx, "", catalogOpts("", true, dir))
	if err != nil || cat.Info().Source != "cache" || !strings.Contains(cat.Info().Age, "2h0m0s old") {
		t.Errorf("warm cache: %v, %+v", err, cat)
	}
}
