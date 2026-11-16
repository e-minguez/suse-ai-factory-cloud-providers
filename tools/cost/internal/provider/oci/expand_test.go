package oci

import (
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

func baseCommon() tfconfig.Common {
	return tfconfig.Common{ClusterName: "c", DeployNodes: true, ControlPlaneCount: 3, ImageDiskGB: 8}
}

func expand(t *testing.T, c tfconfig.Common) []pricing.Resource {
	t.Helper()
	cfg, diags := oci{}.Resolve(c, nil)
	if tfconfig.HasErrors(diags) {
		t.Fatalf("Resolve: %v", diags)
	}
	if cfg.Common.Region != "eu-frankfurt-1" && c.Region == "" {
		t.Errorf("region default not applied: %q", cfg.Common.Region)
	}
	res, excluded := oci{}.Expand(cfg)
	if len(excluded) != 2 || excluded[0].Label != "outbound traffic" {
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

func TestExpandDefaults(t *testing.T) {
	res := expand(t, baseCommon())
	want := map[string]int{
		"jumphost|": 1, "jumphost disk|": 1, "control plane|cp": 3, "control plane disk|cp": 3,
		"custom image|": 1,
		"network load balancer, reserved public ip, nat gateway, vcn|": 1,
	}
	got := map[string]int{}
	for k, r := range byLabel(res) {
		got[k] = r.Qty
	}
	if diff := cmp.Diff(want, got); diff != "" {
		t.Errorf("quantities (-want +got):\n%s", diff)
	}
	m := byLabel(res)
	if m["jumphost|"].RateID != "VM.Standard.E5.Flex:2x16" || m["control plane|cp"].RateID != "VM.Standard.E5.Flex:4x32" {
		t.Errorf("locals.tf instance type defaults not applied: %+v", m)
	}
	if m["jumphost disk|"].SizeGB != 100 || m["control plane disk|cp"].SizeGB != 100 || m["control plane disk|cp"].RateID != rateBoot {
		t.Errorf("locals.tf disk defaults not applied: %+v", m)
	}
	if m["custom image|"].SizeGB != 8 || m["custom image|"].RateID != rateObject {
		t.Errorf("image = %+v", m["custom image|"])
	}
	for _, r := range res {
		if r.SurvivesDestroy || r.BuildOnly {
			t.Errorf("%s: nothing survives destroy or is build-only by default", r.Label)
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
			c.GPUPools = []tfconfig.Pool{{Name: "g", InstanceType: "VM.GPU.A10.1", Count: 2}}
			c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: "VM.Standard.E5.Flex:8x64", Count: 3, DiskGB: &disk}}
		}, func(t *testing.T, m map[string]pricing.Resource) {
			if g := m["gpu node|g"]; g.Qty != 2 || g.RateID != "VM.GPU.A10.1" {
				t.Errorf("gpu = %+v", g)
			}
			if g := m["gpu node disk|g"]; g.Qty != 2 || g.SizeGB != agentDiskGB {
				t.Errorf("gpu disk = %+v", g)
			}
			if w := m["worker node disk|w"]; w.Qty != 3 || w.SizeGB != 500 {
				t.Errorf("worker disk = %+v", w)
			}
		}},
		{"no nodes", func(c *tfconfig.Common) {
			c.DeployNodes = false
			c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: "VM.Standard.E5.Flex:2x16", Count: 2}}
		}, func(t *testing.T, m map[string]pricing.Resource) {
			if m["control plane|cp"].Qty != 0 || m["worker node|w"].Qty != 0 || m["jumphost|"].Qty != 1 {
				t.Errorf("deploy_nodes=false: %+v", m)
			}
		}},
		{"image_id", func(c *tfconfig.Common) { c.ImageIDSet = true }, func(t *testing.T, m map[string]pricing.Resource) {
			if m["custom image|"].Qty != 0 || m["jumphost|"].Qty != 1 {
				t.Errorf("image_id with nodes: image priced or bastion missing: %+v", m)
			}
		}},
		{"image_id no nodes", func(c *tfconfig.Common) { c.ImageIDSet = true; c.DeployNodes = false }, func(t *testing.T, m map[string]pricing.Resource) {
			if m["custom image|"].Qty != 0 || m["jumphost|"].Qty != 0 {
				t.Errorf("image_id without nodes: image or jumphost priced: %+v", m)
			}
		}},
		{"keep artifacts", func(c *tfconfig.Common) { c.KeepBuildArtifacts = true }, func(t *testing.T, m map[string]pricing.Resource) {
			a := m["build artifacts (qcow2 in bucket)|"]
			if a.Qty != 1 || !a.SurvivesDestroy || a.RateID != rateObject {
				t.Errorf("artifacts = %+v", a)
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

func TestResolveShapeErrors(t *testing.T) {
	for in, want := range map[string]string{
		"VM.Standard.E5.Flex":       "needs a size",
		"VM.GPU.A10.1:2x16":         "only flex shapes",
		"VM.Standard.E5.Flex:0x16":  "expected",
		"VM.Standard.E5.Flex:4x32 ": "expected",
		"VM.Standard.E5.Flex:4-32":  "expected",
		"VM Standard":               "expected",
	} {
		c := baseCommon()
		c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: in, Count: 1}}
		_, diags := oci{}.Resolve(c, nil)
		if !tfconfig.HasErrors(diags) || !strings.Contains(diags[0].Summary, want) || !strings.Contains(diags[0].Summary, `worker_pools["w"]`) {
			t.Errorf("%q: diags %+v, want error containing %q", in, diags, want)
		}
	}
	c := baseCommon()
	c.JumphostInstanceType = "VM.Standard.E5.Flex"
	if _, diags := (oci{}).Resolve(c, nil); !tfconfig.HasErrors(diags) {
		t.Error("jumphost flex shape without a size must fail")
	}
}
