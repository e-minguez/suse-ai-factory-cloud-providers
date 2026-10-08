// Package tfvars reads and edits the tfvars layers with hclwrite, keeping
// comments and unrelated attributes untouched.
package tfvars

import (
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/hashicorp/hcl/v2/hclwrite"
	"github.com/zclconf/go-cty/cty"
)

// Layer is one tfvars file in the merge order.
type Layer int

const (
	LayerCommonAll Layer = iota
	LayerCommonProvider
	LayerCluster
)

// ErrNoAttribute is returned by SetComment for an attribute not in the file.
var ErrNoAttribute = errors.New("attribute not found")

// Path returns the file of layer l.
func Path(clustersDir, provider, cluster string, l Layer) string {
	switch l {
	case LayerCommonAll:
		return filepath.Join(clustersDir, "common-all.tfvars")
	case LayerCommonProvider:
		return filepath.Join(clustersDir, "common-"+provider+".tfvars")
	}
	return filepath.Join(clustersDir, cluster, "terraform.tfvars")
}

// Read parses path into Go values (string, bool, float64, []any,
// map[string]any, nil). A missing file is an empty map.
func Read(path string) (map[string]any, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, err
	}
	return parse(b, path)
}

func parse(b []byte, name string) (map[string]any, error) {
	f, diags := hclsyntax.ParseConfig(b, name, hcl.InitialPos)
	if diags.HasErrors() {
		return nil, fmt.Errorf("%s: %w", filepath.Base(name), diags)
	}
	attrs, diags := f.Body.JustAttributes()
	if diags.HasErrors() {
		return nil, fmt.Errorf("%s: %w", filepath.Base(name), diags)
	}
	out := make(map[string]any, len(attrs))
	for n, a := range attrs {
		v, diags := a.Expr.Value(nil)
		if diags.HasErrors() {
			return nil, fmt.Errorf("%s: %s is not a literal value", filepath.Base(name), n)
		}
		out[n] = fromCty(v)
	}
	return out, nil
}

// Write sets values and deletes the names in remove, editing path in place.
// Attributes whose value is unchanged are not touched. The file is replaced
// atomically with mode 600.
func Write(path string, values map[string]any, remove []string) error {
	src, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	cur, err := parse(src, path)
	if err != nil {
		return err
	}
	f, diags := hclwrite.ParseConfig(src, path, hcl.InitialPos)
	if diags.HasErrors() {
		return fmt.Errorf("%s: %w", filepath.Base(path), diags)
	}
	body := f.Body()
	for _, n := range remove {
		body.RemoveAttribute(n)
	}
	names := make([]string, 0, len(values))
	for n := range values {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		if old, ok := cur[n]; ok && reflect.DeepEqual(normalize(old), normalize(values[n])) {
			continue
		}
		v, err := toCty(values[n])
		if err != nil {
			return fmt.Errorf("%s: %w", n, err)
		}
		body.SetAttributeValue(n, v)
	}
	return writeAtomic(path, hclwrite.Format(f.Bytes()))
}

// SetComment puts comment (one or more "# ..." lines) above attribute name,
// replacing a previous "# from github.com/" block. Empty comment removes it.
func SetComment(path, name, comment string) error {
	src, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	f, diags := hclsyntax.ParseConfig(src, path, hcl.InitialPos)
	if diags.HasErrors() {
		return fmt.Errorf("%s: %w", filepath.Base(path), diags)
	}
	attrs, _ := f.Body.(*hclsyntax.Body)
	a, ok := attrs.Attributes[name]
	if !ok {
		return fmt.Errorf("%s: %w", name, ErrNoAttribute)
	}
	lines := strings.Split(string(src), "\n")
	at := a.NameRange.Start.Line - 1
	start := at
	for start > 0 && strings.HasPrefix(strings.TrimSpace(lines[start-1]), "# from github.com/") {
		start--
	}
	var ins []string
	for _, l := range strings.Split(strings.TrimSpace(comment), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			if !strings.HasPrefix(l, "#") {
				l = "# " + l
			}
			ins = append(ins, l)
		}
	}
	out := append(append(append([]string{}, lines[:start]...), ins...), lines[at:]...)
	return writeAtomic(path, []byte(strings.Join(out, "\n")))
}

// Effective merges common-all, common-<provider> and the cluster layer;
// later layers win per top-level name.
func Effective(clustersDir, provider, cluster string) (map[string]any, error) {
	out := map[string]any{}
	for _, l := range []Layer{LayerCommonAll, LayerCommonProvider, LayerCluster} {
		m, err := Read(Path(clustersDir, provider, cluster, l))
		if err != nil {
			return nil, err
		}
		for k, v := range m {
			out[k] = v
		}
	}
	return out, nil
}

func writeAtomic(path string, b []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tfvars-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// normalize maps Go values onto the types Read returns, for comparison.
func normalize(v any) any {
	c, err := toCty(v)
	if err != nil {
		return v
	}
	return fromCty(c)
}

func toCty(v any) (cty.Value, error) {
	switch t := v.(type) {
	case nil:
		return cty.NullVal(cty.DynamicPseudoType), nil
	case string:
		return cty.StringVal(t), nil
	case bool:
		return cty.BoolVal(t), nil
	case int:
		return cty.NumberIntVal(int64(t)), nil
	case int64:
		return cty.NumberIntVal(t), nil
	case float64:
		return cty.NumberVal(new(big.Float).SetFloat64(t)), nil
	case []string:
		a := make([]any, len(t))
		for i, s := range t {
			a[i] = s
		}
		return toCty(a)
	case map[string]string:
		m := make(map[string]any, len(t))
		for k, s := range t {
			m[k] = s
		}
		return toCty(m)
	case []any:
		vs := make([]cty.Value, len(t))
		for i, e := range t {
			c, err := toCty(e)
			if err != nil {
				return cty.NilVal, err
			}
			vs[i] = c
		}
		if len(vs) == 0 {
			return cty.EmptyTupleVal, nil
		}
		return cty.TupleVal(vs), nil
	case map[string]any:
		vs := make(map[string]cty.Value, len(t))
		for k, e := range t {
			c, err := toCty(e)
			if err != nil {
				return cty.NilVal, err
			}
			vs[k] = c
		}
		if len(vs) == 0 {
			return cty.EmptyObjectVal, nil
		}
		return cty.ObjectVal(vs), nil
	}
	return cty.NilVal, fmt.Errorf("unsupported value type %T", v)
}

func fromCty(v cty.Value) any {
	if v.IsNull() || !v.IsKnown() {
		return nil
	}
	t := v.Type()
	switch {
	case t == cty.String:
		return v.AsString()
	case t == cty.Bool:
		return v.True()
	case t == cty.Number:
		f, _ := v.AsBigFloat().Float64()
		return f
	case t.IsListType() || t.IsTupleType() || t.IsSetType():
		out := []any{}
		for it := v.ElementIterator(); it.Next(); {
			_, e := it.Element()
			out = append(out, fromCty(e))
		}
		return out
	case t.IsMapType() || t.IsObjectType():
		out := map[string]any{}
		for it := v.ElementIterator(); it.Next(); {
			k, e := it.Element()
			out[k.AsString()] = fromCty(e)
		}
		return out
	}
	return nil
}

// Comments returns the "# ..." lines directly above attribute name.
func Comments(path, name string) []string {
	src, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	f, diags := hclsyntax.ParseConfig(src, path, hcl.InitialPos)
	if diags.HasErrors() {
		return nil
	}
	body, _ := f.Body.(*hclsyntax.Body)
	a, ok := body.Attributes[name]
	if !ok {
		return nil
	}
	lines := strings.Split(string(src), "\n")
	var out []string
	for i := a.NameRange.Start.Line - 2; i >= 0 && strings.HasPrefix(strings.TrimSpace(lines[i]), "#"); i-- {
		out = append([]string{strings.TrimSpace(lines[i])}, out...)
	}
	return out
}
