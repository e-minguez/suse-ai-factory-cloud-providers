// Package aws estimates the cost of modules/aws from the AWS Price List API.
package aws

import (
	"fmt"
	"sort"
	"strconv"
	"sync"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

// details is Config.Details for aws.
type details struct {
	zones int // number of Availability Zones the module spans
}

// awsProvider implements provider.Provider. Catalog is called after Resolve
// and learns from it which instance types to fetch, so only those prices are
// requested.
type awsProvider struct {
	api productsAPI // nil: the default credential chain, built on demand

	mu    sync.Mutex
	types []string // instance types the resolved configuration uses
}

func init() { provider.Register(&awsProvider{}) }

func (*awsProvider) Name() string { return "aws" }

// Resolve applies the locals.tf defaults and records the instance types the
// catalog must price.
func (p *awsProvider) Resolve(c tfconfig.Common, _ *tfconfig.Vars) (provider.Config, []tfconfig.Diagnostic) {
	var diags []tfconfig.Diagnostic
	if c.Region == "" {
		diags = append(diags, tfconfig.Diagnostic{Severity: tfconfig.SeverityError, Summary: `variable "region" has no default and no value was found in the tfvars; pass --region`})
	}
	if c.ControlPlaneInstanceType == "" {
		c.ControlPlaneInstanceType = defaults["control_plane_instance_type"]
	}
	if c.JumphostInstanceType == "" {
		c.JumphostInstanceType = defaults["jumphost_instance_type"]
	}
	c.ControlPlaneDiskGB = orDefault(c.ControlPlaneDiskGB, defaults["control_plane_disk_size_gb"])
	c.JumphostDiskGB = orDefault(c.JumphostDiskGB, defaults["jumphost_disk_size_gb"])
	c.GPUPools = withDisk(c.GPUPools)
	c.WorkerPools = withDisk(c.WorkerPools)

	zones := defaultZones
	if len(c.Zones) > 0 {
		zones = len(c.Zones)
	}

	set := map[string]bool{c.ControlPlaneInstanceType: true}
	if !c.ImageIDSet {
		set[c.JumphostInstanceType] = true
	}
	for _, pools := range [][]tfconfig.Pool{c.GPUPools, c.WorkerPools} {
		for _, pl := range pools {
			set[pl.InstanceType] = true
		}
	}
	types := make([]string, 0, len(set))
	for t := range set {
		types = append(types, t)
	}
	sort.Strings(types)
	p.mu.Lock()
	p.types = types
	p.mu.Unlock()

	return provider.Config{Common: c, Details: details{zones: zones}}, diags
}

func orDefault(v *float64, def string) *float64 {
	if v != nil {
		return v
	}
	f, err := strconv.ParseFloat(def, 64)
	if err != nil {
		panic(fmt.Sprintf("aws defaults: %q is not a number", def))
	}
	return &f
}

func withDisk(pools []tfconfig.Pool) []tfconfig.Pool {
	out := make([]tfconfig.Pool, len(pools))
	copy(out, pools)
	for i := range out {
		if out[i].DiskGB == nil {
			d := float64(poolDiskGB)
			out[i].DiskGB = &d
		}
	}
	return out
}

func (p *awsProvider) neededTypes() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.types...)
}
