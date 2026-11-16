// Package oci estimates the cost of modules/oci from Oracle's public price
// list.
package oci

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

type oci struct{}

func init() { provider.Register(oci{}) }

func (oci) Name() string { return "oci" }

// shapeFormat mirrors `shape_format` in modules/oci/locals.tf.
var shapeFormat = regexp.MustCompile(`^([A-Za-z0-9.]+)(?::([1-9][0-9]*)x([1-9][0-9]*))?$`)

// Resolve applies the locals.tf defaults and checks the instance type syntax
// like terraform_data.input_checks does. Prices have no region dimension.
func (oci) Resolve(c tfconfig.Common, _ *tfconfig.Vars) (provider.Config, []tfconfig.Diagnostic) {
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

	var diags []tfconfig.Diagnostic
	check := func(who, s string) {
		if msg := checkShape(s); msg != "" {
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
	return provider.Config{Common: c}, diags
}

// checkShape returns "" for a well-formed instance type, else the problem.
func checkShape(s string) string {
	m := shapeFormat.FindStringSubmatch(s)
	if m == nil {
		return `expected "<shape>" or "<shape>:<ocpus>x<memory_gb>"`
	}
	flex, sized := isFlex(m[1]), m[2] != ""
	switch {
	case flex && !sized:
		return fmt.Sprintf(`a flex shape needs a size, for example "%s:2x16"`, s)
	case !flex && sized:
		return "only flex shapes take an <ocpus>x<memory_gb> size"
	}
	return ""
}

func defaultFloat(name string) *float64 {
	f, _ := strconv.ParseFloat(defaults[name], 64)
	return &f
}

// Catalog resolves rates in this order: the --catalog file; with --no-network
// the warm cache; otherwise the public price list (saving the cache), falling
// back to the cache when it is unreachable.
func (oci) Catalog(ctx context.Context, _ string, o provider.CatalogOpts) (pricing.Catalog, error) {
	if o.File != "" {
		pl, err := LoadPriceListFile(o.File)
		if err != nil {
			return nil, fmt.Errorf("loading --catalog %s: %w", o.File, err)
		}
		return pl.ToCatalog(pricing.CatalogInfo{Source: "file", AsOf: pl.LastUpdated})
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
	pl, err := FetchLive(ctx, http.DefaultClient, 30*time.Second)
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
