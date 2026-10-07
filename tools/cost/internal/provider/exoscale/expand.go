package exoscale

import (
	"math"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

// Expand mirrors the resources of modules/exoscale. Instance prices exclude
// the local disk, which is a separate per GiB-hour row; the public IPv4 of
// every instance is included.
func (exoscale) Expand(cfg provider.Config) ([]pricing.Resource, []pricing.Excluded) {
	c := cfg.Common
	var res []pricing.Resource

	vm := func(label, role, pool, instanceType string, qty int, diskGB float64) {
		res = append(res, pricing.Resource{Kind: pricing.KindCompute, Label: label, Role: role, Pool: pool, RateID: instanceType, Qty: qty})
		res = append(res, pricing.Resource{Kind: pricing.KindStorage, Label: label + " disk", Role: role, Pool: pool, RateID: diskRate(instanceType), Qty: qty, SizeGB: diskGB})
	}
	nodeQty := func(n int) int {
		if c.DeployNodes {
			return n
		}
		return 0
	}

	// build.tf: always one jumphost; it builds the image and stays as the
	// SSH entry host.
	vm("jumphost", "jumphost", "", c.JumphostInstanceType, 1, *c.JumphostDiskGB)

	// control-plane.tf: one instance pool, size control_plane_count once
	// bootstrapped (size 1 only during the first deploy pass).
	vm("control plane", "control_plane", "cp", c.ControlPlaneInstanceType, nodeQty(c.ControlPlaneCount), *c.ControlPlaneDiskGB)

	// agent-nodes.tf: worker and GPU pools share one code path.
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

	// loadbalancer.tf: one NLB carries the API and the ingress services.
	res = append(res, pricing.Resource{Kind: pricing.KindFixed, Label: "network load balancer", Role: "lb", RateID: rateLB, Qty: 1})

	// image.tf: the template is registered only without image_id, in the one
	// zone. Billed on its virtual size, at least templateMinGiB.
	templates := 1
	if c.ImageIDSet {
		templates = 0
	}
	res = append(res, pricing.Resource{Kind: pricing.KindStorage, Label: "image template", Role: "image", RateID: rateTemplate, Qty: templates, SizeGB: math.Max(c.ImageDiskGB, templateMinGiB)})

	res = append(res, pricing.Resource{Kind: pricing.KindFree, Label: "public ipv4, private network, security groups", Role: "network", Qty: 1})

	return res, []pricing.Excluded{{Label: "outbound traffic", Reason: "traffic-dependent, billed per GB"}}
}
