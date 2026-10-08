// Package cost runs the tools/cost binary for a cluster's tfvars layers.
package cost

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Timeout bounds one run.
const Timeout = 60 * time.Second

// Error is a failed cost run; Code is the exit code (2 config, 3 pricing).
type Error struct {
	Code   int
	Detail string
}

func (e *Error) Error() string {
	if e.Detail == "" {
		return fmt.Sprintf("cost exited with code %d", e.Code)
	}
	return e.Detail
}

// Run executes `cost --json` for the cluster, passing the existing layers
// (common-all, common-<provider>, cluster) in merge order; env is the full child
// environment (nil inherits).
func Run(ctx context.Context, bin, repoRoot, clustersDir, cluster string, env []string) (json.RawMessage, error) {
	pb, err := os.ReadFile(filepath.Join(clustersDir, cluster, ".provider"))
	if err != nil {
		return nil, fmt.Errorf("cluster %q has no provider", cluster)
	}
	provider := strings.TrimSpace(string(pb))
	args := []string{"--provider", provider, "--json", "--repo", repoRoot}
	for _, f := range []string{
		filepath.Join(clustersDir, "common-all.tfvars"),
		filepath.Join(clustersDir, "common-"+provider+".tfvars"),
		filepath.Join(clustersDir, cluster, "terraform.tfvars"),
	} {
		if st, err := os.Stat(f); err == nil && st.Mode().IsRegular() {
			args = append(args, "--var-file", f)
		}
	}
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Dir = repoRoot
	cmd.Env = env // full environment; nil inherits
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return nil, &Error{Code: ee.ExitCode(), Detail: lastLines(stderr.String(), 6)}
		}
		return nil, err
	}
	out := bytes.TrimSpace(stdout.Bytes())
	if !json.Valid(out) {
		return nil, errors.New("cost returned invalid JSON")
	}
	return json.RawMessage(out), nil
}

func lastLines(s string, n int) string {
	l := strings.Split(strings.TrimSpace(s), "\n")
	if len(l) > n {
		l = l[len(l)-n:]
	}
	return strings.Join(l, "\n")
}
