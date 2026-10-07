package exoscale

import (
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

func catalogOpts(file string, noNetwork bool, cacheDir string) provider.CatalogOpts {
	return provider.CatalogOpts{File: file, NoNetwork: noNetwork, CacheDir: cacheDir}
}

func baseCommon() tfconfig.Common {
	return tfconfig.Common{ClusterName: "c", DeployNodes: true, ControlPlaneCount: 3, ImageDiskGB: 8}
}

func expand(t *testing.T, c tfconfig.Common) []pricing.Resource {
	t.Helper()
	cfg, diags := exoscale{}.Resolve(c, nil)
	if tfconfig.HasErrors(diags) {
		t.Fatalf("Resolve: %v", diags)
	}
	if cfg.Common.Region != "de-fra-1" && c.Region == "" {
		t.Errorf("region default not applied: %q", cfg.Common.Region)
	}
	res, excluded := exoscale{}.Expand(cfg)
	if len(excluded) != 1 || excluded[0].Label != "outbound traffic" {
		t.Errorf("excluded = %+v", excluded)
	}
	return res
}

func byLabel(res []pricing.Resource) map[string]pricing.Resource {
	out := map[string]pricing.Resource{}
	for _, r := range res {
		out[r.Label+"|"+r.Pool] = r
	}
	return out
}

func qtys(res []pricing.Resource) map[string]int {
	out := map[string]int{}
	for k, r := range byLabel(res) {
		out[k] = r.Qty
	}
	return out
}

func TestExpandDefaults(t *testing.T) {
	res := expand(t, baseCommon())
	want := map[string]int{
		"jumphost|": 1, "jumphost disk|": 1, "control plane|cp": 3, "control plane disk|cp": 3,
		"network load balancer|": 1, "image template|": 1,
		"public ipv4, private network, security groups|": 1,
	}
	if diff := cmp.Diff(want, qtys(res)); diff != "" {
		t.Errorf("quantities (-want +got):\n%s", diff)
	}
	m := byLabel(res)
	if m["jumphost|"].RateID != "standard.large" || m["control plane|cp"].RateID != "standard.extra-large" {
		t.Errorf("locals.tf instance type defaults not applied: %+v", m)
	}
	if m["jumphost disk|"].SizeGB != 50 || m["control plane disk|cp"].SizeGB != 100 {
		t.Errorf("locals.tf disk defaults not applied: %+v", m)
	}
	// image_disk_size 8G is grown to the 10 GiB template minimum.
	if m["image template|"].SizeGB != 10 || m["image template|"].RateID != rateTemplate {
		t.Errorf("template = %+v", m["image template|"])
	}
	for _, r := range res {
		if r.SurvivesDestroy || r.BuildOnly {
			t.Errorf("%s: nothing survives destroy or is build-only on this provider", r.Label)
		}
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
			c.GPUPools = []tfconfig.Pool{{Name: "g", InstanceType: "gpu3.small", Count: 2}}
			c.WorkerPools = []tfconfig.Pool{{Name: "s", InstanceType: "storage.huge", Count: 3, DiskGB: &disk}}
		}, func(t *testing.T, m map[string]pricing.Resource) {
			if g := m["gpu node disk|g"]; g.Qty != 2 || g.SizeGB != agentDiskGB || g.RateID != rateDisk {
				t.Errorf("gpu disk = %+v", g)
			}
			if s := m["worker node disk|s"]; s.Qty != 3 || s.SizeGB != 500 || s.RateID != rateDiskStorage {
				t.Errorf("storage optimized disk = %+v", s)
			}
		}},
		{"no nodes", func(c *tfconfig.Common) {
			c.DeployNodes = false
			c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: "standard.large", Count: 2}}
		}, func(t *testing.T, m map[string]pricing.Resource) {
			if m["control plane|cp"].Qty != 0 || m["worker node|w"].Qty != 0 || m["jumphost|"].Qty != 1 || m["network load balancer|"].Qty != 1 {
				t.Errorf("deploy_nodes=false: %+v", m)
			}
		}},
		{"image_id", func(c *tfconfig.Common) { c.ImageIDSet = true }, func(t *testing.T, m map[string]pricing.Resource) {
			if m["image template|"].Qty != 0 {
				t.Errorf("image_id set but the template is priced: %+v", m["image template|"])
			}
		}},
		{"large image", func(c *tfconfig.Common) { c.ImageDiskGB = 32 }, func(t *testing.T, m map[string]pricing.Resource) {
			if m["image template|"].SizeGB != 32 {
				t.Errorf("template size = %v, want the image size above the minimum", m["image template|"].SizeGB)
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
