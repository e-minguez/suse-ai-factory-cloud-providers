package exoscale

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

const fixture = "testdata/pricing.json"

func TestInstanceKey(t *testing.T) {
	for in, want := range map[string]string{
		"standard.extra-large": "running_extra_large",
		"Standard.Large":       "running_large",
		"gpu3.small":           "running_gpu3_small",
		"gpurtx6000pro.huge":   "running_gpurtx6000pro_huge",
		"cpu.extra-large":      "running_cpu_extra_large",
		"storage.mega":         "running_storage_mega",
	} {
		if got, ok := instanceKey(in); !ok || got != want {
			t.Errorf("instanceKey(%q) = %q, %v; want %q", in, got, ok, want)
		}
	}
	for _, bad := range []string{"", "standard", ".large", "standard."} {
		if _, ok := instanceKey(bad); ok {
			t.Errorf("instanceKey(%q) must fail", bad)
		}
	}
}

func TestToCatalog(t *testing.T) {
	pl, err := LoadPriceListFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	cat, err := pl.ToCatalog(pricing.CatalogInfo{Source: "file"})
	if err != nil {
		t.Fatal(err)
	}
	if cat.Currency() != "EUR" {
		t.Errorf("Currency = %q", cat.Currency())
	}
	for id, want := range map[string]pricing.Micros{
		"standard.extra-large": 186_670,
		"gpu3.small":           1_045_300,
		"gpua30.small":         1_226_458, // 1.22645833 rounds to micros
		rateDisk:               140,
		rateDiskStorage:        60,
		rateTemplate:           280,
		rateLB:                 34_720,
	} {
		p, ok := cat.Lookup(id)
		if !ok || p.Hourly != want || p.MonthlyCap != 0 || p.MinHours != 0 {
			t.Errorf("Lookup(%q) = %+v, %v; want hourly %d", id, p, ok, want)
		}
	}
	for _, id := range []string{"standard.nope", "nope", "storage:snapshot"} {
		if _, ok := cat.Lookup(id); ok {
			t.Errorf("Lookup(%q) must miss", id)
		}
	}
}

func TestDiskRate(t *testing.T) {
	if diskRate("storage.huge") != rateDiskStorage || diskRate("standard.huge") != rateDisk || diskRate("gpu3.small") != rateDisk {
		t.Error("storage optimized instances bill their disk at volume_data, every other family at volume")
	}
}

func TestPriceListErrors(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{
		"no-eur.json": `{"chf": {"volume": "0.1"}}`,
		"bad.json":    `{"eur": {"volume": "x"}}`,
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

func TestCacheRoundTrip(t *testing.T) {
	pl, err := LoadPriceListFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "c", "exoscale-pricing.json")
	at := time.Date(2026, 10, 7, 10, 0, 0, 0, time.UTC)
	if err := SaveCache(path, pl, at); err != nil {
		t.Fatal(err)
	}
	got, gotAt, err := LoadCache(path)
	if err != nil {
		t.Fatal(err)
	}
	if !gotAt.Equal(at) || len(got[currency]) != len(pl[currency]) || got[currency]["volume"] != pl[currency]["volume"] {
		t.Errorf("cache round trip lost data: %v %d", gotAt, len(got[currency]))
	}
}

func TestCatalogSources(t *testing.T) {
	ctx := t.Context()
	cat, err := exoscale{}.Catalog(ctx, "de-fra-1", catalogOpts(fixture, true, ""))
	if err != nil || cat.Info().Source != "file" {
		t.Fatalf("--catalog: %v, %+v", err, cat)
	}

	dir := t.TempDir()
	if _, err := (exoscale{}).Catalog(ctx, "", catalogOpts("", true, dir)); err == nil || !strings.Contains(err.Error(), "no warm cache") {
		t.Errorf("--no-network with a cold cache: %v", err)
	}
	pl, _ := LoadPriceListFile(fixture)
	if err := SaveCache(cachePath(dir), pl, time.Now().Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	cat, err = exoscale{}.Catalog(ctx, "", catalogOpts("", true, dir))
	if err != nil || cat.Info().Source != "cache" || !strings.Contains(cat.Info().Age, "2h0m0s old") {
		t.Errorf("warm cache: %v, %+v", err, cat)
	}
}
