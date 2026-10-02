package aws

import (
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

// Rate IDs of everything that is not an instance type.
const (
	rateLB       = "lb"
	rateNAT      = "nat-gateway"
	ratePublicIP = "public-ipv4"
	rateSnapshot = "storage:snapshot"
	rateDisk     = "storage:disk"
)

// Expand mirrors the resources of modules/aws.
func (*awsProvider) Expand(cfg provider.Config) ([]pricing.Resource, []pricing.Excluded) {
	c := cfg.Common
	zones := cfg.Details.(details).zones
	var res []pricing.Resource

	nodeQty := func(n int) int {
		if c.DeployNodes {
			return n
		}
		return 0
	}
	node := func(label, role, pool, instanceType string, disk float64, qty int) {
		res = append(res,
			pricing.Resource{Kind: pricing.KindCompute, Label: label, Role: role, Pool: pool, RateID: instanceType, Qty: qty},
			pricing.Resource{Kind: pricing.KindStorage, Label: label + " root disk (gp3)", Role: role, Pool: pool, RateID: rateDisk, Qty: qty, SizeGB: disk},
		)
	}

	// build.tf: the jumphost exists whenever the image is built (no image_id)
	// and stays as the SSH entry host. It has a public IPv4 address.
	jump := 1
	if c.ImageIDSet {
		jump = 0
	}
	node("jumphost", "jumphost", "", c.JumphostInstanceType, *c.JumphostDiskGB, jump)
	res = append(res, pricing.Resource{Kind: pricing.KindFixed, Label: "public IPv4 (jumphost)", Role: "jumphost", RateID: ratePublicIP, Qty: jump})

	// control-plane.tf, agent-nodes.tf: private subnets, no public IPs.
	node("control plane", "control_plane", "cp", c.ControlPlaneInstanceType, *c.ControlPlaneDiskGB, nodeQty(c.ControlPlaneCount))
	for _, pools := range []struct {
		role  string
		pools []tfconfig.Pool
	}{{"gpu", c.GPUPools}, {"worker", c.WorkerPools}} {
		for _, p := range pools.pools {
			node(pools.role+" node", pools.role, p.Name, p.InstanceType, *p.DiskGB, nodeQty(p.Count))
		}
	}

	// loadbalancer.tf: an internal NLB for the API and an internet-facing
	// one. The internet-facing NLB takes one public IPv4 per zone.
	res = append(res,
		pricing.Resource{Kind: pricing.KindFixed, Label: "network load balancer (api, internal)", Role: "lb", RateID: rateLB, Qty: 1},
		pricing.Resource{Kind: pricing.KindFixed, Label: "network load balancer (public)", Role: "lb", RateID: rateLB, Qty: 1},
		pricing.Resource{Kind: pricing.KindFixed, Label: "public IPv4 (public NLB, one per zone)", Role: "lb", RateID: ratePublicIP, Qty: zones},
	)

	// network.tf: one NAT gateway with one Elastic IP for every private subnet.
	res = append(res,
		pricing.Resource{Kind: pricing.KindFixed, Label: "nat gateway", Role: "network", RateID: rateNAT, Qty: 1},
		pricing.Resource{Kind: pricing.KindFixed, Label: "public IPv4 (nat gateway)", Role: "network", RateID: ratePublicIP, Qty: 1},
	)

	// image.tf: the imported EBS snapshot, removed by destroy. The AMI has no
	// charge of its own.
	snapshots := 1
	if c.ImageIDSet {
		snapshots = 0
	}
	res = append(res, pricing.Resource{Kind: pricing.KindStorage, Label: "image snapshot", Role: "image", RateID: rateSnapshot, Qty: snapshots, SizeGB: c.ImageDiskGB})

	// VPC, subnets, route tables, internet gateway, S3 gateway endpoint,
	// security groups and IAM have no charge.
	res = append(res, pricing.Resource{Kind: pricing.KindFree, Label: "vpc, subnets, routes, security groups, iam, s3 endpoint", Role: "network", Qty: 1})

	return res, []pricing.Excluded{
		{Label: "data transfer", Reason: "traffic-dependent"},
		{Label: "network load balancer capacity units (LCU)", Reason: "traffic-dependent"},
		{Label: "nat gateway data processing", Reason: "per-GB, traffic-dependent"},
		{Label: "raw image in S3", Reason: "stored for one day (until destroy with keep_build_artifacts); storage and requests are small and not estimated"},
	}
}
