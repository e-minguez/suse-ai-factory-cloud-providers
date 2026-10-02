package aws

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
)

func TestFetchPlansParsesFixtures(t *testing.T) {
	api := newFake(t)
	plans, err := fetchPlans(context.Background(), api, "us-east-1", []string{"m7i.xlarge", "g5.2xlarge", "nope.large"})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]pricing.Plan{
		"m7i.xlarge": {Hourly: 201_600, MinHours: perSecondMin},
		"g5.2xlarge": {Hourly: 1_212_000, MinHours: perSecondMin},
		rateDisk:     {GBMonthly: 80_000, MinHours: perSecondMin},
		rateSnapshot: {GBMonthly: 50_000},
		rateNAT:      {Hourly: 45_000, MinHours: 1},
		ratePublicIP: {Hourly: 5_000, MinHours: 1},
		rateLB:       {Hourly: 22_500, MinHours: 1},
	}
	if len(plans) != len(want) {
		t.Errorf("got %d plans, want %d (unknown instance types are left out): %v", len(plans), len(want), plans)
	}
	for id, w := range want {
		w.ID = id
		if plans[id] != w {
			t.Errorf("%s = %+v, want %+v", id, plans[id], w)
		}
	}
}

func TestFetchFollowsPagination(t *testing.T) {
	api := newFake(t)
	api.pageSize = 1
	plans, err := fetchPlans(context.Background(), api, "us-east-1", []string{"c6i.xlarge"})
	if err != nil {
		t.Fatal(err)
	}
	if plans["c6i.xlarge"].Hourly != 170_000 || plans[rateLB].Hourly != 22_500 {
		t.Errorf("paged results lost: %+v", plans)
	}
}

func TestMissingFixedRateFails(t *testing.T) {
	api := newFake(t)
	if _, err := fetchPlans(context.Background(), api, "eu-nowhere-1", nil); err == nil || !strings.Contains(err.Error(), "region") {
		t.Errorf("err = %v, want a missing-price error naming the region", err)
	}
}

func TestAuthFailureIsClear(t *testing.T) {
	api := newFake(t)
	api.err = errors.New("failed to retrieve credentials: no EC2 IMDS role found")
	p := &awsProvider{api: api}
	_, err := p.Catalog(context.Background(), "us-east-1", provider.CatalogOpts{CacheDir: t.TempDir()})
	if err == nil {
		t.Fatal("want an error")
	}
	for _, s := range []string{"valid AWS credentials", "pricing:GetProducts", "aws sso login", "--catalog FILE", "no EC2 IMDS role"} {
		if !strings.Contains(err.Error(), s) {
			t.Errorf("error %q lacks %q", err, s)
		}
	}
	if api.calls != 1 {
		t.Errorf("%d calls after the auth failure, want 1", api.calls)
	}
}

func TestCatalogLiveSavesCacheAndNoNetworkReadsIt(t *testing.T) {
	dir := t.TempDir()
	p := &awsProvider{api: newFake(t)}
	p.types = []string{"m7i.xlarge"}
	cat, err := p.Catalog(context.Background(), "us-east-1", provider.CatalogOpts{CacheDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if cat.Info().Source != "api" || cat.Currency() != "USD" {
		t.Errorf("info = %+v, currency %s", cat.Info(), cat.Currency())
	}

	// A later run for other instance types adds to the cache.
	p.types = []string{"g5.2xlarge"}
	if _, err := p.Catalog(context.Background(), "us-east-1", provider.CatalogOpts{CacheDir: dir}); err != nil {
		t.Fatal(err)
	}

	offline := &awsProvider{} // no API: any network use would panic on nil
	cat, err = offline.Catalog(context.Background(), "us-east-1", provider.CatalogOpts{CacheDir: dir, NoNetwork: true})
	if err != nil {
		t.Fatal(err)
	}
	if cat.Info().Source != "cache" || cat.Info().Age == "" {
		t.Errorf("info = %+v, want cache with an age", cat.Info())
	}
	for _, id := range []string{"m7i.xlarge", "g5.2xlarge", rateLB, rateDisk} {
		if _, ok := cat.Lookup(id); !ok {
			t.Errorf("cache lacks %s", id)
		}
	}
	if _, err := offline.Catalog(context.Background(), "eu-west-1", provider.CatalogOpts{CacheDir: dir, NoNetwork: true}); err == nil {
		t.Error("no cache for the region: want an error")
	}
}

func TestCacheRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sub", "c.json")
	at := time.Date(2026, 9, 18, 10, 0, 0, 0, time.UTC)
	plans := map[string]pricing.Plan{"lb": {Hourly: 22_500, MinHours: 1}, rateDisk: {GBMonthly: 80_000, MinHours: perSecondMin}}
	if err := saveCacheFile(path, newCacheFile("us-east-1", at, plans)); err != nil {
		t.Fatal(err)
	}
	got, err := loadCacheFile(path)
	if err != nil {
		t.Fatal(err)
	}
	cat := got.catalog(pricing.CatalogInfo{})
	if !got.FetchedAt.Equal(at) || got.Region != "us-east-1" {
		t.Errorf("metadata lost: %+v", got)
	}
	for id, w := range plans {
		w.ID = id
		if p, _ := cat.Lookup(id); p != w {
			t.Errorf("%s = %+v, want %+v", id, p, w)
		}
	}
}

func TestCatalogFile(t *testing.T) {
	p := &awsProvider{}
	cat, err := p.Catalog(context.Background(), "us-east-1", provider.CatalogOpts{File: "testdata/catalog-us-east-1.json", NoNetwork: true})
	if err != nil {
		t.Fatal(err)
	}
	if pl, ok := cat.Lookup("m7i.xlarge"); !ok || pl.Hourly != 201_600 || cat.Info().Source != "file" {
		t.Errorf("m7i.xlarge = %+v, info %+v", pl, cat.Info())
	}
	if _, err := p.Catalog(context.Background(), "eu-west-1", provider.CatalogOpts{File: "testdata/catalog-us-east-1.json"}); err == nil || !strings.Contains(err.Error(), "us-east-1") {
		t.Errorf("err = %v, want a region mismatch", err)
	}
	if _, err := p.Catalog(context.Background(), "us-east-1", provider.CatalogOpts{File: "testdata/missing.json"}); err == nil {
		t.Error("missing file: want an error")
	}
}
