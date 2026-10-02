package tfconfig

import (
	"testing"

	"github.com/zclconf/go-cty/cty/gocty"
)

// Paths from this package's directory to the repository's variable files.
const (
	commonVariables = "../../../../modules/common/variables-common.tf"
	vultrVariables  = "../../../../modules/vultr/variables.tf"
)

// TestParsesRealVariables parses the production common and provider files
// together, with brace-in-regex validations and check blocks, and expects no
// diagnostics.
func TestParsesRealVariables(t *testing.T) {
	decls, diags := ParseVariables(commonVariables, vultrVariables)
	if diags.HasErrors() {
		t.Fatalf("diagnostics: %s", diags.Error())
	}
	for _, name := range []string{"region", "cluster_name", "gpu_pools", "worker_pools", "vultr_api_key"} {
		if _, ok := decls[name]; !ok {
			t.Errorf("variable %q not found", name)
		}
	}
	if decls["region"].HasDefault && !decls["region"].Default.IsNull() {
		t.Error("common region should default to null")
	}
	var n int
	if err := gocty.FromCtyValue(decls["control_plane_count"].Default, &n); err != nil || n != 3 {
		t.Errorf("control_plane_count default = %d, %v; want 3", n, err)
	}
	if !decls["vultr_api_key"].Sensitive {
		t.Error("vultr_api_key should be sensitive")
	}
}

func TestParseVariablesRejectsDuplicates(t *testing.T) {
	if _, diags := ParseVariables(commonVariables, commonVariables); !diags.HasErrors() {
		t.Error("declaring the same variables twice must fail")
	}
}

// TestParsesSyntheticVariablesFixture proves a heredoc description and a
// top-level check block are handled without error or evaluation.
func TestParsesSyntheticVariablesFixture(t *testing.T) {
	decls, diags := ParseVariables("testdata/synthetic_variables.tf")
	if diags.HasErrors() {
		t.Fatalf("unexpected diagnostics: %s", diags.Error())
	}
	if _, ok := decls["region"]; !ok {
		t.Error("variable \"region\" missing despite its heredoc description")
	}
	if w, ok := decls["widgets"]; !ok || w.Defaults == nil {
		t.Error("widgets should parse with optional() defaults")
	}
}
