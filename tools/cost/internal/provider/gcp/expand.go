package gcp

import (
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

// Forwarding rules covered by one minimum service charge, and the VM count
// one Cloud NAT gateway charge is capped at.
const (
	rulesInMinCharge = 5
	natVMCap         = 32
)

// Expand mirrors the resources of modules/gcp. Instances and boot disks are
// separate rows; every external IPv4 in use is one row.
func (gcp) Expand(cfg provider.Config) ([]pricing.Resource, []pricing.Excluded) {
	c := cfg.Common
	d, _ := cfg.Details.(details)
	var res []pricing.Resource
	natVMs := 0

	diskType := func(machineType string, override string) string {
		if override != "" {
			return override
		}
		return defaultDiskType(machineType)
	}
	vm := func(label, role, pool, machineType, disk string, qty int, diskGB float64, publicIP bool) {
		res = append(res,
			pricing.Resource{Kind: pricing.KindCompute, Label: label, Role: role, Pool: pool, RateID: machineType, Qty: qty},
			pricing.Resource{Kind: pricing.KindStorage, Label: label + " disk", Role: role, Pool: pool, RateID: diskPrefix + disk, Qty: qty, SizeGB: diskGB})
		if publicIP {
			res = append(res, pricing.Resource{Kind: pricing.KindFixed, Label: "external IPv4 (" + label + ")", Role: role, Pool: pool, RateID: rateIP, Qty: qty})
		} else {
			natVMs += qty
		}
	}
	nodeQty := func(n int) int {
		if c.DeployNodes {
			return n
		}
		return 0
	}

	// build.tf: the jumphost builds the image and is the only SSH entry to the
	// nodes; it has an ephemeral external address, always the family disk.
	jumphost := 0
	if !c.ImageIDSet || c.DeployNodes {
		jumphost = 1
	}
	vm("jumphost", "jumphost", "", c.JumphostInstanceType, diskType(c.JumphostInstanceType, ""), jumphost, *c.JumphostDiskGB, true)

	vm("control plane", "control_plane", "cp", c.ControlPlaneInstanceType, diskType(c.ControlPlaneInstanceType, d.bootDiskType),
		nodeQty(c.ControlPlaneCount), *c.ControlPlaneDiskGB, c.ControlPlanePublicIP)

	for _, grp := range []struct {
		role  string
		pools []tfconfig.Pool
	}{{"gpu", c.GPUPools}, {"worker", c.WorkerPools}} {
		for _, p := range grp.pools {
			disk := agentDiskGB
			if p.DiskGB != nil {
				disk = *p.DiskGB
			}
			vm(grp.role+" node", grp.role, p.Name, p.InstanceType, diskType(p.InstanceType, d.bootDiskType), nodeQty(p.Count), disk, p.PublicIP)
		}
	}

	// build.tf, image.tf: a blank target disk, then a snapshot and an image of
	// it. Snapshot and image are priced at the disk size, an upper bound: they
	// store compressed data.
	built := 1
	if c.ImageIDSet {
		built = 0
	}
	res = append(res,
		pricing.Resource{Kind: pricing.KindStorage, Label: "image target disk", Role: "image", RateID: diskPrefix + "pd-balanced", Qty: built, SizeGB: c.ImageDiskGB},
		pricing.Resource{Kind: pricing.KindStorage, Label: "image snapshot (upper bound)", Role: "image", RateID: rateSnapshot, Qty: built, SizeGB: c.ImageDiskGB},
		pricing.Resource{Kind: pricing.KindStorage, Label: "image (upper bound)", Role: "image", RateID: rateImage, Qty: built, SizeGB: c.ImageDiskGB},
	)

	// loadbalancer.tf: external rules 6443 plus 80 and 443 with an ingress
	// controller; internal rules 6443 and 9345. One minimum charge covers the
	// first five rules.
	rules := 1 + 2
	if c.IngressController != "none" {
		rules += 2
	}
	extra := max(rules-rulesInMinCharge, 0)
	res = append(res,
		pricing.Resource{Kind: pricing.KindFixed, Label: "forwarding rules (minimum charge, first 5)", Role: "lb", RateID: rateLBMin, Qty: 1},
		pricing.Resource{Kind: pricing.KindFixed, Label: "forwarding rules (additional)", Role: "lb", RateID: rateLBExtra, Qty: extra},
		pricing.Resource{Kind: pricing.KindFixed, Label: "external IPv4 (load balancer)", Role: "lb", RateID: rateIP, Qty: 1},
	)

	// network.tf: Cloud NAT is charged per VM that uses it up to a cap, plus
	// the in-use external address of the gateway. With vpc_id the module
	// creates neither: the existing NAT is not its cost.
	if d.existingNet {
		res = append(res, pricing.Resource{Kind: pricing.KindFree, Label: "firewall rules, health checks, internal address", Role: "network", Qty: 1})
	} else {
		res = append(res,
			pricing.Resource{Kind: pricing.KindFixed, Label: "cloud nat gateway (per VM, max 32)", Role: "network", RateID: rateNATVM, Qty: min(natVMs, natVMCap)},
			pricing.Resource{Kind: pricing.KindFixed, Label: "external IPv4 (cloud nat)", Role: "network", RateID: rateIP, Qty: 1},
			pricing.Resource{Kind: pricing.KindFree, Label: "vpc, subnet, firewall rules, router, health checks, internal address", Role: "network", Qty: 1},
		)
	}

	return res, []pricing.Excluded{
		{Label: "outbound traffic", Reason: "traffic-dependent; internet egress is billed per GiB"},
		{Label: "load balancer and NAT data processing", Reason: "traffic-dependent, billed per GiB"},
		{Label: "hyperdisk IOPS and throughput", Reason: "disks are priced per GB only; provisioned performance above the baseline is not estimated"},
	}
}
