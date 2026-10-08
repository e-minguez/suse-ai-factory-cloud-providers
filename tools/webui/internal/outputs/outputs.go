// Package outputs reads non-sensitive terraform outputs and the cluster
// kubeconfig (fetched on demand, never stored).
package outputs

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

const timeout = 90 * time.Second

// Get runs `terraform -chdir=<clusterDir> output -json` and returns
// name -> value without sensitive outputs.
// env is the child environment (see workspace.ChildEnv); nil means
// workspace.ChildEnv(nil).
func Get(ctx context.Context, clusterDir string, env []string) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var out, errb bytes.Buffer
	cmd := exec.CommandContext(ctx, "terraform", "-chdir="+clusterDir, "output", "-json")
	cmd.Stdout, cmd.Stderr = &out, &errb
	cmd.Env = append(childEnv(env), "TF_IN_AUTOMATION=1", "TF_INPUT=0")
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("terraform output: %w: %s", err, trim(errb.String()))
	}
	var raw map[string]struct {
		Sensitive bool `json:"sensitive"`
		Value     any  `json:"value"`
	}
	if err := json.Unmarshal(out.Bytes(), &raw); err != nil {
		return nil, fmt.Errorf("terraform output: %w", err)
	}
	res := make(map[string]any, len(raw))
	for k, v := range raw {
		if !v.Sensitive {
			res[k] = v.Value
		}
	}
	return res, nil
}

// Kubeconfig runs <clusterDir>/kubeconfig.sh (no arguments, so stdout) and
// returns what it prints. Falls back to <repo>/scripts/kubeconfig.sh -C.
// env as in Get: HOME and provider credentials so ssh finds its key.
func Kubeconfig(ctx context.Context, repoRoot, clusterDir string, env []string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	script, args := filepath.Join(clusterDir, "kubeconfig.sh"), []string(nil)
	if _, err := os.Stat(script); err != nil {
		script, args = filepath.Join(repoRoot, "scripts", "kubeconfig.sh"), []string{"-C", clusterDir}
	}
	var out, errb bytes.Buffer
	cmd := exec.CommandContext(ctx, script, args...)
	cmd.Dir = clusterDir
	cmd.Env = childEnv(env)
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("kubeconfig.sh: %w: %s", err, trim(errb.String()))
	}
	return out.Bytes(), nil
}

func childEnv(env []string) []string {
	if env == nil {
		return workspace.ChildEnv(nil)
	}
	return env
}

func trim(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > 500 {
		s = s[:500] + "..."
	}
	return s
}

// Raw returns `terraform output -raw <name>`, for a sensitive output the user
// asked to see. Callers pass a fixed output name, never user input.
func Raw(ctx context.Context, clusterDir, name string, env []string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var out, errb bytes.Buffer
	cmd := exec.CommandContext(ctx, "terraform", "-chdir="+clusterDir, "output", "-raw", name)
	cmd.Stdout, cmd.Stderr = &out, &errb
	cmd.Env = append(childEnv(env), "TF_IN_AUTOMATION=1", "TF_INPUT=0")
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("terraform output %s: %w: %s", name, err, trim(errb.String()))
	}
	return out.String(), nil
}
