//go:build live

// Builds only under `go test -tags live` (make cost-fixtures): it makes a
// real network call to notice when the price list no longer has the parts
// the estimator and the module defaults rely on.
package oci

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

func TestLivePriceListStillHasFixtureParts(t *testing.T) {
	live, err := FetchLive(context.Background(), http.DefaultClient, 30*time.Second)
	if err != nil {
		t.Fatalf("fetching live price list: %v", err)
	}
	have := map[string]bool{}
	for _, it := range live.Items {
		have[it.PartNumber] = true
	}
	for p := range wanted() {
		if !have[p] {
			t.Errorf("part %q is gone from the live list -- update the part number tables", p)
		}
	}
	cat, err := live.ToCatalog(pricing.CatalogInfo{Source: "api"})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{defaults["control_plane_instance_type"], defaults["jumphost_instance_type"], "VM.GPU.A10.1", "VM.GPU.A10.2", rateBoot, rateObject} {
		if _, ok := cat.Lookup(id); !ok {
			t.Errorf("live price list has no rate for %q", id)
		}
	}
}
