// Package gcp estimates the cost of modules/gcp from the Cloud Billing
// Catalog API (Compute Engine and Networking services).
package gcp

import (
	"context"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

type gcp struct{}

func init() { provider.Register(gcp{}) }

func (gcp) Name() string { return "gcp" }

// details is Config.Details for gcp.
type details struct {
	bootDiskType string // boot_disk_type; "" = the family default
}

// Mirrors machine_type_format and fractional_g4 in modules/gcp/locals.tf.
var (
	machineTypeFormat = regexp.MustCompile(`^[a-z][a-z0-9]*-[a-z0-9-]+$`)
	fractionalG4      = regexp.MustCompile(`^g4-standard-(6|12|24)$`)
)

// Resolve applies the locals.tf defaults, reads boot_disk_type and checks the
// machine type syntax like the module's input checks do.
func (gcp) Resolve(c tfconfig.Common, v *tfconfig.Vars) (provider.Config, []tfconfig.Diagnostic) {
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

	d := details{}
	if v != nil {
		d.bootDiskType = v.String("boot_disk_type")
	}

	var diags []tfconfig.Diagnostic
	check := func(who, s string) {
		var msg string
		switch {
		case !machineTypeFormat.MatchString(s):
			msg = `expected a machine type such as "n2-standard-4" or "g2-standard-4"`
		case fractionalG4.MatchString(s):
			msg = "fractional G4 sizes are not supported: use g4-standard-48 or larger"
		}
		if msg != "" {
			diags = append(diags, tfconfig.Diagnostic{Severity: tfconfig.SeverityError, Summary: fmt.Sprintf("%s = %q: %s", who, s, msg)})
		}
	}
	check("jumphost_instance_type", c.JumphostInstanceType)
	check("control_plane_instance_type", c.ControlPlaneInstanceType)
	for _, p := range c.GPUPools {
		check(fmt.Sprintf("gpu_pools[%q].instance_type", p.Name), p.InstanceType)
	}
	for _, p := range c.WorkerPools {
		check(fmt.Sprintf("worker_pools[%q].instance_type", p.Name), p.InstanceType)
	}
	return provider.Config{Common: c, Details: d}, diags
}

func defaultFloat(name string) *float64 {
	f, _ := strconv.ParseFloat(defaults[name], 64)
	return &f
}

// Catalog resolves rates in this order: the --catalog file; with --no-network
// the warm cache; otherwise the Billing Catalog API (saving the cache),
// falling back to the cache when the key is missing or the API unreachable.
// Rates are those of region.
func (gcp) Catalog(ctx context.Context, region string, o provider.CatalogOpts) (pricing.Catalog, error) {
	if region == "" {
		region = defaults["region"]
	}
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

	key, err := APIKey()
	if err != nil {
		if c, ok := fromCache(", no API key"); ok {
			return c, nil
		}
		return nil, err
	}
	fetchedAt := time.Now()
	pl, err := FetchLive(ctx, http.DefaultClient, key, region, 120*time.Second)
	if err == nil {
		if cache != "" {
			_ = SaveCache(cache, pl, fetchedAt) // best effort
		}
		return pl.ToCatalog(region, pricing.CatalogInfo{Source: "api", AsOf: fetchedAt.UTC().Format(time.RFC3339)})
	}
	if c, ok := fromCache(", network unavailable"); ok {
		return c, nil
	}
	return nil, fmt.Errorf("fetching the catalog failed and no cache or --catalog is available: %w", err)
}
