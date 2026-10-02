package tfconfig

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTFVars(t *testing.T, name, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func resolve(t *testing.T, overrides map[string]string, files ...string) (Common, []Diagnostic) {
	t.Helper()
	decls, diags := ParseVariables(commonVariables, vultrVariables)
	if diags.HasErrors() {
		t.Fatal(diags.Error())
	}
	tfvars, diags := ParseTFVarsLayered(files)
	if diags.HasErrors() {
		t.Fatal(diags.Error())
	}
	v := NewVars(decls, tfvars, overrides)
	c := ResolveCommon(v)
	return c, v.Diagnostics()
}

func TestResolveCommonDefaults(t *testing.T) {
	c, diags := resolve(t, map[string]string{"region": "ams"})
	if HasErrors(diags) {
		t.Fatalf("diagnostics: %v", diags)
	}
	if c.Region != "ams" || c.ClusterName != "suse-ai-factory" || !c.DeployNodes || c.ControlPlaneCount != 3 {
		t.Errorf("unexpected defaults: %+v", c)
	}
	if c.ControlPlaneInstanceType != "" || c.ControlPlaneDiskGB != nil || c.JumphostInstanceType != "" {
		t.Errorf("null variables must stay unset for the provider to default: %+v", c)
	}
	if c.ImageDiskGB != 8 || c.IngressController != "traefik" || c.ImageIDSet || c.KeepBuildArtifacts {
		t.Errorf("unexpected image defaults: %+v", c)
	}
}

func TestResolveLayeredLaterWins(t *testing.T) {
	all := writeTFVars(t, "common-all.tfvars", "cluster_name = \"shared\"\ncontrol_plane_count = 1\nimage_id = \"img-1\"\n")
	cluster := writeTFVars(t, "terraform.tfvars", "control_plane_count = 5\nzones = [\"a\", \"b\"]\n")
	c, diags := resolve(t, nil, all, cluster)
	if HasErrors(diags) {
		t.Fatalf("diagnostics: %v", diags)
	}
	if c.ClusterName != "shared" || c.ControlPlaneCount != 5 || !c.ImageIDSet || len(c.Zones) != 2 {
		t.Errorf("layering wrong: %+v", c)
	}
}

func TestResolvePools(t *testing.T) {
	f := writeTFVars(t, "t.tfvars", `
gpu_pools = {
  zz = { instance_type = "gn.l", count = 2, disk_size_gb = 500, zone = "b", public_ip = true }
  aa = { instance_type = "vbm-x", kind = "bare_metal" }
}
worker_pools = {
  w = { instance_type = "c1a.m", count = 0 }
}
`)
	c, diags := resolve(t, nil, f)
	if HasErrors(diags) {
		t.Fatalf("diagnostics: %v", diags)
	}
	if len(c.GPUPools) != 2 || c.GPUPools[0].Name != "aa" || c.GPUPools[1].Name != "zz" {
		t.Fatalf("pools must come back sorted by key: %+v", c.GPUPools)
	}
	aa, zz := c.GPUPools[0], c.GPUPools[1]
	if aa.Count != 1 || aa.Kind != "bare_metal" || aa.PublicIP || aa.DiskGB != nil || aa.Zone != nil {
		t.Errorf("optional() defaults not applied: %+v", aa)
	}
	if zz.Count != 2 || zz.Kind != "vm" || !zz.PublicIP || zz.DiskGB == nil || *zz.DiskGB != 500 || zz.Zone == nil || *zz.Zone != "b" {
		t.Errorf("explicit values lost: %+v", zz)
	}
	if len(c.WorkerPools) != 1 || c.WorkerPools[0].Count != 0 {
		t.Errorf("worker pool: %+v", c.WorkerPools)
	}
}

func TestResolveErrorsNeverEchoValues(t *testing.T) {
	const secret = "s3cr3t-value-123"
	f := writeTFVars(t, "t.tfvars", "control_plane_count = \""+secret+"\"\nimage_disk_size = \""+secret+"\"\nunknown_credential = \""+secret+"\"\n")
	_, diags := resolve(t, nil, f)
	if !HasErrors(diags) {
		t.Fatal("wrong types must be errors")
	}
	sawUndeclared := false
	for _, d := range diags {
		if strings.Contains(d.Format(), secret) {
			t.Errorf("diagnostic leaks a value: %s", d.Format())
		}
		sawUndeclared = sawUndeclared || strings.Contains(d.Summary, "unknown_credential")
	}
	if !sawUndeclared {
		t.Error("an undeclared tfvars key should warn by name")
	}
}

func TestResolveBadPool(t *testing.T) {
	f := writeTFVars(t, "t.tfvars", "gpu_pools = { a = { count = 1 } }\n")
	if _, diags := resolve(t, nil, f); !HasErrors(diags) {
		t.Error("a pool without instance_type must be an error")
	}
}

func TestParseDiskSizeGB(t *testing.T) {
	for in, want := range map[string]float64{"8G": 8, "1T": 1000, "500M": 0.5} {
		if got, err := parseDiskSizeGB(in); err != nil || got != want {
			t.Errorf("parseDiskSizeGB(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	if _, err := parseDiskSizeGB("8"); err == nil {
		t.Error("a size without a unit must fail")
	}
}

// TestDiagnosticRedaction covers the syntax-error path: Detail is dropped for
// a diagnostic located in a tfvars file.
func TestDiagnosticRedaction(t *testing.T) {
	const secret = "nvapi-FAKEFAKEFAKE"
	f := writeTFVars(t, "t.tfvars", "nvidia_api_key = \""+secret+"\nregion = \"x\"\n")
	_, hclDiags := ParseTFVarsLayered([]string{f})
	if !hclDiags.HasErrors() {
		t.Fatal("expected a syntax error")
	}
	for _, d := range FromHCLDiagnostics(hclDiags, f) {
		if strings.Contains(d.Format(), secret) {
			t.Errorf("redacted diagnostic leaks the value: %s", d.Format())
		}
	}
}
