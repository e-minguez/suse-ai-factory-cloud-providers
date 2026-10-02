package tfconfig

import (
	"fmt"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/ext/typeexpr"
	"github.com/hashicorp/hcl/v2/hclparse"
	"github.com/zclconf/go-cty/cty"
)

// VariableDecl is one `variable` block from variables.tf, reduced to what
// pricing needs: its type constraint, any optional() defaults typeexpr found
// nested inside that constraint, its own top-level `default` (if any), and
// whether it is marked sensitive. `validation` blocks are consumed without
// being evaluated -- see variableBodySchema -- and `check` blocks never reach
// this type at all -- see ParseVariables.
type VariableDecl struct {
	Name       string
	Type       cty.Type
	Defaults   *typeexpr.Defaults // nil if the type expression declared no optional() defaults
	Default    cty.Value          // cty.NilVal if the block has no `default` attribute
	HasDefault bool
	Sensitive  bool
}

// variablesFileSchema pulls only `variable "NAME" { ... }` blocks out of a
// variables.tf-shaped file. Everything else -- in particular the two
// top-level `check` blocks -- lands in PartialContent's second return value
// (Remain) and is dropped without a second look: this tool never builds the
// data sources those checks reference, and evaluating them is not its job.
var variablesFileSchema = &hcl.BodySchema{
	Blocks: []hcl.BlockHeaderSchema{
		{Type: "variable", LabelNames: []string{"name"}},
	},
}

// variableBodySchema pulls `type`, `default`, `sensitive` and `description`
// out of one variable block and swallows any `validation` blocks whole, as
// hcl.Body values that are never handed to an EvalContext. That is what
// keeps the braces inside e.g.
// `can(regex("^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$", k))` from mattering here
// at all: hcl/v2's real parser already tokenized them correctly as part of a
// quoted string, and PartialContent only needs to find the block's closing
// brace, not read inside it.
var variableBodySchema = &hcl.BodySchema{
	Attributes: []hcl.AttributeSchema{
		{Name: "type", Required: true},
		{Name: "default", Required: false},
		{Name: "sensitive", Required: false},
		{Name: "description", Required: false},
		{Name: "nullable", Required: false},
	},
	Blocks: []hcl.BlockHeaderSchema{
		{Type: "validation"},
	},
}

// ParseVariables reads variables.tf-shaped files (the shared common file plus
// the provider module's own) and returns every `variable` block's
// declaration, keyed by name. A name declared twice is an error.
func ParseVariables(paths ...string) (map[string]*VariableDecl, hcl.Diagnostics) {
	all := map[string]*VariableDecl{}
	var diags hcl.Diagnostics
	for _, p := range paths {
		decls, d := parseVariablesFile(p)
		diags = append(diags, d...)
		if d.HasErrors() {
			return nil, diags
		}
		for name, decl := range decls {
			if _, dup := all[name]; dup {
				diags = append(diags, &hcl.Diagnostic{Severity: hcl.DiagError, Summary: fmt.Sprintf("variable %q declared in more than one file", name)})
				return nil, diags
			}
			all[name] = decl
		}
	}
	return all, diags
}

func parseVariablesFile(path string) (map[string]*VariableDecl, hcl.Diagnostics) {
	parser := hclparse.NewParser()
	f, diags := parser.ParseHCLFile(path)
	if diags.HasErrors() {
		return nil, diags
	}

	content, _, contentDiags := f.Body.PartialContent(variablesFileSchema)
	diags = append(diags, contentDiags...)
	if contentDiags.HasErrors() {
		return nil, diags
	}

	decls := make(map[string]*VariableDecl, len(content.Blocks))
	for _, block := range content.Blocks {
		name := block.Labels[0]
		decl, declDiags := parseVariableBlock(name, block.Body)
		diags = append(diags, declDiags...)
		if decl != nil {
			decls[name] = decl
		}
	}
	return decls, diags
}

func parseVariableBlock(name string, body hcl.Body) (*VariableDecl, hcl.Diagnostics) {
	content, _, diags := body.PartialContent(variableBodySchema)
	if diags.HasErrors() {
		return nil, diags
	}

	decl := &VariableDecl{Name: name}

	typeAttr := content.Attributes["type"]
	ty, defs, typeDiags := typeexpr.TypeConstraintWithDefaults(typeAttr.Expr)
	diags = append(diags, typeDiags...)
	if typeDiags.HasErrors() {
		return nil, diags
	}
	decl.Type = ty
	decl.Defaults = defs

	if attr, ok := content.Attributes["default"]; ok {
		val, valDiags := attr.Expr.Value(&hcl.EvalContext{})
		diags = append(diags, valDiags...)
		if !valDiags.HasErrors() {
			decl.Default = val
			decl.HasDefault = true
		}
	}

	if attr, ok := content.Attributes["sensitive"]; ok {
		val, valDiags := attr.Expr.Value(&hcl.EvalContext{})
		diags = append(diags, valDiags...)
		if !valDiags.HasErrors() && val.Type() == cty.Bool && !val.IsNull() && val.True() {
			decl.Sensitive = true
		}
	}

	return decl, diags
}
