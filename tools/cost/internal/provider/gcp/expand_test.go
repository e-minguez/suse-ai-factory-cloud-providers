package gcp

import (
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

func baseCommon() tfconfig.Common {
	return tfconfig.Common{ClusterName: "c", DeployNodes: true, ControlPlaneCount: 3, ImageDiskGB: 8, IngressController: "traefik"}
}

func expand(t *testing.T, c tfconfig.Common) []pricing.Resource {
	t.Helper()
	cfg, diags := gcp{}.Resolve(c, nil)
	if tfconfig.HasErrors(diags) {
		t.Fatalf("Resolve: %v", diags)
	}
	if cfg.Common.Region != "europe-west4" && c.Region == "" {
		t.Errorf("region default not applied: %q", cfg.Common.Region)
	}
	res, excluded := gcp{}.Expand(cfg)
	if len(excluded) != 3 || excluded[0].Label != "outbound traffic" {
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
		"jumphost|": 1, "jumphost disk|": 1, "external IPv4 (jumphost)|": 1,
		"control plane|cp": 3, "control plane disk|cp": 3,
		"image target disk|": 1, "image snapshot (upper bound)|": 1, "image (upper bound)|": 1,
		"forwarding rules (minimum charge, first 5)|": 1, "forwarding rules (additional)|": 0,
		"external IPv4 (load balancer)|": 1,
		// The control planes have no public address: they use Cloud NAT.
		"cloud nat gateway (per VM, max 32)|": 3, "external IPv4 (cloud nat)|": 1,
		"vpc, subnet, firewall rules, router, health checks, internal address|": 1,
		"external IPv4 (control plane)|cp":                                      0,
	}
	got := map[string]int{}
	for k, r := range byLabel(res) {
		got[k] = r.Qty
	}
	delete(got, "external IPv4 (control plane)|cp") // not emitted without a public IP
	delete(want, "external IPv4 (control plane)|cp")
	if diff := cmp.Diff(want, got); diff != "" {
		t.Errorf("quantities (-want +got):\n%s", diff)
	}
	m := byLabel(res)
	if m["jumphost|"].RateID != "e2-standard-4" || m["control plane|cp"].RateID != "n2-standard-4" {
		t.Errorf("locals.tf machine type defaults not applied: %+v", m)
	}
	if m["jumphost disk|"].SizeGB != 100 || m["control plane disk|cp"].SizeGB != 100 || m["control plane disk|cp"].RateID != "disk:pd-balanced" {
		t.Errorf("locals.tf disk defaults not applied: %+v", m)
	}
	if m["image target disk|"].SizeGB != 8 {
		t.Errorf("image target disk = %+v", m["image target disk|"])
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
			c.GPUPools = []tfconfig.Pool{{Name: "g", InstanceType: "g2-standard-8", Count: 2, PublicIP: true}}
			c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: "c3-standard-8", Count: 3, DiskGB: &disk}}
		}, func(t *testing.T, m map[string]pricing.Resource) {
			if g := m["gpu node|g"]; g.Qty != 2 || g.RateID != "g2-standard-8" {
				t.Errorf("gpu = %+v", g)
			}
			if g := m["gpu node disk|g"]; g.Qty != 2 || g.SizeGB != agentDiskGB || g.RateID != "disk:pd-balanced" {
				t.Errorf("gpu disk = %+v", g)
			}
			if w := m["worker node disk|w"]; w.Qty != 3 || w.SizeGB != 500 || w.RateID != "disk:hyperdisk-balanced" {
				t.Errorf("worker disk = %+v (C3 boots from hyperdisk)", w)
			}
			if ip := m["external IPv4 (gpu node)|g"]; ip.Qty != 2 {
				t.Errorf("gpu public ip = %+v", ip)
			}
			// 3 control planes + 3 workers use NAT; the public GPU nodes do not.
			if n := m["cloud nat gateway (per VM, max 32)|"]; n.Qty != 6 {
				t.Errorf("nat = %+v", n)
			}
		}},
		{"no ingress", func(c *tfconfig.Common) { c.IngressController = "none" }, func(t *testing.T, m map[string]pricing.Resource) {
			if m["forwarding rules (additional)|"].Qty != 0 {
				t.Error("3 rules fit the minimum charge")
			}
		}},
		{"nat cap", func(c *tfconfig.Common) {
			c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: "n2-standard-4", Count: 40}}
		}, func(t *testing.T, m map[string]pricing.Resource) {
			if n := m["cloud nat gateway (per VM, max 32)|"]; n.Qty != 32 {
				t.Errorf("nat = %+v", n)
			}
		}},
		{"no nodes", func(c *tfconfig.Common) {
			c.DeployNodes = false
			c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: "n2-standard-4", Count: 2}}
		}, func(t *testing.T, m map[string]pricing.Resource) {
			if m["control plane|cp"].Qty != 0 || m["worker node|w"].Qty != 0 || m["jumphost|"].Qty != 1 || m["cloud nat gateway (per VM, max 32)|"].Qty != 0 {
				t.Errorf("deploy_nodes=false: %+v", m)
			}
		}},
		{"image_id", func(c *tfconfig.Common) { c.ImageIDSet = true }, func(t *testing.T, m map[string]pricing.Resource) {
			if m["image target disk|"].Qty != 0 || m["image (upper bound)|"].Qty != 0 || m["jumphost|"].Qty != 1 {
				t.Errorf("image_id with nodes: image priced or bastion missing: %+v", m)
			}
		}},
		{"image_id no nodes", func(c *tfconfig.Common) { c.ImageIDSet = true; c.DeployNodes = false }, func(t *testing.T, m map[string]pricing.Resource) {
			if m["image snapshot (upper bound)|"].Qty != 0 || m["jumphost|"].Qty != 0 || m["external IPv4 (jumphost)|"].Qty != 0 {
				t.Errorf("image_id without nodes: image or jumphost priced: %+v", m)
			}
		}},
		{"public control planes", func(c *tfconfig.Common) { c.ControlPlanePublicIP = true }, func(t *testing.T, m map[string]pricing.Resource) {
			if m["external IPv4 (control plane)|cp"].Qty != 3 || m["cloud nat gateway (per VM, max 32)|"].Qty != 0 {
				t.Errorf("public control planes: %+v", m)
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

func TestBootDiskTypeOverride(t *testing.T) {
	cfg, _ := gcp{}.Resolve(baseCommon(), nil)
	cfg.Details = details{bootDiskType: "pd-ssd"}
	m := byLabel(first(gcp{}.Expand(cfg)))
	if m["control plane disk|cp"].RateID != "disk:pd-ssd" || m["jumphost disk|"].RateID != "disk:pd-balanced" {
		t.Errorf("override: nodes use it, the jumphost keeps the family default: %+v", m)
	}
}

func first(r []pricing.Resource, _ []pricing.Excluded) []pricing.Resource { return r }

func TestResolveTypeErrors(t *testing.T) {
	for in, want := range map[string]string{
		"g4-standard-12":    "fractional",
		"n2-standard-4:2x8": "expected",
		"N2 standard":       "expected",
		"standard":          "expected",
	} {
		c := baseCommon()
		c.WorkerPools = []tfconfig.Pool{{Name: "w", InstanceType: in, Count: 1}}
		_, diags := gcp{}.Resolve(c, nil)
		if !tfconfig.HasErrors(diags) || !strings.Contains(diags[0].Summary, want) || !strings.Contains(diags[0].Summary, `worker_pools["w"]`) {
			t.Errorf("%q: diags %+v, want error containing %q", in, diags, want)
		}
	}
	c := baseCommon()
	c.JumphostInstanceType = "g4-standard-6"
	if _, diags := (gcp{}).Resolve(c, nil); !tfconfig.HasErrors(diags) {
		t.Error("fractional G4 jumphost must fail")
	}
}
