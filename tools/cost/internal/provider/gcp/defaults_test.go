package gcp

import (
	"maps"
	"os"
	"regexp"
	"strconv"
	"testing"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclparse"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/zclconf/go-cty/cty"
)

const localsFile = "../../../../../modules/gcp/locals.tf"

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
// `coalesce(var.X, literal)` calls in modules/gcp/locals.tf, in either
// direction, or when agentDiskGB differ from their locals.
func TestDefaultsMatchLocals(t *testing.T) {
	f, diags := hclparse.NewParser().ParseHCLFile(localsFile)
	if diags.HasErrors() {
		t.Fatal(diags.Error())
	}
	body := f.Body.(*hclsyntax.Body)

	found := map[string]string{}
	consts := map[string]string{}
	hclsyntax.VisitAll(body, func(n hclsyntax.Node) hcl.Diagnostics {
		if attr, ok := n.(*hclsyntax.Attribute); ok && attr.Name == "agent_disk_gb" {
			consts[attr.Name], _ = literal(attr.Expr)
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
	for name, code := range map[string]float64{"agent_disk_gb": agentDiskGB} {
		if consts[name] != strconv.FormatFloat(code, 'f', -1, 64) {
			t.Errorf("locals.tf %s = %q, code has %v", name, consts[name], code)
		}
	}
}

// TestHyperdiskFamiliesMatchLocals: the family list that picks the boot disk
// type is the one in locals.tf.
func TestHyperdiskFamiliesMatchLocals(t *testing.T) {
	data, err := os.ReadFile(localsFile)
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`hyperdisk_families\s*=\s*\[([^\]]*)\]`).FindSubmatch(data)
	if m == nil {
		t.Fatal("hyperdisk_families not found in locals.tf")
	}
	want := map[string]bool{}
	for _, f := range regexp.MustCompile(`"([a-z0-9]+)"`).FindAllSubmatch(m[1], -1) {
		want[string(f[1])] = true
	}
	if !maps.Equal(want, hyperdiskFamilies) {
		t.Errorf("locals.tf hyperdisk_families = %v, code has %v", want, hyperdiskFamilies)
	}
}
