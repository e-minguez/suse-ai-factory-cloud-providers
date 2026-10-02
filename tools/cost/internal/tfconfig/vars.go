package tfconfig

import (
	"fmt"

	"github.com/zclconf/go-cty/cty"
	"github.com/zclconf/go-cty/cty/gocty"
)

// Vars resolves variables by name from, in order: overrides (CLI flags), the
// layered tfvars, the variable's own declared default. It is the only way
// code outside this package reads a tfvars value, and it hands back typed Go
// values only -- never a cty.Value -- so credentials, which nothing asks for
// by name, never leave the package. Problems accumulate in Diagnostics().
type Vars struct {
	decls     map[string]*VariableDecl
	tfvars    map[string]TFVarValue
	overrides map[string]string
	diags     []Diagnostic
}

// NewVars wraps already-parsed declarations and tfvars. Every tfvars key not
// declared in decls becomes a warning (name only, never the value).
func NewVars(decls map[string]*VariableDecl, tfvars map[string]TFVarValue, overrides map[string]string) *Vars {
	v := &Vars{decls: decls, tfvars: tfvars, overrides: overrides}
	for name, tv := range tfvars {
		if _, ok := decls[name]; !ok {
			r := tv.Range
			v.diags = append(v.diags, Diagnostic{
				Severity: SeverityWarning,
				Summary:  fmt.Sprintf("tfvars sets %q, which is not declared in the module's variables", name),
				Subject:  &r,
			})
		}
	}
	return v
}

// Diagnostics returns every diagnostic collected so far, warnings included.
func (v *Vars) Diagnostics() []Diagnostic { return v.diags }

func (v *Vars) addErr(format string, args ...any) {
	v.diags = append(v.diags, Diagnostic{Severity: SeverityError, Summary: fmt.Sprintf(format, args...)})
}

// value resolves name. ok is false when it has neither a value nor a
// default; ok with a null value means the variable is explicitly null.
func (v *Vars) value(name string) (cty.Value, bool) {
	val, ok, d := resolveValue(v.decls, v.tfvars, v.overrides, name)
	v.diags = append(v.diags, d...)
	return val, ok
}

// IsSet reports whether name resolves to a non-null value.
func (v *Vars) IsSet(name string) bool {
	val, ok := v.value(name)
	return ok && !val.IsNull()
}

// String returns the string value of name, or "" when unset or null.
func (v *Vars) String(name string) string {
	val, ok := v.value(name)
	if !ok || val.IsNull() {
		return ""
	}
	var s string
	if err := gocty.FromCtyValue(val, &s); err != nil {
		v.addErr("variable %q: expected a string", name)
	}
	return s
}

// Bool returns the bool value of name, or false when unset or null.
func (v *Vars) Bool(name string) bool {
	val, ok := v.value(name)
	if !ok || val.IsNull() {
		return false
	}
	var b bool
	if err := gocty.FromCtyValue(val, &b); err != nil {
		v.addErr("variable %q: expected a bool", name)
	}
	return b
}

// Int returns the whole-number value of name, or 0 when unset or null.
func (v *Vars) Int(name string) int {
	val, ok := v.value(name)
	if !ok || val.IsNull() {
		return 0
	}
	var n int
	if err := gocty.FromCtyValue(val, &n); err != nil {
		v.addErr("variable %q: expected a whole number", name)
	}
	return n
}

// OptFloat returns the number value of name, or nil when unset or null.
func (v *Vars) OptFloat(name string) *float64 {
	val, ok := v.value(name)
	if !ok || val.IsNull() {
		return nil
	}
	var f float64
	if err := gocty.FromCtyValue(val, &f); err != nil {
		v.addErr("variable %q: expected a number", name)
		return nil
	}
	return &f
}

// StringList returns the list(string) value of name; nil when unset or null.
func (v *Vars) StringList(name string) []string {
	val, ok := v.value(name)
	if !ok || val.IsNull() {
		return nil
	}
	var out []string
	if err := gocty.FromCtyValue(val, &out); err != nil {
		v.addErr("variable %q: expected a list of strings", name)
		return nil
	}
	return out
}

// require records an error when name has neither a value nor a default.
func (v *Vars) require(name string) {
	if _, ok := v.value(name); !ok {
		v.addErr("variable %q could not be resolved: no value in the tfvars and no default in the module", name)
	}
}
