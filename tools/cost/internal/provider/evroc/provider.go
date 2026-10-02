// Package evroc estimates the cost of modules/evroc from a rate card derived
// from evroc's public calculator, since evroc provides no pricing API.
package evroc

import (
	"context"
	"fmt"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

type evroc struct{}

func init() { provider.Register(evroc{}) }

func (evroc) Name() string { return "evroc" }

// details holds the evroc-only variables that affect price.
type details struct {
	imageTargetDiskGB float64
	imageIDs          int // entries of image_ids; > 0 means no image build
}

// Resolve applies the locals.tf defaults and reads image_ids and
// image_target_disk_gb. Prices do not depend on the region, so a null region
// (the evroc CLI context, which this tool cannot read) only changes the label.
func (evroc) Resolve(c tfconfig.Common, v *tfconfig.Vars) (provider.Config, []tfconfig.Diagnostic) {
	var diags []tfconfig.Diagnostic
	if c.ControlPlaneInstanceType == "" {
		c.ControlPlaneInstanceType = defaults["control_plane_instance_type"]
	}
	if c.JumphostInstanceType == "" {
		c.JumphostInstanceType = defaults["jumphost_instance_type"]
	}
	if c.ControlPlaneDiskGB == nil {
		c.ControlPlaneDiskGB = defaultDisk("control_plane_disk_size_gb")
	}
	if c.JumphostDiskGB == nil {
		c.JumphostDiskGB = defaultDisk("jumphost_disk_size_gb")
	}
	if len(c.Zones) == 0 {
		c.Zones = defaultZones
	}
	d := details{imageTargetDiskGB: defaultImageTargetDiskGB}
	if v != nil {
		if g := v.OptFloat("image_target_disk_gb"); g != nil {
			d.imageTargetDiskGB = *g
		}
		d.imageIDs = len(v.MapKeys("image_ids"))
	}
	if c.Region == "" {
		c.Region = regionCLIContext
	}
	return provider.Config{Common: c, Details: d}, diags
}

func defaultDisk(name string) *float64 {
	var f float64
	_, _ = fmt.Sscan(defaults[name], &f)
	return &f
}

// Catalog returns the --catalog file when given, else the embedded rate
// card. The region does not change evroc prices; nothing is fetched.
func (evroc) Catalog(_ context.Context, _ string, o provider.CatalogOpts) (pricing.Catalog, error) {
	if o.File != "" {
		cat, err := LoadCatalogFile(o.File)
		if err != nil {
			return nil, fmt.Errorf("loading --catalog %s: %w", o.File, err)
		}
		return cat, nil
	}
	return EmbeddedCatalog()
}
