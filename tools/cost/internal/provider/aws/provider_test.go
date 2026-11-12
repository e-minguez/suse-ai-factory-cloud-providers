package aws

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

const (
	commonVariablesFile = "../../../../../modules/common/variables-common.tf"
	variablesFile       = "../../../../../modules/aws/variables.tf"
)

func resolveTFVars(t *testing.T, body string) (*awsProvider, details) {
	t.Helper()
	decls, diags := tfconfig.ParseVariables(commonVariablesFile, variablesFile)
	if diags.HasErrors() {
		t.Fatal(diags.Error())
	}
	path := filepath.Join(t.TempDir(), "terraform.tfvars")
	if err := os.WriteFile(path, []byte("region = \"us-east-1\"\n"+body), 0o600); err != nil {
		t.Fatal(err)
	}
	tfvars, diags := tfconfig.ParseTFVarsLayered([]string{path})
	if diags.HasErrors() {
		t.Fatal(diags.Error())
	}
	v := tfconfig.NewVars(decls, tfvars, nil)
	p := &awsProvider{}
	cfg, _ := p.Resolve(tfconfig.ResolveCommon(v), v)
	return p, cfg.Details.(details)
}

// With vpc_id the zones default to the private_subnet_ids keys, and the
// existing network's NAT gateway is not priced.
func TestResolveExistingVPC(t *testing.T) {
	_, d := resolveTFVars(t, `vpc_id = "vpc-1"
public_subnet_ids  = { a = "subnet-1", b = "subnet-2" }
private_subnet_ids = { a = "subnet-3", b = "subnet-4" }
`)
	if d.zones != 2 || !d.existingVPC {
		t.Fatalf("details = %+v, want 2 zones and existingVPC", d)
	}

	p, cfg := resolved(t, tfconfig.Common{Region: "us-east-1", DeployNodes: true, ControlPlaneCount: 1, ImageDiskGB: 8})
	cfg.Details = d
	res, _ := p.Expand(cfg)
	for label, want := range map[string]int{"nat gateway": 0, "public IPv4 (nat gateway)": 0, "public IPv4 (public NLB, one per zone)": 2} {
		if got, _ := qtyOf(res, label); got != want {
			t.Errorf("%q qty = %d, want %d with vpc_id", label, got, want)
		}
	}
}

func TestResolveNewVPCDefaults(t *testing.T) {
	_, d := resolveTFVars(t, "")
	if d.zones != defaultZones || d.existingVPC {
		t.Fatalf("details = %+v, want %d zones and a new VPC", d, defaultZones)
	}
}
