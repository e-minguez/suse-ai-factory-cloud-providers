package aws

import (
	"os"
	"regexp"
	"strconv"
	"testing"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclparse"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/zclconf/go-cty/cty"
)

const localsFile = "../../../../../modules/aws/locals.tf"

// literal evaluates expr when it needs no context (a literal), as a string.
func literal(expr hcl.Expression) (string, bool) {
	v, diags := expr.Value(nil)
	if diags.HasErrors() || v.IsNull() {
		return "", false
	}
	switch v.Type() {
	case cty.String:
		return v.AsString(), true
	case cty.Number:
		return v.AsBigFloat().Text('f', -1), true
	}
	return "", false
}

// TestDefaultsMatchLocals fails when defaults diverges from the literal
// `coalesce(var.X, literal)` calls in modules/aws/locals.tf, in either
// direction, or when poolDiskGB or defaultZones differ from their locals.
func TestDefaultsMatchLocals(t *testing.T) {
	f, diags := hclparse.NewParser().ParseHCLFile(localsFile)
	if diags.HasErrors() {
		t.Fatal(diags.Error())
	}
	found := map[string]string{}
	hclsyntax.VisitAll(f.Body.(*hclsyntax.Body), func(n hclsyntax.Node) hcl.Diagnostics {
		call, ok := n.(*hclsyntax.FunctionCallExpr)
		if !ok || call.Name != "coalesce" || len(call.Args) != 2 {
			return nil
		}
		scope, ok := call.Args[0].(*hclsyntax.ScopeTraversalExpr)
		if !ok || scope.Traversal.RootName() != "var" || len(scope.Traversal) != 2 {
			return nil
		}
		if def, ok := literal(call.Args[1]); ok && def != "" {
			found[scope.Traversal[1].(hcl.TraverseAttr).Name] = def
		}
		return nil
	})
	for name, want := range found {
		if got, ok := defaults[name]; !ok || got != want {
			t.Errorf("locals.tf coalesces var.%s to %q; defaults has %q (present=%v)", name, want, got, ok)
		}
	}
	for name := range defaults {
		if _, ok := found[name]; !ok {
			t.Errorf("defaults[%q] has no matching coalesce in locals.tf", name)
		}
	}

	src, err := os.ReadFile(localsFile)
	if err != nil {
		t.Fatal(err)
	}
	disks := regexp.MustCompile(`coalesce\(p\.disk_size_gb, (\d+)\)`).FindAllSubmatch(src, -1)
	if len(disks) != 2 {
		t.Fatalf("want 2 pool disk defaults in locals.tf (worker, gpu), found %d", len(disks))
	}
	for _, m := range disks {
		if string(m[1]) != strconv.Itoa(poolDiskGB) {
			t.Errorf("locals.tf pool disk default %s, poolDiskGB = %d", m[1], poolDiskGB)
		}
	}
	zones := regexp.MustCompile(`slice\(data\.aws_availability_zones\.available\.names, 0, min\((\d+),`).FindSubmatch(src)
	if zones == nil || string(zones[1]) != strconv.Itoa(defaultZones) {
		t.Errorf("locals.tf default zone count %q, defaultZones = %d", zones, defaultZones)
	}
}
