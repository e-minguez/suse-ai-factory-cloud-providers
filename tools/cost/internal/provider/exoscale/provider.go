// Package exoscale estimates the cost of modules/exoscale from Exoscale's
// public price list.
package exoscale

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

type exoscale struct{}

func init() { provider.Register(exoscale{}) }

func (exoscale) Name() string { return "exoscale" }

// Resolve applies the locals.tf defaults. Prices have no zone dimension; the
// zone only labels the report. No provider-only variable affects price.
func (exoscale) Resolve(c tfconfig.Common, _ *tfconfig.Vars) (provider.Config, []tfconfig.Diagnostic) {
	if c.Region == "" {
		c.Region = defaults["region"]
	}
	if c.ControlPlaneInstanceType == "" {
		c.ControlPlaneInstanceType = defaults["control_plane_instance_type"]
	}
	if c.JumphostInstanceType == "" {
		c.JumphostInstanceType = defaults["jumphost_instance_type"]
	}
	if c.ControlPlaneDiskGB == nil {
		c.ControlPlaneDiskGB = defaultFloat("control_plane_disk_size_gb")
	}
	if c.JumphostDiskGB == nil {
		c.JumphostDiskGB = defaultFloat("jumphost_disk_size_gb")
	}
	return provider.Config{Common: c}, nil
}

func defaultFloat(name string) *float64 {
	f, _ := strconv.ParseFloat(defaults[name], 64)
	return &f
}

// Catalog resolves rates in this order: the --catalog file; with --no-network
// the warm cache; otherwise the public price list (saving the cache), falling
// back to the cache when it is unreachable. The zone does not change prices.
func (exoscale) Catalog(ctx context.Context, _ string, o provider.CatalogOpts) (pricing.Catalog, error) {
	if o.File != "" {
		pl, err := LoadPriceListFile(o.File)
		if err != nil {
			return nil, fmt.Errorf("loading --catalog %s: %w", o.File, err)
		}
		return pl.ToCatalog(pricing.CatalogInfo{Source: "file"})
	}

	cache := ""
	if o.CacheDir != "" {
		cache = cachePath(o.CacheDir)
	}
	fromCache := func(note string) (pricing.Catalog, bool) {
		if cache == "" {
			return nil, false
		}
		pl, at, err := LoadCache(cache)
		if err != nil {
			return nil, false
		}
		age := time.Since(at).Round(time.Minute)
		cat, err := pl.ToCatalog(pricing.CatalogInfo{Source: "cache", AsOf: at.UTC().Format(time.RFC3339), Age: fmt.Sprintf("(%s old%s)", age, note)})
		return cat, err == nil
	}

	if o.NoNetwork {
		if c, ok := fromCache(""); ok {
			return c, nil
		}
		return nil, fmt.Errorf("--no-network was set, no --catalog given, and no warm cache is available at %s", cache)
	}

	fetchedAt := time.Now()
	pl, err := FetchLive(ctx, http.DefaultClient, 15*time.Second)
	if err == nil {
		if cache != "" {
			_ = SaveCache(cache, pl, fetchedAt) // best effort
		}
		return pl.ToCatalog(pricing.CatalogInfo{Source: "api", AsOf: fetchedAt.UTC().Format(time.RFC3339)})
	}
	if c, ok := fromCache(", network unavailable"); ok {
		return c, nil
	}
	return nil, fmt.Errorf("fetching the price list failed and no cache or --catalog is available: %w", err)
}
