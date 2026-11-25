package gcp

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
)

const (
	fixture = "testdata/skus.json"
	region  = "europe-west4"
)

func opts(file string, noNetwork bool, cacheDir string) provider.CatalogOpts {
	return provider.CatalogOpts{File: file, NoNetwork: noNetwork, CacheDir: cacheDir}
}

func fixtureCatalog(t *testing.T) pricing.Catalog {
	t.Helper()
	pl, err := LoadPriceListFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	cat, err := pl.ToCatalog(region, pricing.CatalogInfo{Source: "file"})
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
		// N2: 0.036 per vCPU-hour + 0.005 per GB-hour; standard is 4 GB per vCPU.
		{"n2-standard-4", 4*36000 + 16*5000, 0},
		{"n2-highmem-8", 8*36000 + 64*5000, 0},
		{"n2-highcpu-16", 16*36000 + 16*5000, 0},
		{"e2-standard-4", 4*25000 + 16*3000, 0},
		// G2 adds the L4 per GPU: g2-standard-24 has 2 GPUs and 96 GB.
		{"g2-standard-4", 4*30000 + 16*4000 + 800000, 0},
		{"g2-standard-24", 24*30000 + 96*4000 + 2*800000, 0},
		{"c3-standard-8", 8*40000 + 32*5500, 0},
		{"g4-standard-48", 48*45000 + 180*6000 + 3_000_000, 0},
		{rateIP, 5000, 0},
		{rateLBMin, 25000, 0},
		{rateLBExtra, 10000, 0},
		{rateNATVM, 1400, 0},
		{diskPrefix + "pd-balanced", 0, 120000},
		{diskPrefix + "hyperdisk-balanced", 0, 140000},
		{rateSnapshot, 0, 26000},
		{rateImage, 0, 50000},
	}
	for _, tt := range tests {
		p, ok := cat.Lookup(tt.id)
		if !ok || p.Hourly != tt.hourly || p.GBMonthly != tt.monthly {
			t.Errorf("Lookup(%q) = %+v, %v; want hourly %d monthly %d", tt.id, p, ok, tt.hourly, tt.monthly)
		}
	}
	// No such price in the catalog, or a type outside the tables.
	for _, id := range []string{"n2-standard-4:x", "e2-micro", "n2-custom-4-8192", "c2-highmem-8", "a3-highgpu-8g", "disk:pd-ssd", "g4-standard-12", "lb", "nope"} {
		if _, ok := cat.Lookup(id); ok {
			t.Errorf("Lookup(%q) must miss", id)
		}
	}
	if cat.Currency() != "USD" || cat.Info().AsOf != "2026-11-20T00:00:00Z" {
		t.Errorf("currency %q, info %+v", cat.Currency(), cat.Info())
	}
}

// Decoys in the fixture (commitment, spot, custom, other region, regional
// disk, wrong unit) must not leak into any rate.
func TestOtherRegionAndNoRegion(t *testing.T) {
	pl, err := LoadPriceListFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	cat, err := pl.ToCatalog("europe-west3", pricing.CatalogInfo{})
	if err != nil {
		t.Fatal(err)
	}
	if p, ok := cat.Lookup(diskPrefix + "pd-balanced"); !ok || p.GBMonthly != 999000 {
		t.Errorf("europe-west3 disk = %+v, %v", p, ok)
	}
	if _, ok := cat.Lookup("n2-standard-4"); ok {
		t.Error("europe-west3 has a core SKU but no RAM SKU: n2 must miss")
	}
	if _, err := pl.ToCatalog("us-central1", pricing.CatalogInfo{}); err == nil || !strings.Contains(err.Error(), "us-central1") {
		t.Errorf("a region without prices must fail: %v", err)
	}
}

func TestParseMachine(t *testing.T) {
	m, ok := parseMachine("c4-highmem-8")
	if !ok || m.vcpu != 8 || m.ramGB != 62 || m.family != "c4" {
		t.Errorf("c4-highmem-8 = %+v, %v", m, ok)
	}
	m, ok = parseMachine("a3-highgpu-8g")
	if !ok || m.gpus != 8 || m.gpu != "h100-80" || m.family != "a3" {
		t.Errorf("a3-highgpu-8g = %+v, %v", m, ok)
	}
	for _, n := range []string{"e2-small", "n2-standard-0", "n1-ultramem-40", "g2-standard-5", "c2-highcpu-8"} {
		if _, ok := parseMachine(n); ok {
			t.Errorf("%s must be unknown", n)
		}
	}
	if defaultDiskType("n2-standard-4") != "pd-balanced" || defaultDiskType("g4-standard-48") != "hyperdisk-balanced" {
		t.Error("default disk types wrong")
	}
}

func TestPriceListErrors(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{
		"empty.json":  `{"skus": []}`,
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
}

func TestFilteredKeepsOnlyUsedSKUs(t *testing.T) {
	pl, err := LoadPriceListFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	pl.SKUs = append(pl.SKUs, SKU{SkuID: "Z", Description: "Something else", ServiceRegions: []string{region}, Category: Category{UsageType: "OnDemand"}})
	got := pl.filtered(region)
	// 27 fixture SKUs: 6 are decoys or other regions (the wrong-unit one stays).
	if len(got.SKUs) != 21 {
		t.Errorf("filtered kept %d SKUs", len(got.SKUs))
	}
}

func TestCacheRoundTrip(t *testing.T) {
	pl, _ := LoadPriceListFile(fixture)
	pl = pl.filtered(region)
	path := cachePath(filepath.Join(t.TempDir(), "c"), region)
	at := time.Date(2026, 11, 13, 10, 0, 0, 0, time.UTC)
	if err := SaveCache(path, pl, at); err != nil {
		t.Fatal(err)
	}
	got, gotAt, err := LoadCache(path)
	if err != nil || !gotAt.Equal(at) || len(got.SKUs) != len(pl.SKUs) {
		t.Fatalf("cache round trip: %v %v %d", err, gotAt, len(got.SKUs))
	}
	if _, err := got.ToCatalog(region, pricing.CatalogInfo{}); err != nil {
		t.Error(err)
	}
}

func TestCatalogSources(t *testing.T) {
	ctx := t.Context()
	cat, err := gcp{}.Catalog(ctx, region, opts(fixture, true, ""))
	if err != nil || cat.Info().Source != "file" || cat.Info().AsOf == "" {
		t.Fatalf("--catalog: %v, %+v", err, cat)
	}

	dir := t.TempDir()
	if _, err := (gcp{}).Catalog(ctx, region, opts("", true, dir)); err == nil || !strings.Contains(err.Error(), "no warm cache") {
		t.Errorf("--no-network with a cold cache: %v", err)
	}
	pl, _ := LoadPriceListFile(fixture)
	if err := SaveCache(cachePath(dir, region), pl.filtered(region), time.Now().Add(-2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	cat, err = gcp{}.Catalog(ctx, region, opts("", true, dir))
	if err != nil || cat.Info().Source != "cache" || !strings.Contains(cat.Info().Age, "2h0m0s old") {
		t.Errorf("warm cache: %v, %+v", err, cat)
	}

	// No API key: the warm cache serves, a cold one fails naming the variable.
	t.Setenv(KeyEnv, "")
	cat, err = gcp{}.Catalog(ctx, region, opts("", false, dir))
	if err != nil || !strings.Contains(cat.Info().Age, "no API key") {
		t.Errorf("no key, warm cache: %v, %+v", err, cat)
	}
	if _, err := (gcp{}).Catalog(ctx, region, opts("", false, t.TempDir())); err == nil || !strings.Contains(err.Error(), KeyEnv) {
		t.Errorf("no key, cold cache: %v", err)
	}
}

// TestFetchLive runs the paginated fetch against a fake API: the key goes in
// a header, never in the URL, and a failing Networking service is tolerated.
func TestFetchLive(t *testing.T) {
	pl, _ := LoadPriceListFile(fixture)
	half := len(pl.SKUs) / 2
	var urls []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		urls = append(urls, r.URL.String())
		if r.Header.Get("X-Goog-Api-Key") != "k3y" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		if strings.Contains(r.URL.Path, networkingService) {
			http.Error(w, "gone", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		enc := func(s []SKU, next string) {
			b, _ := json.Marshal(skuPage{SKUs: s, NextPageToken: next})
			_, _ = w.Write(b)
		}
		if r.URL.Query().Get("pageToken") == "" {
			enc(pl.SKUs[:half], "page2")
		} else {
			enc(pl.SKUs[half:], "")
		}
	}))
	defer srv.Close()
	old := BaseURL
	BaseURL = srv.URL
	defer func() { BaseURL = old }()

	got, err := FetchLive(t.Context(), srv.Client(), "k3y", region, 10*time.Second)
	if err != nil || len(got.SKUs) != 21 {
		t.Fatalf("FetchLive: %v, %d SKUs", err, len(got.SKUs))
	}
	for _, u := range urls {
		if strings.Contains(u, "k3y") {
			t.Errorf("the key is in the URL %s", u)
		}
	}
	if _, err := FetchLive(t.Context(), srv.Client(), "wrong", region, 10*time.Second); err == nil || strings.Contains(err.Error(), "wrong") {
		t.Errorf("a bad key must fail without echoing it: %v", err)
	}
}
