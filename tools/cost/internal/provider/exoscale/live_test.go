//go:build live

// Builds only under `go test -tags live` (make cost-fixtures): it makes a
// real network call to notice when the price list no longer has the keys
// testdata/pricing.json and the module defaults rely on.
package exoscale

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

func TestLivePriceListStillHasFixtureKeys(t *testing.T) {
	live, err := FetchLive(context.Background(), http.DefaultClient, 15*time.Second)
	if err != nil {
		t.Fatalf("fetching live price list: %v", err)
	}
	fixture, err := LoadPriceListFile("testdata/pricing.json")
	if err != nil {
		t.Fatalf("loading fixture: %v", err)
	}
	for k := range fixture[currency] {
		if _, ok := live[currency][k]; !ok {
			t.Errorf("price key %q from testdata/pricing.json is gone from the live list -- refresh the fixture", k)
		}
	}
	cat, err := live.ToCatalog(pricing.CatalogInfo{Source: "api"})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{defaults["control_plane_instance_type"], defaults["jumphost_instance_type"], rateDisk, rateTemplate, rateLB} {
		if _, ok := cat.Lookup(id); !ok {
			t.Errorf("live price list has no rate for %q", id)
		}
	}
}
