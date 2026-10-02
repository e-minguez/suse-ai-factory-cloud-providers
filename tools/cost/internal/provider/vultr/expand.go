package vultr

import (
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

// Expand mirrors the resources of modules/vultr. Bare metal and cloud pools
// price the same way, by plan ID.
func (vultr) Expand(cfg provider.Config) ([]pricing.Resource, []pricing.Excluded) {
	c := cfg.Common
	var res []pricing.Resource

	// jumphost.tf: always one, even with image_id set, because it is also the
	// SSH entry host.
	res = append(res, pricing.Resource{Kind: pricing.KindCompute, Label: "jumphost", Role: "jumphost", RateID: c.JumphostInstanceType, Qty: 1})

	nodeQty := func(n int) int {
		if c.DeployNodes {
			return n
		}
		return 0
	}

	// control-plane.tf: count = deploy_nodes ? control_plane_count : 0.
	res = append(res, pricing.Resource{Kind: pricing.KindCompute, Label: "control plane", Role: "control_plane", Pool: "cp", RateID: c.ControlPlaneInstanceType, Qty: nodeQty(c.ControlPlaneCount)})

	for _, pools := range []struct {
		role  string
		pools []tfconfig.Pool
	}{{"gpu", c.GPUPools}, {"worker", c.WorkerPools}} {
		for _, p := range pools.pools {
			label := pools.role + " node"
			if p.Kind == "bare_metal" {
				label += " (bare metal)"
			}
			res = append(res, pricing.Resource{Kind: pricing.KindCompute, Label: label, Role: pools.role, Pool: p.Name, RateID: p.InstanceType, Qty: nodeQty(p.Count)})
		}
	}

	// loadbalancer.tf: the API load balancer always exists; the ingress one
	// only with the traefik ingress controller.
	res = append(res, pricing.Resource{Kind: pricing.KindFixed, Label: "load balancer (api)", Role: "lb", RateID: rateLB, Qty: lbNodes})
	ingress := 0
	if c.IngressController == "traefik" {
		ingress = lbNodes
	}
	res = append(res, pricing.Resource{Kind: pricing.KindFixed, Label: "load balancer (ingress)", Role: "lb", RateID: rateLB, Qty: ingress})

	// network.tf: one NAT gateway.
	res = append(res, pricing.Resource{Kind: pricing.KindFixed, Label: "nat gateway", Role: "network", RateID: rateNAT, Qty: 1})

	// image.tf: the snapshot is built only without image_id. It is a
	// Terraform resource, so destroy removes it. Billed at image_disk_size,
	// a ceiling: Vultr bills the imported snapshot's actual size.
	snapshots := 1
	if c.ImageIDSet {
		snapshots = 0
	}
	res = append(res, pricing.Resource{Kind: pricing.KindStorage, Label: "image snapshot", Role: "image", RateID: rateSnapshot, Qty: snapshots, SizeGB: c.ImageDiskGB})

	// The VPC, firewall groups and rules have no charge.
	res = append(res, pricing.Resource{Kind: pricing.KindFree, Label: "vpc, firewall groups and rules", Role: "network", Qty: 1})

	return res, []pricing.Excluded{{Label: "bandwidth overage", Reason: "traffic-dependent"}}
}
