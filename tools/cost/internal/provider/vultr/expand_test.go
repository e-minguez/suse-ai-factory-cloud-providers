package vultr

import (
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

func baseCommon() tfconfig.Common {
	return tfconfig.Common{
		Region: "ams", ClusterName: "c", DeployNodes: true, ControlPlaneCount: 3,
		IngressController: "traefik", ImageDiskGB: 8,
	}
}

func expand(t *testing.T, c tfconfig.Common) []pricing.Resource {
	t.Helper()
	cfg, diags := vultr{}.Resolve(c, nil)
	if tfconfig.HasErrors(diags) {
		t.Fatalf("Resolve: %v", diags)
	}
	res, excluded := vultr{}.Expand(cfg)
	if len(excluded) != 1 || excluded[0].Label != "bandwidth overage" {
		t.Errorf("excluded = %+v", excluded)
	}
	return res
}

func qtys(res []pricing.Resource) map[string]int {
	out := map[string]int{}
	for _, r := range res {
		out[r.Label+"|"+r.Pool] = r.Qty
	}
	return out
}

func TestExpandDefaults(t *testing.T) {
	res := expand(t, baseCommon())
	got := qtys(res)
	want := map[string]int{
		"jumphost|": 1, "control plane|cp": 3,
		"load balancer (api)|": 1, "load balancer (ingress)|": 1,
		"nat gateway|": 1, "image snapshot|": 1, "vpc, firewall groups and rules|": 1,
	}
	if diff := cmp.Diff(want, got); diff != "" {
		t.Errorf("quantities (-want +got):\n%s", diff)
	}
	if res[0].RateID != "vc2-6c-16gb" || res[1].RateID != "vx1-g-4c-16g-240s" {
		t.Errorf("locals.tf defaults not applied: %q, %q", res[0].RateID, res[1].RateID)
	}
	for _, r := range res {
		if r.SurvivesDestroy || r.BuildOnly {
			t.Errorf("%s: nothing survives destroy or is build-only on this provider", r.Label)
		}
	}
}

func TestExpandVariants(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*tfconfig.Common)
		want   map[string]int
	}{
		{"no nodes", func(c *tfconfig.Common) {
			c.DeployNodes = false
			c.GPUPools = []tfconfig.Pool{{Name: "g", InstanceType: "vbm-x", Count: 2, Kind: "bare_metal"}}
		},
			map[string]int{"control plane|cp": 0, "gpu node (bare metal)|g": 0, "jumphost|": 1}},
		{"no ingress controller", func(c *tfconfig.Common) { c.IngressController = "none" },
			map[string]int{"load balancer (ingress)|": 0, "load balancer (api)|": 1}},
		{"existing image", func(c *tfconfig.Common) { c.ImageIDSet = true },
			map[string]int{"image snapshot|": 0, "jumphost|": 1}},
		{"pools", func(c *tfconfig.Common) {
			c.GPUPools = []tfconfig.Pool{{Name: "g", InstanceType: "vbm-x", Count: 2, Kind: "bare_metal"}}
			c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: "vc2-x", Count: 4, Kind: "vm"}}
		}, map[string]int{"gpu node (bare metal)|g": 2, "worker node|w": 4}},
	}
	for _, tt := range tests {
		c := baseCommon()
		tt.mutate(&c)
		got := qtys(expand(t, c))
		for k, w := range tt.want {
			if got[k] != w {
				t.Errorf("%s: %s = %d, want %d", tt.name, k, got[k], w)
			}
		}
	}
}

func TestExpandRolesAndPools(t *testing.T) {
	c := baseCommon()
	c.GPUPools = []tfconfig.Pool{{Name: "g", InstanceType: "vbm-x", Count: 1}}
	res := expand(t, c)
	roles := map[string]string{}
	for _, r := range res {
		roles[r.Label] = r.Role
	}
	for label, role := range map[string]string{"jumphost": "jumphost", "control plane": "control_plane", "gpu node": "gpu", "load balancer (api)": "lb", "nat gateway": "network", "image snapshot": "image"} {
		if roles[label] != role {
			t.Errorf("%s role = %q, want %q", label, roles[label], role)
		}
	}
}

func TestResolveRequiresRegion(t *testing.T) {
	c := baseCommon()
	c.Region = ""
	if _, diags := (vultr{}).Resolve(c, nil); !tfconfig.HasErrors(diags) {
		t.Error("a missing region must be an error")
	}
}

var _ provider.Provider = vultr{}
