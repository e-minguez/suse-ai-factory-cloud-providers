package evroc

import (
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

func baseCommon() tfconfig.Common {
	return tfconfig.Common{
		Region: "eu-central", ClusterName: "c", DeployNodes: true, ControlPlaneCount: 3,
		Zones: []string{"a", "b", "c"}, ImageDiskGB: 8,
	}
}

func expandWith(t *testing.T, c tfconfig.Common, d *details) ([]pricing.Resource, []pricing.Excluded) {
	t.Helper()
	cfg, diags := evroc{}.Resolve(c, nil)
	if tfconfig.HasErrors(diags) {
		t.Fatalf("Resolve: %v", diags)
	}
	if d != nil {
		cfg.Details = *d
	}
	return evroc{}.Expand(cfg)
}

func expand(t *testing.T, c tfconfig.Common) []pricing.Resource {
	t.Helper()
	res, _ := expandWith(t, c, nil)
	return res
}

func byKey(res []pricing.Resource) map[string]pricing.Resource {
	out := map[string]pricing.Resource{}
	for _, r := range res {
		out[r.Label+"|"+r.Pool] = r
	}
	return out
}

func qtys(res []pricing.Resource) map[string]int {
	out := map[string]int{}
	for k, r := range byKey(res) {
		out[k] = r.Qty
	}
	return out
}

func TestExpandDefaults(t *testing.T) {
	res, excluded := expandWith(t, baseCommon(), nil)
	want := map[string]int{
		"jumphost|": 1, "jumphost disk|": 1,
		"public ip (jumphost)|": 1, "public ip (api, ingress)|": 1,
		"control plane|cp": 3, "control plane disk|cp": 3, "public ip (control plane)|cp": 0,
		"image builder|": 2, "image builder disk|": 2, "image target disk|": 3,
		"vpc, subnets, security and placement groups|": 1,
	}
	if diff := cmp.Diff(want, qtys(res)); diff != "" {
		t.Errorf("quantities (-want +got):\n%s", diff)
	}
	m := byKey(res)
	if m["jumphost|"].RateID != "a1a.m" || m["control plane|cp"].RateID != "c1a.m" {
		t.Errorf("locals.tf defaults not applied: %+v %+v", m["jumphost|"], m["control plane|cp"])
	}
	if m["control plane disk|cp"].SizeGB != 200 || m["jumphost disk|"].SizeGB != 200 || m["image target disk|"].SizeGB != 32 {
		t.Errorf("disk sizes: %+v", res)
	}
	labels := map[string]string{}
	for _, e := range excluded {
		labels[e.Label] = e.Reason
	}
	for _, l := range []string{"load balancer", "image snapshots (one per zone)"} {
		if labels[l] != noRate {
			t.Errorf("excluded %q = %q", l, labels[l])
		}
	}
	if labels["outbound transfer"] == "" {
		t.Error("outbound transfer must be excluded")
	}
	// Build-only: builders and (without keep_build_artifacts) target disks.
	for k, r := range m {
		wantBuild := k == "image builder|" || k == "image builder disk|" || k == "image target disk|"
		if r.BuildOnly != wantBuild || r.SurvivesDestroy {
			t.Errorf("%s: BuildOnly=%v SurvivesDestroy=%v", k, r.BuildOnly, r.SurvivesDestroy)
		}
	}
}

func TestExpandVariants(t *testing.T) {
	gpu := tfconfig.Pool{Name: "g", InstanceType: "gn-b200.s", Count: 2}
	disk := 500.0
	tests := []struct {
		name   string
		mutate func(*tfconfig.Common)
		d      *details
		want   map[string]int
	}{
		{"single zone has no builders", func(c *tfconfig.Common) { c.Zones = []string{"a"} }, nil,
			map[string]int{"image builder|": 0, "image target disk|": 1, "jumphost|": 1}},
		{"no nodes", func(c *tfconfig.Common) {
			c.DeployNodes = false
			c.ControlPlanePublicIP = true
			c.GPUPools = []tfconfig.Pool{gpu}
		}, nil, map[string]int{"control plane|cp": 0, "public ip (control plane)|cp": 0, "gpu node|g": 0, "gpu node disk|g": 0, "jumphost|": 1}},
		{"control plane public ips", func(c *tfconfig.Common) { c.ControlPlanePublicIP = true }, nil,
			map[string]int{"public ip (control plane)|cp": 3}},
		{"gpu and worker pools", func(c *tfconfig.Common) {
			gpuIP := gpu
			gpuIP.PublicIP = true
			c.GPUPools = []tfconfig.Pool{gpuIP}
			c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: "c1a.l", Count: 4, DiskGB: &disk}}
		}, nil, map[string]int{
			"gpu node|g": 2, "gpu node disk|g": 2, "public ip (gpu node)|g": 2,
			"worker node|w": 4, "worker node disk|w": 4, "public ip (worker node)|w": 0,
		}},
		{"image_ids set", func(c *tfconfig.Common) {}, &details{imageTargetDiskGB: 32, imageIDs: 3},
			map[string]int{"image builder|": 0, "image builder disk|": 0, "image target disk|": 0, "jumphost|": 1}},
		{"image_id set", func(c *tfconfig.Common) { c.ImageIDSet = true }, nil,
			map[string]int{"image builder|": 0, "image target disk|": 0}},
	}
	for _, tt := range tests {
		c := baseCommon()
		tt.mutate(&c)
		res, excluded := expandWith(t, c, tt.d)
		got := qtys(res)
		for k, w := range tt.want {
			if g, ok := got[k]; !ok || g != w {
				t.Errorf("%s: %s = %d (present=%v), want %d", tt.name, k, g, ok, w)
			}
		}
		if tt.d != nil || tt.name == "image_id set" {
			for _, e := range excluded {
				if e.Label == "image snapshots (one per zone)" {
					t.Errorf("%s: no snapshots are built, so none are excluded", tt.name)
				}
			}
		}
	}
}

func TestExpandPoolDisk(t *testing.T) {
	c := baseCommon()
	big := 500.0
	cpDisk := 100.0
	c.ControlPlaneDiskGB = &cpDisk
	c.WorkerPools = []tfconfig.Pool{
		{Name: "w1", InstanceType: "c1a.m", Count: 1},
		{Name: "w2", InstanceType: "c1a.m", Count: 1, DiskGB: &big},
	}
	m := byKey(expand(t, c))
	if m["worker node disk|w1"].SizeGB != 100 || m["worker node disk|w2"].SizeGB != 500 {
		t.Errorf("pool disks: %v %v", m["worker node disk|w1"].SizeGB, m["worker node disk|w2"].SizeGB)
	}
}

func TestExpandKeepBuildArtifacts(t *testing.T) {
	c := baseCommon()
	c.KeepBuildArtifacts = true
	m := byKey(expand(t, c))
	if m["image target disk|"].BuildOnly || m["image target disk|"].Qty != 3 {
		t.Errorf("target disks are kept: %+v", m["image target disk|"])
	}
	// Builders are removed on the second pass regardless.
	if !m["image builder|"].BuildOnly || !m["image builder disk|"].BuildOnly {
		t.Error("builders are always build-only")
	}
}

func TestExpandRoles(t *testing.T) {
	c := baseCommon()
	c.GPUPools = []tfconfig.Pool{{Name: "g", InstanceType: "gn-l40s.s", Count: 1}}
	res := expand(t, c)
	roles := map[string]string{}
	for _, r := range res {
		roles[r.Label] = r.Role
	}
	for label, role := range map[string]string{
		"jumphost": "jumphost", "control plane": "control_plane", "gpu node": "gpu",
		"image builder": "builder", "image target disk": "image", "public ip (api, ingress)": "lb",
	} {
		if roles[label] != role {
			t.Errorf("%s role = %q, want %q", label, roles[label], role)
		}
	}
}

func TestResolveNullRegionUsesCLIContextLabel(t *testing.T) {
	c := baseCommon()
	c.Region = ""
	cfg, diags := evroc{}.Resolve(c, nil)
	if tfconfig.HasErrors(diags) {
		t.Fatalf("a null region must not be an error: %v", diags)
	}
	if cfg.Common.Region != regionCLIContext {
		t.Errorf("region label = %q, want %q", cfg.Common.Region, regionCLIContext)
	}
}

func TestResolveDefaultsZones(t *testing.T) {
	c := baseCommon()
	c.Zones = nil
	cfg, _ := evroc{}.Resolve(c, nil)
	if diff := cmp.Diff(defaultZones, cfg.Common.Zones); diff != "" {
		t.Error(diff)
	}
}

var _ provider.Provider = evroc{}
