package workspace

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, path, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(s), 0o755); err != nil {
		t.Fatal(err)
	}
}

func fakeRepo(t *testing.T) *Workspace {
	repo := t.TempDir()
	write(t, filepath.Join(repo, "examples/aws/deploy.sh"), "")
	write(t, filepath.Join(repo, "examples/vultr/deploy.sh"), "")
	write(t, filepath.Join(repo, "examples/notaprovider/main.tf"), "")
	write(t, filepath.Join(repo, "tools/multicluster/cluster.sh"), `#!/bin/sh
[ "$1" = new ] && [ "$2" = --empty ] || exit 2
d="$(dirname "$0")/../../clusters/$4"
mkdir -p "$d" && echo "$3" > "$d/.provider"
`)
	return New(repo)
}

func TestValidName(t *testing.T) {
	for n, want := range map[string]bool{
		"a": true, "my-cluster1": true, "": false, "1a": false, "A": false,
		"a_b": false, "-a": false, "a/b": false, "..": false,
		fmt.Sprintf("a%0*d", 62, 0): true, fmt.Sprintf("a%0*d", 63, 0): false,
	} {
		if ValidName(n) != want {
			t.Errorf("ValidName(%q) != %v", n, want)
		}
	}
}

func TestProvidersCreateList(t *testing.T) {
	w := fakeRepo(t)
	if got := w.Providers(); len(got) != 2 || got[0] != "aws" || got[1] != "vultr" {
		t.Fatalf("providers %v", got)
	}
	if l, err := w.List(); err != nil || len(l) != 0 {
		t.Fatalf("empty list: %v %v", l, err)
	}
	ctx := context.Background()
	c, err := w.Create(ctx, "aws", "demo")
	if err != nil || c.Provider != "aws" || c.Status != StatusNoState {
		t.Fatalf("create: %+v %v", c, err)
	}
	if _, err := w.Create(ctx, "aws", "demo"); err != ErrExists {
		t.Fatalf("dup: %v", err)
	}
	if _, err := w.Create(ctx, "nope", "x"); err != ErrUnknownProv {
		t.Fatalf("prov: %v", err)
	}
	if _, err := w.Create(ctx, "aws", "../x"); err != ErrInvalidName {
		t.Fatalf("name: %v", err)
	}
	if l, _ := w.List(); len(l) != 1 || l[0].Name != "demo" {
		t.Fatalf("list %v", l)
	}
	if _, err := w.Get("missing"); err != ErrNotFound {
		t.Fatalf("get: %v", err)
	}
}

func TestStatus(t *testing.T) {
	d := t.TempDir()
	if s := Status(d); s != StatusNoState {
		t.Fatal(s)
	}
	write(t, filepath.Join(d, "terraform.tfstate"), `{"resources":[]}`)
	if s := Status(d); s != StatusNoState {
		t.Fatalf("empty resources: %s", s)
	}
	write(t, filepath.Join(d, "terraform.tfstate"), `{"resources":[{"type":"x"}]}`)
	if s := Status(d); s != StatusDeployed {
		t.Fatal(s)
	}
	write(t, filepath.Join(d, ".deploy/webui-last-status"), "failed\n")
	if s := Status(d); s != StatusError {
		t.Fatal(s)
	}
	write(t, filepath.Join(d, ".deploy/webui.lock"), fmt.Sprintf("%d 1 deploy %s\n", os.Getpid(), Instance))
	if s := Status(d); s != StatusRunning {
		t.Fatal(s)
	}
	// Live pid, but written by another instance (earlier container): stale.
	write(t, filepath.Join(d, ".deploy/webui.lock"), fmt.Sprintf("%d 1 deploy other\n", os.Getpid()))
	if s := Status(d); s != StatusError {
		t.Fatalf("other instance: %s", s)
	}
	write(t, filepath.Join(d, ".deploy/webui.lock"), "99999999\n")
	if s := Status(d); s != StatusError {
		t.Fatalf("stale lock: %s", s)
	}
}

func TestProviderValidation(t *testing.T) {
	w := fakeRepo(t)
	for content, ok := range map[string]bool{"aws\n": true, "": false, "Aws": false, "../x": false, "a b": false, "1a": false} {
		write(t, filepath.Join(w.Root, "c1", ".provider"), content)
		_, err := w.Get("c1")
		if (err == nil) != ok {
			t.Errorf("%q: err=%v", content, err)
		}
	}
}

func TestChildEnvDropsWebUI(t *testing.T) {
	t.Setenv("WEBUI_TOKEN", "x")
	t.Setenv("WEBUI_ADDR", "y")
	t.Setenv("KEEP_ME", "1")
	env := ChildEnv([]string{"HOME=/h"})
	var keep, home bool
	for _, kv := range env {
		if len(kv) >= 6 && kv[:6] == "WEBUI_" {
			t.Fatalf("leaked %q", kv)
		}
		keep = keep || kv == "KEEP_ME=1"
		home = home || kv == "HOME=/h"
	}
	if !keep || !home || env[len(env)-1] != "HOME=/h" {
		t.Fatalf("env %v", env)
	}
}

func TestVarsRootLayer(t *testing.T) {
	w := fakeRepo(t)
	write(t, filepath.Join(w.Repo, "common-all.tfvars"), "a = \"root\"\nb = \"root\"\n")
	write(t, filepath.Join(w.Root, "common-all.tfvars"), "b = \"clusters\"\n")
	v, _ := Vars(w.Repo, w.Root, "aws", "c1")
	if v["a"] != "root" || v["b"] != "clusters" {
		t.Fatalf("%v", v)
	}
}
