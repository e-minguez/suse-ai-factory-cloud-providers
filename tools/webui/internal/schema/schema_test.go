package schema

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/hashicorp/terraform-config-inspect/tfconfig"
)

// repoRoot walks up to the repository root (examples/ and tools/webui/).
func repoRoot(t *testing.T) string {
	t.Helper()
	d, _ := os.Getwd()
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(d, "examples")); err == nil {
			return d
		}
		d = filepath.Dir(d)
	}
	t.Fatal("repo root not found")
	return ""
}

func TestProviders(t *testing.T) {
	got := Providers(repoRoot(t))
	if len(got) != 4 {
		t.Fatalf("providers = %v", got)
	}
}

func TestLoadAll(t *testing.T) {
	root := repoRoot(t)
	for _, p := range Providers(root) {
		fs, err := Load(root, p)
		if err != nil {
			t.Fatalf("%s: %v", p, err)
		}
		if len(fs) < 30 {
			t.Errorf("%s: only %d fields", p, len(fs))
		}
		for i, f := range fs {
			if f.Order != i || f.Widget == "" || f.Label == "" {
				t.Errorf("%s/%s: bad field %+v", p, f.Name, f)
			}
			if !f.Managed && !f.Basic && f.Group == "" {
				t.Errorf("%s/%s: no group", p, f.Name)
			}
			if f.Required == f.HasDefault {
				t.Errorf("%s/%s: required/default mismatch", p, f.Name)
			}
		}
	}
}

// CI rule: every variable without default is basic or a credential.
func TestRequiredAreBasicOrCredential(t *testing.T) {
	root := repoRoot(t)
	for _, p := range Providers(root) {
		fs, _ := Load(root, p)
		for _, f := range fs {
			if f.Required && !f.Basic && !IsCredential(f.Name) {
				t.Errorf("%s: %s has no default and is not basic", p, f.Name)
			}
			if IsCredential(f.Name) && !f.Managed {
				t.Errorf("%s: credential %s must be managed", p, f.Name)
			}
		}
	}
}

// CI rule: every ui.yaml name exists; managed is disjoint from shown.
func TestUINamesExistAndManagedDisjoint(t *testing.T) {
	root := repoRoot(t)
	ui, err := LoadUI(root)
	if err != nil {
		t.Fatal(err)
	}
	vars := map[string]map[string]bool{}
	any := map[string]bool{}
	for _, p := range Providers(root) {
		vars[p] = map[string]bool{}
		mod, _ := loadVars(root, p)
		for n := range mod {
			vars[p][n], any[n] = true, true
		}
	}
	check := func(where string, s *section, known func(string) bool) {
		shown := map[string]bool{}
		for _, e := range s.Basic {
			if !known(e.Name) {
				t.Errorf("%s: basic %q does not exist", where, e.Name)
			}
			if shown[e.Name] {
				t.Errorf("%s: %q listed twice", where, e.Name)
			}
			shown[e.Name] = true
		}
		for _, g := range s.groups {
			for _, e := range g.Names {
				if !known(e.Name) {
					t.Errorf("%s: group %s name %q does not exist", where, g.Title, e.Name)
				}
				if shown[e.Name] {
					t.Errorf("%s: %q placed twice", where, e.Name)
				}
				shown[e.Name] = true
			}
		}
		for n := range s.Examples {
			if !known(n) {
				t.Errorf("%s: example %q does not exist", where, n)
			}
		}
		for _, m := range s.Managed {
			if !known(m) {
				t.Errorf("%s: managed %q does not exist", where, m)
			}
			if shown[m] {
				t.Errorf("%s: %q is managed and shown", where, m)
			}
		}
	}
	check("common", &ui.Common, func(n string) bool { return any[n] })
	for p, s := range ui.Providers {
		if vars[p] == nil {
			t.Errorf("ui.yaml section %q is not a provider", p)
			continue
		}
		check(p, s, func(n string) bool { return vars[p][n] })
	}
	// Cross-section: a provider must not show what common manages, or vice versa.
	for p, s := range ui.Providers {
		shown := map[string]bool{}
		for _, e := range s.Basic {
			shown[e.Name] = true
		}
		for _, g := range s.groups {
			for _, e := range g.Names {
				shown[e.Name] = true
			}
		}
		for _, m := range ui.Common.Managed {
			if shown[m] {
				t.Errorf("%s shows %q, managed in common", p, m)
			}
		}
	}
}

func TestMergeDetails(t *testing.T) {
	root := repoRoot(t)
	fs, _ := Load(root, "exoscale")
	by := map[string]Field{}
	for _, f := range fs {
		by[f.Name] = f
	}
	if r := by["region"]; r.Widget != "select" || !r.Basic || len(r.Options) == 0 || r.Default != "de-fra-1" {
		t.Errorf("region = %+v", r)
	}
	if by["control_plane_count"].Default != float64(3) {
		t.Errorf("number default = %#v", by["control_plane_count"].Default)
	}
	if f := by["nvidia_api_key"]; !f.Collapsed || !f.Sensitive || f.Widget != "password" {
		t.Errorf("nvidia_api_key = %+v", f)
	}
	if f := by["gpu_pools"]; f.Widget != "gpu_pool" || f.Type[:3] != "map" {
		t.Errorf("gpu_pools = %+v", f)
	}
	if !by["cp_initialized"].Managed || by["cp_initialized"].Basic {
		t.Error("cp_initialized should be managed")
	}
	if by["tags"].Group != "Tags" || by["tags"].Widget != "json" {
		t.Errorf("tags = %+v", by["tags"])
	}
	if _, err := Load(root, "nope"); err == nil {
		t.Error("unknown provider accepted")
	}
}

// loadVars returns the variables of examples/<provider> (used by tests).
func loadVars(repoRoot, provider string) (map[string]*tfconfig.Variable, error) {
	mod, diags := tfconfig.LoadModule(filepath.Join(repoRoot, "examples", provider))
	if diags.HasErrors() {
		return nil, diags.Err()
	}
	return mod.Variables, nil
}
