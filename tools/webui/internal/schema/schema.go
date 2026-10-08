// Package schema merges examples/<provider>/variables.tf with ui.yaml into
// the field list the forms render.
package schema

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/hashicorp/terraform-config-inspect/tfconfig"
	"gopkg.in/yaml.v3"
)

// Field is one input variable with its form metadata. Widget is always
// filled (inferred from the type when ui.yaml gives none).
type Field struct {
	Name, Type, Description string
	Default                 any
	HasDefault              bool
	Sensitive               bool
	Required                bool
	Basic                   bool
	Collapsed               bool // basic, shown in the collapsed optional block
	Group                   string
	Order                   int
	Widget                  string
	Options                 []string
	Managed                 bool
	Label, Help             string
	Example                 string // sample value from ui.yaml (json widgets)
}

// FallbackGroup holds variables ui.yaml does not place.
const FallbackGroup = "Advanced"

// credentialVars are required variables the account profile page owns.
var credentialVars = map[string]bool{"vultr_api_key": true, "exoscale_api_key": true, "exoscale_api_secret": true}

// IsCredential reports whether name is a provider credential variable.
func IsCredential(name string) bool { return credentialVars[name] }

// entry is one ui.yaml name; it unmarshals from a scalar or a mapping.
type entry struct {
	Name      string   `yaml:"name"`
	Label     string   `yaml:"label"`
	Widget    string   `yaml:"widget"`
	Options   []string `yaml:"options"`
	Collapsed bool     `yaml:"collapsed"`
}

func (e *entry) UnmarshalYAML(n *yaml.Node) error {
	if n.Kind == yaml.ScalarNode {
		e.Name = n.Value
		return nil
	}
	type plain entry
	return n.Decode((*plain)(e))
}

type groupDef struct {
	Title string
	Names []entry
}

type section struct {
	Basic    []entry           `yaml:"basic"`
	Groups   yaml.Node         `yaml:"groups"`
	Managed  []string          `yaml:"managed"`
	Examples map[string]string `yaml:"examples"` // name -> sample value; provider wins
	groups   []groupDef        // decoded from Groups, order kept
}

// UI is the parsed ui.yaml.
type UI struct {
	Common    section
	Providers map[string]*section
}

func (s *section) decodeGroups() error {
	g := &s.Groups
	if g.Kind == 0 {
		return nil
	}
	if g.Kind != yaml.MappingNode {
		return fmt.Errorf("groups must be a mapping")
	}
	for i := 0; i+1 < len(g.Content); i += 2 {
		gd := groupDef{Title: g.Content[i].Value}
		if err := g.Content[i+1].Decode(&gd.Names); err != nil {
			return fmt.Errorf("group %q: %w", gd.Title, err)
		}
		s.groups = append(s.groups, gd)
	}
	return nil
}

// LoadUI parses <repoRoot>/tools/webui/ui.yaml.
func LoadUI(repoRoot string) (*UI, error) {
	b, err := os.ReadFile(filepath.Join(repoRoot, "tools", "webui", "ui.yaml"))
	if err != nil {
		return nil, err
	}
	var raw map[string]*section
	if err := yaml.Unmarshal(b, &raw); err != nil {
		return nil, fmt.Errorf("ui.yaml: %w", err)
	}
	ui := &UI{Providers: map[string]*section{}}
	for k, s := range raw {
		if s == nil {
			s = &section{}
		}
		if err := s.decodeGroups(); err != nil {
			return nil, fmt.Errorf("ui.yaml %s: %w", k, err)
		}
		if k == "common" {
			ui.Common = *s
		} else {
			ui.Providers[k] = s
		}
	}
	return ui, nil
}

// Providers lists examples/*/ that ship a deploy.sh, sorted.
func Providers(repoRoot string) []string {
	m, _ := filepath.Glob(filepath.Join(repoRoot, "examples", "*", "deploy.sh"))
	out := make([]string, 0, len(m))
	for _, p := range m {
		out = append(out, filepath.Base(filepath.Dir(p)))
	}
	sort.Strings(out)
	return out
}

// Load returns the provider's fields: basic first (ui.yaml order), then
// groups (ui.yaml order), then unplaced variables in source order.
// Managed fields are included with Managed set so callers can skip them.
func Load(repoRoot, provider string) ([]Field, error) {
	dir := filepath.Join(repoRoot, "examples", provider)
	if _, err := os.Stat(filepath.Join(dir, "variables.tf")); err != nil {
		return nil, fmt.Errorf("unknown provider %q", provider)
	}
	mod, diags := tfconfig.LoadModule(dir)
	if diags.HasErrors() {
		return nil, fmt.Errorf("%s: %w", dir, diags.Err())
	}
	ui, err := LoadUI(repoRoot)
	if err != nil {
		return nil, err
	}
	return merge(mod, ui, provider), nil
}

type placed struct {
	entry
	group     string
	collapsed bool
}

func merge(mod *tfconfig.Module, ui *UI, provider string) []Field {
	secs := []*section{&ui.Common}
	if ps := ui.Providers[provider]; ps != nil {
		secs = append(secs, ps)
	}
	managed := map[string]bool{}
	examples := map[string]string{}
	var basic []placed
	var groups []string
	gmap := map[string][]entry{}
	for _, s := range secs {
		for _, m := range s.Managed {
			managed[m] = true
		}
		for n, ex := range s.Examples {
			examples[n] = strings.TrimSpace(ex)
		}
		for _, e := range s.Basic {
			replaced := false
			for i := range basic {
				if basic[i].Name == e.Name {
					basic[i].entry, basic[i].collapsed = overlay(basic[i].entry, e), e.Collapsed || basic[i].collapsed
					replaced = true
				}
			}
			if !replaced {
				basic = append(basic, placed{entry: e, collapsed: e.Collapsed})
			}
		}
		for _, g := range s.groups {
			if _, ok := gmap[g.Title]; !ok {
				groups = append(groups, g.Title)
			}
			gmap[g.Title] = append(gmap[g.Title], g.Names...)
		}
	}
	var out []Field
	seen := map[string]bool{}
	add := func(p placed, basicField bool) {
		v := mod.Variables[p.Name]
		if v == nil || seen[p.Name] {
			return
		}
		seen[p.Name] = true
		out = append(out, newField(v, p, basicField, managed[p.Name], len(out)))
		out[len(out)-1].Example = examples[p.Name]
	}
	for _, p := range basic {
		add(p, true)
	}
	for _, t := range groups {
		for _, e := range gmap[t] {
			add(placed{entry: e, group: t}, false)
		}
	}
	var rest []*tfconfig.Variable
	for n, v := range mod.Variables {
		if !seen[n] {
			rest = append(rest, v)
		}
	}
	sort.Slice(rest, func(i, j int) bool {
		a, b := rest[i].Pos, rest[j].Pos
		if a.Filename != b.Filename {
			return a.Filename < b.Filename
		}
		return a.Line < b.Line
	})
	for _, v := range rest {
		add(placed{entry: entry{Name: v.Name}, group: FallbackGroup}, false)
	}
	// Managed variables never show: drop them from the group order.
	for i := range out {
		if out[i].Managed {
			out[i].Basic, out[i].Group = false, ""
		}
	}
	return out
}

func overlay(base, e entry) entry {
	if e.Label != "" {
		base.Label = e.Label
	}
	if e.Widget != "" {
		base.Widget = e.Widget
	}
	if e.Options != nil {
		base.Options = e.Options
	}
	return base
}

func newField(v *tfconfig.Variable, p placed, basic, managed bool, order int) Field {
	f := Field{
		Name:        v.Name,
		Type:        strings.TrimSpace(v.Type),
		Description: v.Description,
		Default:     normalize(v.Default),
		HasDefault:  !v.Required,
		Sensitive:   v.Sensitive,
		Required:    v.Required,
		Basic:       basic,
		Collapsed:   basic && p.collapsed,
		Group:       p.group,
		Order:       order,
		Widget:      p.Widget,
		Options:     p.Options,
		Managed:     managed,
		Label:       p.Label,
		Help:        v.Description,
	}
	if f.Type == "" {
		f.Type = "string"
	}
	if f.Label == "" {
		f.Label = f.Name
	}
	if f.Widget == "" {
		f.Widget = inferWidget(f)
	}
	return f
}

func inferWidget(f Field) string {
	switch {
	case f.Type == "bool":
		return "bool"
	case f.Type == "number":
		return "number"
	case f.Type == "list(string)":
		return "list"
	case f.Type == "string" && len(f.Options) > 0:
		return "select"
	case f.Type == "string" && f.Sensitive:
		return "password"
	case f.Type == "string":
		return "text"
	}
	return "json"
}

// normalize turns decoded numbers into float64, recursively.
func normalize(v any) any {
	switch t := v.(type) {
	case int:
		return float64(t)
	case int64:
		return float64(t)
	case []any:
		for i := range t {
			t[i] = normalize(t[i])
		}
	case map[string]any:
		for k := range t {
			t[k] = normalize(t[k])
		}
	}
	return v
}
