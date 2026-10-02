package vultr

import (
	"strconv"
	"testing"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclparse"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/zclconf/go-cty/cty"
)

const localsFile = "../../../../../modules/vultr/locals.tf"

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
// `coalesce(var.X, "literal")` calls in modules/vultr/locals.tf, in either
// direction, or when lbNodes differs from the `lb_nodes` local.
func TestDefaultsMatchLocals(t *testing.T) {
	f, diags := hclparse.NewParser().ParseHCLFile(localsFile)
	if diags.HasErrors() {
		t.Fatal(diags.Error())
	}
	body := f.Body.(*hclsyntax.Body)

	found := map[string]string{}
	lb := ""
	hclsyntax.VisitAll(body, func(n hclsyntax.Node) hcl.Diagnostics {
		if attr, ok := n.(*hclsyntax.Attribute); ok && attr.Name == "lb_nodes" {
			lb, _ = literal(attr.Expr)
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
	if lb != strconv.Itoa(lbNodes) {
		t.Errorf("locals.tf lb_nodes = %q, lbNodes = %d", lb, lbNodes)
	}
}
