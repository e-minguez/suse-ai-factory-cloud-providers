package evroc

import (
	"strconv"
	"testing"

	"github.com/google/go-cmp/cmp"
	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclparse"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/zclconf/go-cty/cty"
)

const (
	localsFile    = "../../../../../modules/evroc/locals.tf"
	variablesFile = "../../../../../modules/evroc/variables.tf"
)

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

func parse(t *testing.T, path string) *hclsyntax.Body {
	t.Helper()
	f, diags := hclparse.NewParser().ParseHCLFile(path)
	if diags.HasErrors() {
		t.Fatal(diags.Error())
	}
	return f.Body.(*hclsyntax.Body)
}

// TestDefaultsMatchLocals fails when defaults, defaultZones or
// defaultImageTargetDiskGB diverge from modules/evroc, in either direction.
func TestDefaultsMatchLocals(t *testing.T) {
	found := map[string]string{}
	var zones []string
	hclsyntax.VisitAll(parse(t, localsFile), func(n hclsyntax.Node) hcl.Diagnostics {
		if attr, ok := n.(*hclsyntax.Attribute); ok && attr.Name == "zones" {
			if cond, ok := attr.Expr.(*hclsyntax.ConditionalExpr); ok {
				if v, d := cond.FalseResult.Value(nil); !d.HasErrors() {
					for _, e := range v.AsValueSlice() {
						zones = append(zones, e.AsString())
					}
				}
			}
		}
		call, ok := n.(*hclsyntax.FunctionCallExpr)
		if !ok || call.Name != "coalesce" || len(call.Args) != 2 {
			return nil
		}
		scope, ok := call.Args[0].(*hclsyntax.ScopeTraversalExpr)
		if !ok || scope.Traversal.RootName() != "var" || len(scope.Traversal) != 2 {
			return nil
		}
		def, ok := literal(call.Args[1])
		if !ok {
			return nil // a computed fallback, not a literal default
		}
		found[scope.Traversal[1].(hcl.TraverseAttr).Name] = def
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
	if diff := cmp.Diff(zones, defaultZones); diff != "" {
		t.Errorf("locals.tf zones fallback vs defaultZones (-locals +code):\n%s", diff)
	}

	disk := ""
	for _, b := range parse(t, variablesFile).Blocks {
		if b.Type == "variable" && b.Labels[0] == "image_target_disk_gb" {
			disk, _ = literal(b.Body.Attributes["default"].Expr)
		}
	}
	if disk != strconv.FormatFloat(defaultImageTargetDiskGB, 'f', -1, 64) {
		t.Errorf("variables.tf image_target_disk_gb default = %q, code has %v", disk, defaultImageTargetDiskGB)
	}
}
