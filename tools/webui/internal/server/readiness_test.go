package server

import (
	"slices"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/schema"
)

func TestMissingForDeploy(t *testing.T) {
	fields := []schema.Field{
		{Name: "admin_cidrs", Label: "Admin CIDRs", Required: true},
		{Name: "exoscale_api_key", Label: "exoscale_api_key", Required: true},
		{Name: "components", Default: []any{"rancher", "local-path-provisioner"}},
		{Name: "appco_username", Label: "AppCo user"},
		{Name: "appco_password", Label: "AppCo password"},
	}
	vals := map[string]any{}
	value := func(f schema.Field) any {
		if v, ok := vals[f.Name]; ok {
			return v
		}
		return f.Default
	}
	got := missingForDeploy(fields, value)
	want := []string{"Admin CIDRs", "exoscale_api_key (account profile)", "AppCo user", "AppCo password"}
	if !slices.Equal(got, want) {
		t.Fatalf("got %q", got)
	}
	vals["admin_cidrs"] = []any{"192.0.2.1/32"}
	vals["exoscale_api_key"] = "k"
	vals["components"] = []any{"rancher"} // no Application Collection component
	if got := missingForDeploy(fields, value); len(got) != 0 {
		t.Fatalf("got %q", got)
	}
}
