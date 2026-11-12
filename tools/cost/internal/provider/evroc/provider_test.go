package evroc

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

const commonVariablesFile = "../../../../../modules/common/variables-common.tf"

func resolveTFVars(t *testing.T, body string) tfconfig.Common {
	t.Helper()
	decls, diags := tfconfig.ParseVariables(commonVariablesFile, variablesFile)
	if diags.HasErrors() {
		t.Fatal(diags.Error())
	}
	path := filepath.Join(t.TempDir(), "terraform.tfvars")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	tfvars, diags := tfconfig.ParseTFVarsLayered([]string{path})
	if diags.HasErrors() {
		t.Fatal(diags.Error())
	}
	v := tfconfig.NewVars(decls, tfvars, nil)
	cfg, _ := evroc{}.Resolve(tfconfig.ResolveCommon(v), v)
	return cfg.Common
}

// With vpc_name and zones unset, locals.tf takes the zones from the
// subnet_names keys; the zone count drives the per-zone build hosts.
func TestResolveZonesFromSubnetNames(t *testing.T) {
	for _, tc := range []struct {
		name, tfvars string
		want         []string
	}{
		{"default", ``, defaultZones},
		{"subnet_names keys", "vpc_name = \"v\"\nsubnet_names = { b = \"sb\", a = \"sa\" }\n", []string{"a", "b"}},
		{"zones wins", "vpc_name = \"v\"\nsubnet_names = { a = \"sa\" }\nzones = [\"a\"]\n", []string{"a"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if diff := cmp.Diff(tc.want, resolveTFVars(t, tc.tfvars).Zones); diff != "" {
				t.Errorf("zones (-want +got):\n%s", diff)
			}
		})
	}
}
