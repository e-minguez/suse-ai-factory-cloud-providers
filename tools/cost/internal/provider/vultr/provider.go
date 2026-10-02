package vultr

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

type vultr struct{}

func init() { provider.Register(vultr{}) }

func (vultr) Name() string { return "vultr" }

// Resolve applies the locals.tf defaults. The module has no provider-only
// variable that affects price.
func (vultr) Resolve(c tfconfig.Common, _ *tfconfig.Vars) (provider.Config, []tfconfig.Diagnostic) {
	var diags []tfconfig.Diagnostic
	if c.ControlPlaneInstanceType == "" {
		c.ControlPlaneInstanceType = defaults["control_plane_instance_type"]
	}
	if c.JumphostInstanceType == "" {
		c.JumphostInstanceType = defaults["jumphost_instance_type"]
	}
	if c.Region == "" {
		diags = append(diags, tfconfig.Diagnostic{Severity: tfconfig.SeverityError, Summary: `variable "region" has no default and no value was found in the tfvars; pass --region`})
	}
	return provider.Config{Common: c}, diags
}

// Catalog resolves rates in this order: the --catalog file; with --no-network
// the warm cache; otherwise the public API (saving the cache), falling back
// to the cache when the API is unreachable.
func (vultr) Catalog(ctx context.Context, region string, o provider.CatalogOpts) (pricing.Catalog, error) {
	if o.File != "" {
		plans, err := LoadPlansFile(o.File)
		if err != nil {
			return nil, fmt.Errorf("loading --catalog %s: %w", o.File, err)
		}
		return plans.ToCatalog(region, pricing.CatalogInfo{Source: "file"}), nil
	}

	cache := ""
	if o.CacheDir != "" {
		cache = cachePath(o.CacheDir)
	}
	fromCache := func(note string) (pricing.Catalog, bool) {
		if cache == "" {
			return nil, false
		}
		plans, at, err := LoadCache(cache)
		if err != nil {
			return nil, false
		}
		age := time.Since(at).Round(time.Minute)
		return plans.ToCatalog(region, pricing.CatalogInfo{Source: "cache", AsOf: at.UTC().Format(time.RFC3339), Age: fmt.Sprintf("(%s old%s)", age, note)}), true
	}

	if o.NoNetwork {
		if c, ok := fromCache(""); ok {
			return c, nil
		}
		return nil, fmt.Errorf("--no-network was set, no --catalog given, and no warm cache is available at %s", cache)
	}

	fetchedAt := time.Now()
	plans, err := FetchLive(ctx, http.DefaultClient, 15*time.Second)
	if err == nil {
		if cache != "" {
			_ = SaveCache(cache, plans, fetchedAt) // best effort
		}
		return plans.ToCatalog(region, pricing.CatalogInfo{Source: "api", AsOf: fetchedAt.UTC().Format(time.RFC3339)}), nil
	}
	if c, ok := fromCache(", network unavailable"); ok {
		return c, nil
	}
	return nil, fmt.Errorf("fetching the live plan catalog failed and no cache or --catalog is available: %w", err)
}
