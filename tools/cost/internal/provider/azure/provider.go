// Package azure estimates the cost of modules/azure from the Azure Retail
// Prices API.
package azure

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

type azure struct{}

// details holds the azure-only variables that affect price.
type details struct {
	existingVPC bool // vpc_id set: the network and its NAT gateway already exist
}

func init() { provider.Register(azure{}) }

func (azure) Name() string { return "azure" }

// normRegion turns "West Europe" into the armRegionName "westeurope".
func normRegion(r string) string {
	return strings.ToLower(strings.ReplaceAll(strings.TrimSpace(r), " ", ""))
}

// Resolve applies the locals.tf defaults, reads vpc_id and checks the disk
// sizes fit a Premium SSD tier.
func (azure) Resolve(c tfconfig.Common, v *tfconfig.Vars) (provider.Config, []tfconfig.Diagnostic) {
	if c.Region == "" {
		c.Region = defaults["region"]
	}
	c.Region = normRegion(c.Region)
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

	var diags []tfconfig.Diagnostic
	check := func(who string, gb float64) {
		if _, ok := tierFor(gb); !ok {
			diags = append(diags, tfconfig.Diagnostic{Severity: tfconfig.SeverityError, Summary: fmt.Sprintf("%s = %v: larger than the biggest Premium SSD tier (32767 GiB)", who, gb)})
		}
	}
	check("jumphost_disk_size_gb", *c.JumphostDiskGB)
	check("control_plane_disk_size_gb", *c.ControlPlaneDiskGB)
	for _, grp := range [][]tfconfig.Pool{c.GPUPools, c.WorkerPools} {
		for _, p := range grp {
			if p.DiskGB != nil {
				check(fmt.Sprintf("pool %q disk_size_gb", p.Name), *p.DiskGB)
			}
		}
	}
	var det details
	if v != nil {
		det.existingVPC = v.IsSet("vpc_id")
	}
	return provider.Config{Common: c, Details: det}, diags
}

func defaultFloat(name string) *float64 {
	f, _ := strconv.ParseFloat(defaults[name], 64)
	return &f
}

// Catalog resolves rates in this order: the --catalog file; with --no-network
// the warm cache; otherwise the Retail Prices API (saving the cache), falling
// back to the cache when it is unreachable.
func (azure) Catalog(ctx context.Context, region string, o provider.CatalogOpts) (pricing.Catalog, error) {
	region = normRegion(region)
	if o.File != "" {
		pl, err := LoadPriceListFile(o.File)
		if err != nil {
			return nil, fmt.Errorf("loading --catalog %s: %w", o.File, err)
		}
		return pl.ToCatalog(region, pricing.CatalogInfo{Source: "file"})
	}

	cache := ""
	if o.CacheDir != "" {
		cache = cachePath(o.CacheDir, region)
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
		cat, err := pl.ToCatalog(region, pricing.CatalogInfo{Source: "cache", AsOf: at.UTC().Format(time.RFC3339), Age: fmt.Sprintf("(%s old%s)", age, note)})
		return cat, err == nil
	}

	if o.NoNetwork {
		if c, ok := fromCache(""); ok {
			return c, nil
		}
		return nil, fmt.Errorf("--no-network was set, no --catalog given, and no warm cache is available at %s", cache)
	}

	fetchedAt := time.Now()
	pl, err := FetchLive(ctx, http.DefaultClient, region, 120*time.Second)
	if err == nil {
		if cache != "" {
			_ = SaveCache(cache, region, pl, fetchedAt) // best effort
		}
		return pl.ToCatalog(region, pricing.CatalogInfo{Source: "api", AsOf: fetchedAt.UTC().Format(time.RFC3339)})
	}
	if c, ok := fromCache(", network unavailable"); ok {
		return c, nil
	}
	return nil, fmt.Errorf("fetching the price list failed and no cache or --catalog is available: %w", err)
}
