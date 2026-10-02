//go:build live

package aws

import (
	"context"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
)

// TestLiveCatalog needs AWS credentials with pricing:GetProducts.
func TestLiveCatalog(t *testing.T) {
	p := &awsProvider{types: []string{"m7i.xlarge"}}
	cat, err := p.Catalog(context.Background(), "us-east-1", provider.CatalogOpts{})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"m7i.xlarge", rateLB, rateNAT, ratePublicIP, rateDisk, rateSnapshot} {
		if pl, ok := cat.Lookup(id); !ok || (pl.Hourly == 0 && pl.GBMonthly == 0) {
			t.Errorf("%s: %+v, found=%v", id, pl, ok)
		}
	}
}
