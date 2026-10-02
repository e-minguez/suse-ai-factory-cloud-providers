package aws

import (
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

func resolved(t *testing.T, c tfconfig.Common) (*awsProvider, provider.Config) {
	t.Helper()
	p := &awsProvider{}
	cfg, diags := p.Resolve(c, nil)
	if tfconfig.HasErrors(diags) {
		t.Fatalf("diags: %v", diags)
	}
	return p, cfg
}

func qtyOf(res []pricing.Resource, label string) (int, bool) {
	for _, r := range res {
		if r.Label == label {
			return r.Qty, true
		}
	}
	return 0, false
}

func TestResolveDefaultsAndRegion(t *testing.T) {
	_, diags := (&awsProvider{}).Resolve(tfconfig.Common{}, nil)
	if !tfconfig.HasErrors(diags) || diags[0].Summary == "" {
		t.Fatalf("empty region: want an error, got %v", diags)
	}

	f := 50.0
	_, cfg := resolved(t, tfconfig.Common{Region: "us-east-1", ControlPlaneDiskGB: &f, WorkerPools: []tfconfig.Pool{{Name: "cpu", InstanceType: "m7i.2xlarge", Count: 1}}})
	c := cfg.Common
	if c.ControlPlaneInstanceType != "m7i.xlarge" || c.JumphostInstanceType != "c6i.xlarge" || *c.JumphostDiskGB != 100 || *c.ControlPlaneDiskGB != 50 || *c.WorkerPools[0].DiskGB != 200 {
		t.Errorf("defaults wrong: %+v", c)
	}
}

func TestResolveRecordsInstanceTypes(t *testing.T) {
	p, _ := resolved(t, tfconfig.Common{Region: "us-east-1",
		GPUPools:    []tfconfig.Pool{{Name: "a10", InstanceType: "g5.2xlarge", Count: 1}},
		WorkerPools: []tfconfig.Pool{{Name: "cpu", InstanceType: "m7i.xlarge", Count: 2}}})
	want := []string{"c6i.xlarge", "g5.2xlarge", "m7i.xlarge"}
	got := p.neededTypes()
	if len(got) != len(want) {
		t.Fatalf("types = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("types = %v, want %v", got, want)
		}
	}
	p2, _ := resolved(t, tfconfig.Common{Region: "us-east-1", ImageIDSet: true})
	if got := p2.neededTypes(); len(got) != 1 || got[0] != "m7i.xlarge" {
		t.Errorf("image_id set: types = %v, want only the control plane type", got)
	}
}

func TestExpand(t *testing.T) {
	gpu := []tfconfig.Pool{{Name: "a10", InstanceType: "g5.2xlarge", Count: 2}}
	tests := []struct {
		name string
		c    tfconfig.Common
		want map[string]int // label -> qty
	}{
		{
			"defaults, three control planes",
			tfconfig.Common{Region: "us-east-1", DeployNodes: true, ControlPlaneCount: 3, ImageDiskGB: 8},
			map[string]int{
				"jumphost": 1, "public IPv4 (jumphost)": 1, "control plane": 3, "control plane root disk (gp3)": 3,
				"network load balancer (api, internal)": 1, "network load balancer (public)": 1,
				"public IPv4 (public NLB, one per zone)": 3, "nat gateway": 1, "public IPv4 (nat gateway)": 1, "image snapshot": 1,
			},
		},
		{
			"two zones, gpu pool",
			tfconfig.Common{Region: "us-east-1", Zones: []string{"a", "b"}, DeployNodes: true, ControlPlaneCount: 1, GPUPools: gpu, ImageDiskGB: 8},
			map[string]int{"public IPv4 (public NLB, one per zone)": 2, "gpu node": 2, "gpu node root disk (gp3)": 2},
		},
		{
			"image_id set drops jumphost and snapshot",
			tfconfig.Common{Region: "us-east-1", ImageIDSet: true, DeployNodes: true, ControlPlaneCount: 3, ImageDiskGB: 8},
			map[string]int{"jumphost": 0, "jumphost root disk (gp3)": 0, "public IPv4 (jumphost)": 0, "image snapshot": 0, "control plane": 3},
		},
		{
			"deploy_nodes false keeps infrastructure",
			tfconfig.Common{Region: "us-east-1", DeployNodes: false, ControlPlaneCount: 3, GPUPools: gpu, ImageDiskGB: 8},
			map[string]int{"control plane": 0, "gpu node": 0, "jumphost": 1, "nat gateway": 1, "network load balancer (public)": 1, "image snapshot": 1},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p, cfg := resolved(t, tt.c)
			res, excl := p.Expand(cfg)
			for label, q := range tt.want {
				if got, ok := qtyOf(res, label); !ok || got != q {
					t.Errorf("%q qty = %d (present=%v), want %d", label, got, ok, q)
				}
			}
			if len(excl) == 0 {
				t.Error("want excluded costs listed")
			}
			for _, r := range res {
				if r.BuildOnly || r.SurvivesDestroy {
					t.Errorf("%q: aws marks nothing build-only or surviving destroy", r.Label)
				}
			}
		})
	}
}

func TestExpandDiskSizes(t *testing.T) {
	d := 300.0
	p, cfg := resolved(t, tfconfig.Common{Region: "us-east-1", DeployNodes: true, ControlPlaneCount: 1, ImageDiskGB: 8,
		WorkerPools: []tfconfig.Pool{{Name: "cpu", InstanceType: "m7i.xlarge", Count: 1, DiskGB: &d}, {Name: "def", InstanceType: "m7i.xlarge", Count: 1}}})
	res, _ := p.Expand(cfg)
	sizes := map[string]float64{}
	for _, r := range res {
		if r.Kind == pricing.KindStorage {
			sizes[r.Label+"/"+r.Pool] = r.SizeGB
		}
	}
	for k, want := range map[string]float64{
		"control plane root disk (gp3)/cp": 100, "worker node root disk (gp3)/cpu": 300,
		"worker node root disk (gp3)/def": 200, "jumphost root disk (gp3)/": 100, "image snapshot/": 8,
	} {
		if sizes[k] != want {
			t.Errorf("%s = %v, want %v (all: %v)", k, sizes[k], want, sizes)
		}
	}
}
