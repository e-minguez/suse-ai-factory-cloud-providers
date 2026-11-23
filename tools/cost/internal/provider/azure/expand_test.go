package azure

import (
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

func baseCommon() tfconfig.Common {
	return tfconfig.Common{ClusterName: "c", DeployNodes: true, ControlPlaneCount: 3, ImageDiskGB: 8}
}

func expand(t *testing.T, c tfconfig.Common) []pricing.Resource {
	t.Helper()
	cfg, diags := azure{}.Resolve(c, nil)
	if tfconfig.HasErrors(diags) {
		t.Fatalf("Resolve: %v", diags)
	}
	if cfg.Common.Region != "westeurope" && c.Region == "" {
		t.Errorf("region default not applied: %q", cfg.Common.Region)
	}
	res, excluded := azure{}.Expand(cfg)
	if len(excluded) == 0 || excluded[0].Label != "outbound traffic" {
		t.Errorf("excluded = %+v", excluded)
	}
	return res
}

func TestExpandExistingVPCSkipsNAT(t *testing.T) {
	cfg, _ := azure{}.Resolve(baseCommon(), nil)
	cfg.Details = details{existingVPC: true}
	res, _ := azure{}.Expand(cfg)
	m := byLabel(res)
	for _, k := range []string{"nat gateway|", "nat gateway public ip|"} {
		if m[k].Qty != 0 {
			t.Errorf("%s qty = %d, want 0 with vpc_id (the existing network provides egress)", k, m[k].Qty)
		}
	}
	if m["load balancer public ip|"].Qty != 1 {
		t.Error("the load balancer public ip must stay")
	}
}

func byLabel(res []pricing.Resource) map[string]pricing.Resource {
	out := map[string]pricing.Resource{}
	for _, r := range res {
		out[r.Label+"|"+r.Pool] = r
	}
	return out
}

func TestExpandDefaults(t *testing.T) {
	m := byLabel(expand(t, baseCommon()))
	want := map[string]int{
		"jumphost|": 1, "jumphost disk|": 1, "jumphost public ip|": 1,
		"control plane|cp": 3, "control plane disk|cp": 3,
		"load balancer (rules)|": 1, "load balancer public ip|": 1,
		"nat gateway|": 1, "nat gateway public ip|": 1,
	}
	for k, q := range want {
		if m[k].Qty != q {
			t.Errorf("%s: qty %d, want %d", k, m[k].Qty, q)
		}
	}
	if len(m) != len(want) {
		t.Errorf("rows = %d, want %d", len(m), len(want))
	}
	if m["jumphost|"].RateID != "Standard_D4s_v5" || m["control plane|cp"].RateID != "Standard_D8s_v5" {
		t.Errorf("locals.tf instance type defaults not applied: %+v", m)
	}
	// 100 GB rounds up to P10 (128 GiB).
	if d := m["jumphost disk|"]; d.RateID != "disk:P10" || d.SizeGB != 128 {
		t.Errorf("jumphost disk = %+v", d)
	}
	if d := m["control plane disk|cp"]; d.RateID != "disk:P10" || d.SizeGB != 128 {
		t.Errorf("control plane disk = %+v", d)
	}
}

func TestExpandVariants(t *testing.T) {
	disk := 500.0
	tests := []struct {
		name   string
		mutate func(*tfconfig.Common)
		check  func(*testing.T, map[string]pricing.Resource)
	}{
		{"pools", func(c *tfconfig.Common) {
			c.GPUPools = []tfconfig.Pool{{Name: "g", InstanceType: "Standard_NC24ads_A100_v4", Count: 2}}
			c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: "Standard_D16s_v5", Count: 3, DiskGB: &disk}}
		}, func(t *testing.T, m map[string]pricing.Resource) {
			if g := m["gpu node|g"]; g.Qty != 2 || g.RateID != "Standard_NC24ads_A100_v4" {
				t.Errorf("gpu = %+v", g)
			}
			// agent_disk_gb 200 -> P15 (256 GiB); 500 -> P20 (512 GiB).
			if g := m["gpu node disk|g"]; g.Qty != 2 || g.RateID != "disk:P15" || g.SizeGB != 256 {
				t.Errorf("gpu disk = %+v", g)
			}
			if w := m["worker node disk|w"]; w.Qty != 3 || w.RateID != "disk:P20" || w.SizeGB != 512 {
				t.Errorf("worker disk = %+v", w)
			}
		}},
		{"no nodes", func(c *tfconfig.Common) {
			c.DeployNodes = false
			c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: "Standard_D8s_v5", Count: 2}}
		}, func(t *testing.T, m map[string]pricing.Resource) {
			if m["control plane|cp"].Qty != 0 || m["worker node|w"].Qty != 0 || m["jumphost|"].Qty != 1 || m["load balancer (rules)|"].Qty != 1 {
				t.Errorf("deploy_nodes=false: %+v", m)
			}
		}},
		{"image_id no nodes", func(c *tfconfig.Common) { c.ImageIDSet = true; c.DeployNodes = false }, func(t *testing.T, m map[string]pricing.Resource) {
			if m["jumphost|"].Qty != 0 || m["jumphost public ip|"].Qty != 0 {
				t.Errorf("image_id without nodes: jumphost priced: %+v", m)
			}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := baseCommon()
			tt.mutate(&c)
			tt.check(t, byLabel(expand(t, c)))
		})
	}
}

func TestResolveDiskTooBig(t *testing.T) {
	c := baseCommon()
	big := 40000.0
	c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: "Standard_D8s_v5", Count: 1, DiskGB: &big}}
	_, diags := azure{}.Resolve(c, nil)
	if !tfconfig.HasErrors(diags) || !strings.Contains(diags[0].Summary, `pool "w"`) {
		t.Errorf("diags = %+v", diags)
	}
}

func TestNormRegion(t *testing.T) {
	if got := normRegion(" West Europe "); got != "westeurope" {
		t.Errorf("normRegion = %q", got)
	}
}
