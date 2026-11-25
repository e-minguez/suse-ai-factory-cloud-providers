//go:build live

// Builds only under `go test -tags live` (make cost-fixtures): it calls the
// real Cloud Billing Catalog API to notice when the SKU descriptions the
// estimator matches no longer exist. Skipped without GCP_PRICING_API_KEY.
package gcp

import (
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

func TestLiveCatalogStillHasRates(t *testing.T) {
	key := os.Getenv(KeyEnv)
	if key == "" {
		t.Skipf("%s is not set", KeyEnv)
	}
	live, err := FetchLive(t.Context(), http.DefaultClient, key, defaults["region"], 120*time.Second)
	if err != nil {
		t.Fatalf("fetching the live catalog: %v", err)
	}
	cat, err := live.ToCatalog(defaults["region"], pricing.CatalogInfo{Source: "api"})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{
		defaults["control_plane_instance_type"], defaults["jumphost_instance_type"],
		"g2-standard-8", "g4-standard-48", "c3-standard-8",
		rateIP, rateLBMin, rateNATVM, rateSnapshot, rateImage,
		diskPrefix + "pd-balanced", diskPrefix + "hyperdisk-balanced",
	} {
		if _, ok := cat.Lookup(id); !ok {
			t.Errorf("live catalog has no rate for %q in %s: fix the description patterns in catalog.go", id, defaults["region"])
		}
	}
}
