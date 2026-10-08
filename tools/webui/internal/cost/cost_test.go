package cost

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fake(t *testing.T, script string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "cost")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func setup(t *testing.T) (repo, cl string) {
	repo = t.TempDir()
	cl = filepath.Join(repo, "clusters")
	_ = os.MkdirAll(filepath.Join(cl, "c1"), 0o700)
	_ = os.WriteFile(filepath.Join(cl, "c1", ".provider"), []byte("vultr\n"), 0o600)
	_ = os.WriteFile(filepath.Join(cl, "common-all.tfvars"), nil, 0o600)
	_ = os.WriteFile(filepath.Join(cl, "c1", "terraform.tfvars"), nil, 0o600)
	return
}

func TestRunArgsAndJSON(t *testing.T) {
	repo, cl := setup(t)
	// Echo the args as JSON so the test can inspect them.
	bin := fake(t, `printf '{"args":"%s"}' "$*"`)
	out, err := Run(context.Background(), bin, repo, cl, "c1", nil)
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	i1 := strings.Index(s, "common-all.tfvars")
	i2 := strings.Index(s, "c1/terraform.tfvars")
	if !strings.Contains(s, "--provider vultr --json") || i1 < 0 || i2 < i1 || strings.Contains(s, "common-vultr") {
		t.Errorf("args: %s", s)
	}
}

func TestRunErrors(t *testing.T) {
	repo, cl := setup(t)
	bin := fake(t, "echo 'region is required' >&2; exit 3")
	_, err := Run(context.Background(), bin, repo, cl, "c1", nil)
	var ce *Error
	if !errors.As(err, &ce) || ce.Code != 3 || !strings.Contains(ce.Detail, "region is required") {
		t.Errorf("err = %v", err)
	}
	if _, err := Run(context.Background(), fake(t, "echo notjson"), repo, cl, "c1", nil); err == nil {
		t.Error("invalid JSON accepted")
	}
	if _, err := Run(context.Background(), bin, repo, cl, "nope", nil); err == nil {
		t.Error("unknown cluster accepted")
	}
	if _, err := Run(context.Background(), "/nonexistent/cost", repo, cl, "c1", nil); err == nil {
		t.Error("missing binary accepted")
	}
}
