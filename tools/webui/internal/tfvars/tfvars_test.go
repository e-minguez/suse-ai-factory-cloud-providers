package tfvars

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"
)

var attacks = []string{
	`plain`,
	`with "quotes" and \ backslash`,
	`${var.x} and ${file("/etc/passwd")}`,
	`%{ if true }x%{ endif }`,
	"line1\nline2\r\nline3\ttab",
	"EOT\nEOF\n<<EOT",
	"héllo wörld 日本語 🙂 ‮ rtl",
	`$${escaped} %%{escaped}`,
	"ctrl \x01 \x1f end",
	`# not a comment // nor this`,
	`}` + "\n" + `injected = "x"`,
	``,
	`a"; b = "c`,
}

func TestRoundTripAttackStrings(t *testing.T) {
	p := filepath.Join(t.TempDir(), "terraform.tfvars")
	for i, s := range attacks {
		vals := map[string]any{
			"s":    s,
			"list": []any{s, "x"},
			"obj":  map[string]any{"gpu": map[string]any{"instance_type": s, "count": float64(2)}},
			"tags": map[string]any{s + "k": s},
		}
		if err := Write(p, vals, nil); err != nil {
			t.Fatalf("#%d write: %v", i, err)
		}
		b, _ := os.ReadFile(p)
		if _, d := hclsyntax.ParseConfig(b, p, hcl.InitialPos); d.HasErrors() {
			t.Fatalf("#%d does not parse: %v\n%s", i, d, b)
		}
		got, err := Read(p)
		if err != nil {
			t.Fatalf("#%d read: %v\n%s", i, err, b)
		}
		if !reflect.DeepEqual(got["s"], s) || !reflect.DeepEqual(got["list"], vals["list"]) ||
			!reflect.DeepEqual(got["obj"], vals["obj"]) || !reflect.DeepEqual(got["tags"], vals["tags"]) {
			t.Errorf("#%d round trip mismatch for %q: %#v\n%s", i, s, got, b)
		}
		// Must be a single attribute set: no injected extras.
		if len(got) != 4 {
			t.Errorf("#%d: %d attributes, want 4", i, len(got))
		}
	}
}

func TestWriteKeepsCommentsAndOthers(t *testing.T) {
	p := filepath.Join(t.TempDir(), "terraform.tfvars")
	orig := "# header\nregion = \"ams\" # inline\n\nmanual = [\"a\", \"b\"]\n# keep me\ncluster_name = \"old\"\n"
	if err := os.WriteFile(p, []byte(orig), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Write(p, map[string]any{"cluster_name": "new", "control_plane_count": 3, "region": "ams"}, []string{"manual", "absent"}); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p)
	s := string(b)
	for _, want := range []string{"# header", "# inline", "# keep me", `cluster_name`, `"new"`, "control_plane_count"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in\n%s", want, s)
		}
	}
	if strings.Contains(s, "manual") {
		t.Errorf("manual not removed:\n%s", s)
	}
	st, _ := os.Stat(p)
	if st.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", st.Mode())
	}
	m, _ := Read(p)
	if m["control_plane_count"] != float64(3) || m["cluster_name"] != "new" {
		t.Errorf("read %#v", m)
	}
}

func TestUnchangedValueUntouched(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x.tfvars")
	orig := "region   =   \"ams\"  # odd spacing kept? no, fmt\nn = 1.0\n"
	_ = os.WriteFile(p, []byte(orig), 0o600)
	if err := Write(p, map[string]any{"n": float64(1)}, nil); err != nil {
		t.Fatal(err)
	}
	m, _ := Read(p)
	if m["n"] != float64(1) || m["region"] != "ams" {
		t.Errorf("%#v", m)
	}
}

func TestWriteRejectsInvalidExisting(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x.tfvars")
	_ = os.WriteFile(p, []byte("this is = = broken"), 0o600)
	if err := Write(p, map[string]any{"a": "b"}, nil); err == nil {
		t.Fatal("want error")
	}
	if b, _ := os.ReadFile(p); string(b) != "this is = = broken" {
		t.Error("file modified")
	}
}

func TestReadMissingAndNonLiteral(t *testing.T) {
	d := t.TempDir()
	m, err := Read(filepath.Join(d, "none"))
	if err != nil || len(m) != 0 {
		t.Fatalf("%v %v", m, err)
	}
	p := filepath.Join(d, "f")
	_ = os.WriteFile(p, []byte("a = var.x\n"), 0o600)
	if _, err := Read(p); err == nil {
		t.Error("non-literal accepted")
	}
}

func TestSetComment(t *testing.T) {
	p := filepath.Join(t.TempDir(), "t.tfvars")
	_ = os.WriteFile(p, []byte("a = 1\nssh_authorized_keys = [\n  \"k1\",\n]\nb = 2\n"), 0o600)
	if err := SetComment(p, "ssh_authorized_keys", "# from github.com/alice.keys"); err != nil {
		t.Fatal(err)
	}
	if err := SetComment(p, "ssh_authorized_keys", "# from github.com/bob.keys\n# from github.com/carol.keys"); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p)
	s := string(b)
	if strings.Contains(s, "alice") || strings.Count(s, "# from github.com/") != 2 {
		t.Errorf("comments wrong:\n%s", s)
	}
	if !strings.Contains(s, "carol.keys\nssh_authorized_keys") {
		t.Errorf("comment not above attribute:\n%s", s)
	}
	if err := Write(p, map[string]any{"ssh_authorized_keys": []any{"k2"}}, nil); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(p)
	if strings.Count(string(b), "# from github.com/") != 2 {
		t.Errorf("comment lost on write:\n%s", b)
	}
	if err := SetComment(p, "ssh_authorized_keys", ""); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(p)
	if strings.Contains(string(b), "github.com") {
		t.Errorf("comment not removed:\n%s", b)
	}
	if err := SetComment(p, "nope", "# x"); err == nil {
		t.Error("missing attribute accepted")
	}
	if m, _ := Read(p); m["b"] != float64(2) || !reflect.DeepEqual(m["ssh_authorized_keys"], []any{"k2"}) {
		t.Errorf("%#v", m)
	}
}

func TestEffective(t *testing.T) {
	d := t.TempDir()
	_ = os.MkdirAll(filepath.Join(d, "c1"), 0o700)
	_ = Write(Path(d, "aws", "c1", LayerCommonAll), map[string]any{"a": "all", "b": "all", "c": "all"}, nil)
	_ = Write(Path(d, "aws", "c1", LayerCommonProvider), map[string]any{"b": "prov", "c": "prov"}, nil)
	_ = Write(Path(d, "aws", "c1", LayerCluster), map[string]any{"c": "cluster"}, nil)
	m, err := Effective(d, "aws", "c1")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"a": "all", "b": "prov", "c": "cluster"}
	if !reflect.DeepEqual(m, want) {
		t.Errorf("%v", m)
	}
}
