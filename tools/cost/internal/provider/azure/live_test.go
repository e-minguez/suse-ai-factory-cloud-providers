//go:build live

// Builds only under `go test -tags live` (make cost-fixtures): it makes a
// real network call to notice when the Retail Prices API no longer has the
// meters the estimator and the module defaults rely on.
package azure

import (
	"net/http"
	"testing"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

func TestLivePricesStillHaveDefaults(t *testing.T) {
	region := defaults["region"]
	live, err := FetchLive(t.Context(), http.DefaultClient, region, 120*time.Second)
	if err != nil {
		t.Fatalf("fetching live prices: %v", err)
	}
	cat, err := live.ToCatalog(region, pricing.CatalogInfo{Source: "api"})
	if err != nil {
		t.Fatal(err)
	}
	ids := []string{defaults["control_plane_instance_type"], defaults["jumphost_instance_type"], rateIP, rateLB, rateNAT}
	for _, d := range diskTiers {
		ids = append(ids, diskPfx+d.Name)
	}
	for _, id := range ids {
		if p, ok := cat.Lookup(id); !ok || (p.Hourly == 0 && p.GBMonthly == 0) {
			t.Errorf("live prices have no rate for %q", id)
		}
	}
}
