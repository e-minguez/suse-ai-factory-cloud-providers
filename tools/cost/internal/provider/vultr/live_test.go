//go:build live

// This file only builds under `go test -tags live` (run it with `go test -tags live ./internal/provider/vultr/...`),
// never under a plain `go test ./...`: a public rate card rots silently, and
// this test's only job is to notice when Vultr's has moved out from under
// testdata/plans.json. It makes a real network call.
package vultr

import (
	"context"
	"net/http"
	"testing"
	"time"
)

// TestLiveCatalogStillHasFixturePlans fetches the real API and checks that
// every plan ID this repo's testdata assumes still exists, with the same
// InvoiceType. It does not check prices: those are expected to drift.
func TestLiveCatalogStillHasFixturePlans(t *testing.T) {
	live, err := FetchLive(context.Background(), http.DefaultClient, 15*time.Second)
	if err != nil {
		t.Fatalf("fetching live catalog: %v", err)
	}

	fixture, err := LoadPlansFile("testdata/plans.json")
	if err != nil {
		t.Fatalf("loading fixture: %v", err)
	}

	for id, want := range fixture {
		got, ok := live.Lookup(id)
		if !ok {
			t.Errorf("plan %q from testdata/plans.json no longer exists in the live catalog -- refresh the fixtures", id)
			continue
		}
		if got.InvoiceType != want.InvoiceType {
			t.Errorf("plan %q invoice_type changed from %q to %q live -- refresh fixtures and re-check pricing.Charge's cap assumptions", id, want.InvoiceType, got.InvoiceType)
		}
	}
}
