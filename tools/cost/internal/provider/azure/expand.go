package azure

import (
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

// Expand mirrors the resources of modules/azure. VMs and OS disks are
// separate rows; a disk is billed as the Premium SSD tier that holds it.
func (azure) Expand(cfg provider.Config) ([]pricing.Resource, []pricing.Excluded) {
	c := cfg.Common
	det, _ := cfg.Details.(details)
	var res []pricing.Resource

	vm := func(label, role, pool, size string, qty int, diskGB float64) {
		res = append(res, pricing.Resource{Kind: pricing.KindCompute, Label: label, Role: role, Pool: pool, RateID: size, Qty: qty})
		tier, ok := tierFor(diskGB)
		if !ok {
			tier = diskTiers[len(diskTiers)-1] // Resolve reports it
		}
		res = append(res, pricing.Resource{Kind: pricing.KindStorage, Label: label + " disk", Role: role, Pool: pool, RateID: diskPfx + tier.Name, Qty: qty, SizeGB: tier.GiB})
	}
	nodeQty := func(n int) int {
		if c.DeployNodes {
			return n
		}
		return 0
	}

	// The jumphost builds the image and is the only SSH entry to the private
	// nodes, so it exists while building or while nodes exist.
	jumphost := 0
	if !c.ImageIDSet || c.DeployNodes {
		jumphost = 1
	}
	vm("jumphost", "jumphost", "", c.JumphostInstanceType, jumphost, *c.JumphostDiskGB)
	res = append(res, pricing.Resource{Kind: pricing.KindFixed, Label: "jumphost public ip", Role: "jumphost", RateID: rateIP, Qty: jumphost})

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

	// The load balancer and its public IP exist before the image (the address
	// is in the image); the NAT gateway serves the private subnet, none with
	// vpc_id (the existing network provides egress).
	nat := 1
	if det.existingVPC {
		nat = 0
	}
	res = append(res,
		pricing.Resource{Kind: pricing.KindFixed, Label: "load balancer (rules)", Role: "network", RateID: rateLB, Qty: 1},
		pricing.Resource{Kind: pricing.KindFixed, Label: "load balancer public ip", Role: "network", RateID: rateIP, Qty: 1},
		pricing.Resource{Kind: pricing.KindFixed, Label: "nat gateway", Role: "network", RateID: rateNAT, Qty: nat},
		pricing.Resource{Kind: pricing.KindFixed, Label: "nat gateway public ip", Role: "network", RateID: rateIP, Qty: nat},
	)

	return res, []pricing.Excluded{
		{Label: "outbound traffic", Reason: "traffic-dependent; the first 100 GB per month are free"},
		{Label: "load balancer and NAT gateway data processed", Reason: "traffic-dependent; per GB"},
		{Label: "jumphost SLES licence", Reason: "marketplace pay-as-you-go image; billed per hour by vCPU tier as a separate meter"},
		{Label: "image storage", Reason: "page blob in the storage account and the compute gallery image version; small, and the blob is deleted unless keep_build_artifacts"},
	}
}
