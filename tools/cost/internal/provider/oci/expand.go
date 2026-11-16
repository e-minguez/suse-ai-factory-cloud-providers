package oci

import (
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

// Expand mirrors the resources of modules/oci. Instances and boot volumes are
// separate rows; the network load balancer, reserved public IP and NAT gateway
// have no charge.
func (oci) Expand(cfg provider.Config) ([]pricing.Resource, []pricing.Excluded) {
	c := cfg.Common
	var res []pricing.Resource

	vm := func(label, role, pool, shape string, qty int, diskGB float64) {
		res = append(res, pricing.Resource{Kind: pricing.KindCompute, Label: label, Role: role, Pool: pool, RateID: shape, Qty: qty})
		res = append(res, pricing.Resource{Kind: pricing.KindStorage, Label: label + " disk", Role: role, Pool: pool, RateID: rateBoot, Qty: qty, SizeGB: diskGB})
	}
	nodeQty := func(n int) int {
		if c.DeployNodes {
			return n
		}
		return 0
	}

	// build.tf (jumphost_enabled): it builds the image and is the only SSH entry
	// to the private nodes, so it exists while building or while nodes exist.
	jumphost := 0
	if !c.ImageIDSet || c.DeployNodes {
		jumphost = 1
	}
	vm("jumphost", "jumphost", "", c.JumphostInstanceType, jumphost, *c.JumphostDiskGB)

	vm("control plane", "control_plane", "cp", c.ControlPlaneInstanceType, nodeQty(c.ControlPlaneCount), *c.ControlPlaneDiskGB)

	// Worker and GPU pools share one code path.
	for _, grp := range []struct {
		role  string
		pools []tfconfig.Pool
	}{{"gpu", c.GPUPools}, {"worker", c.WorkerPools}} {
		for _, p := range grp.pools {
			disk := agentDiskGB
			if p.DiskGB != nil {
				disk = *p.DiskGB
			}
			vm(grp.role+" node", grp.role, p.Name, p.InstanceType, nodeQty(p.Count), disk)
		}
	}

	// image.tf: the custom image is stored in Object Storage, billed on the
	// image size. keep_build_artifacts also leaves the qcow2 in the bucket.
	built := 1
	if c.ImageIDSet {
		built = 0
	}
	res = append(res, pricing.Resource{Kind: pricing.KindStorage, Label: "custom image", Role: "image", RateID: rateObject, Qty: built, SizeGB: c.ImageDiskGB})
	if c.KeepBuildArtifacts {
		res = append(res, pricing.Resource{Kind: pricing.KindStorage, Label: "build artifacts (qcow2 in bucket)", Role: "image", RateID: rateObject, Qty: built, SizeGB: c.ImageDiskGB, SurvivesDestroy: true})
	}

	res = append(res, pricing.Resource{Kind: pricing.KindFree, Label: "network load balancer, reserved public ip, nat gateway, vcn", Role: "network", Qty: 1})

	return res, []pricing.Excluded{
		{Label: "outbound traffic", Reason: "traffic-dependent; the first 10 TB per month are free"},
		{Label: "build bucket", Reason: "transient Object Storage use while the image is built; the qcow2 is deleted unless keep_build_artifacts"},
	}
}
