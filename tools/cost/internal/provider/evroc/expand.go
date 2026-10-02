package evroc

import (
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

const noRate = "evroc does not publish this rate and provides no pricing API"

// Expand mirrors the resources of modules/evroc. Every VM has a boot disk
// sized by its pool; public IPs are separate billable objects.
func (evroc) Expand(cfg provider.Config) ([]pricing.Resource, []pricing.Excluded) {
	c := cfg.Common
	d, _ := cfg.Details.(details)
	zones := len(c.Zones)
	var res []pricing.Resource

	vm := func(label, role, pool, flavor string, qty int, disk *float64, buildOnly bool) {
		res = append(res, pricing.Resource{Kind: pricing.KindCompute, Label: label, Role: role, Pool: pool, RateID: flavor, Qty: qty, BuildOnly: buildOnly})
		res = append(res, pricing.Resource{Kind: pricing.KindStorage, Label: label + " disk", Role: role, Pool: pool, RateID: rateDisk, Qty: qty, SizeGB: *disk, BuildOnly: buildOnly})
	}
	ip := func(label, role, pool string, qty int) {
		res = append(res, pricing.Resource{Kind: pricing.KindFixed, Label: label, Role: role, Pool: pool, RateID: ratePublicIP, Qty: qty})
	}
	nodeQty := func(n int) int {
		if c.DeployNodes {
			return n
		}
		return 0
	}

	// build.tf: the jumphost (zones[0]) is always created, with its own
	// public IP; it stays as the bastion.
	vm("jumphost", "jumphost", "", c.JumphostInstanceType, 1, c.JumphostDiskGB, false)
	ip("public ip (jumphost)", "jumphost", "", 1)

	// network.tf: the cluster public IP fronts the load balancer.
	ip("public ip (api, ingress)", "lb", "", 1)

	// control-plane.tf: one VM, disk and optional public IP per node.
	cp := nodeQty(c.ControlPlaneCount)
	vm("control plane", "control_plane", "cp", c.ControlPlaneInstanceType, cp, c.ControlPlaneDiskGB, false)
	pubCP := 0
	if c.ControlPlanePublicIP {
		pubCP = cp
	}
	ip("public ip (control plane)", "control_plane", "cp", pubCP)

	// agent-nodes.tf: worker and GPU pools share one code path; the disk
	// defaults to the control-plane disk size.
	for _, grp := range []struct {
		role  string
		pools []tfconfig.Pool
	}{{"gpu", c.GPUPools}, {"worker", c.WorkerPools}} {
		for _, p := range grp.pools {
			disk := c.ControlPlaneDiskGB
			if p.DiskGB != nil {
				disk = p.DiskGB
			}
			n := nodeQty(p.Count)
			vm(grp.role+" node", grp.role, p.Name, p.InstanceType, n, disk, false)
			pub := 0
			if p.PublicIP {
				pub = n
			}
			ip("public ip ("+grp.role+" node)", grp.role, p.Name, pub)
		}
	}

	// build.tf: with image_ids nothing is built. Otherwise builders (every
	// zone but the first) exist only until the second pass, and the
	// per-zone target disks only until the third, unless
	// keep_build_artifacts keeps them.
	build := 1
	if d.imageIDs > 0 || c.ImageIDSet {
		build = 0
	}
	builders := build * (zones - 1)
	vm("image builder", "builder", "", c.JumphostInstanceType, builders, c.JumphostDiskGB, true)
	res = append(res, pricing.Resource{Kind: pricing.KindStorage, Label: "image target disk", Role: "image", RateID: rateDisk, Qty: build * zones, SizeGB: d.imageTargetDiskGB, BuildOnly: !c.KeepBuildArtifacts})

	// The VPC, subnets, security groups and placement groups have no charge.
	res = append(res, pricing.Resource{Kind: pricing.KindFree, Label: "vpc, subnets, security and placement groups", Role: "network", Qty: 1})

	excluded := []pricing.Excluded{
		{Label: "load balancer", Reason: noRate},
		{Label: "outbound transfer", Reason: "traffic-dependent; the first 100 GB are free, then billed per GB"},
	}
	if build > 0 {
		excluded = append(excluded, pricing.Excluded{Label: "image snapshots (one per zone)", Reason: noRate})
	}
	return res, excluded
}
