package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

func TestWithEscapes(t *testing.T) {
	got := withEscapes([]string{"short", "p\"a&s<s\\w", "p\"a&s<s\\w"})
	set := map[string]bool{}
	for _, g := range got {
		if set[g] {
			t.Fatalf("duplicate %q", g)
		}
		set[g] = true
	}
	for _, want := range []string{`p"a&s<s\w`, `p\"a&s<s\\w`, `p\"a&s<s\\w`} {
		if !set[want] {
			t.Errorf("missing %q in %v", want, got)
		}
	}
	if set["short"] {
		t.Error("secrets under 6 chars must be skipped")
	}
}

func TestRedactorCollect(t *testing.T) {
	repo := t.TempDir()
	w := func(p, s string) {
		p = filepath.Join(repo, p)
		_ = os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	w("examples/vultr/deploy.sh", "")
	w("examples/vultr/variables.tf", `variable "vultr_api_key" {
  type      = string
  sensitive = true
}
variable "cluster_name" {
  type    = string
  default = "x"
}
`)
	w("tools/webui/ui.yaml", "common: {}\n")
	w("common-all.tfvars", "vultr_api_key = \"root-layer-secret\"\n")
	w("clusters/c1/.provider", "vultr\n")
	r := &redactor{repo: repo, clusters: filepath.Join(repo, "clusters"), ws: workspace.New(repo)}
	out := r.Redact("key=root-layer-secret in {\"k\":\"root-layer-secret\"} and cluster x")
	if strings.Contains(out, "root-layer-secret") || !strings.Contains(out, "cluster x") {
		t.Fatalf("%q", out)
	}
}
