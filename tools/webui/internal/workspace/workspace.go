// Package workspace lists and creates clusters on the shared clusters/ volume.
package workspace

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/schema"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/tfvars"
)

// Cluster status values.
const (
	StatusNoState  = "no-state"
	StatusDeployed = "deployed"
	StatusRunning  = "running"
	StatusError    = "error"
)

var (
	nameRe = regexp.MustCompile(`^[a-z][a-z0-9-]{0,62}$`)
	provRe = regexp.MustCompile(`^[a-z][a-z0-9]*$`)

	ErrInvalidName = errors.New("invalid cluster name: lowercase letters, digits and dashes, starting with a letter, max 63 characters")
	ErrUnknownProv = errors.New("unknown provider")
	ErrBadProvider = errors.New("invalid .provider file")
	ErrNotFound    = errors.New("cluster not found")
	ErrExists      = errors.New("cluster already exists")
)

// ValidName reports whether name is a valid cluster name.
func ValidName(name string) bool { return nameRe.MatchString(name) }

// ValidProvider reports whether p looks like a provider name.
func ValidProvider(p string) bool { return provRe.MatchString(p) }

// ReadProvider returns the validated content of <clusterDir>/.provider.
func ReadProvider(clusterDir string) (string, error) {
	b, err := os.ReadFile(filepath.Join(clusterDir, ".provider"))
	if err != nil {
		return "", ErrNotFound
	}
	p := strings.TrimSpace(string(b))
	if !ValidProvider(p) {
		return "", ErrBadProvider
	}
	return p, nil
}

// ChildEnv is the environment of every child process: os.Environ() without
// WEBUI_* (the session token must not leak) plus extra (later entries win).
func ChildEnv(extra []string) []string {
	env := make([]string, 0, len(os.Environ())+len(extra))
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "WEBUI_") {
			env = append(env, kv)
		}
	}
	return append(env, extra...)
}

// Vars returns the effective tfvars of a cluster as deploy.sh reads them:
// <repo>/common-all.tfvars (lowest) then the clusters layers.
func Vars(repo, clustersDir, provider, cluster string) (map[string]any, error) {
	out, err := tfvars.Read(filepath.Join(repo, "common-all.tfvars"))
	if err != nil {
		out = map[string]any{}
	}
	eff, err := tfvars.Effective(clustersDir, provider, cluster)
	for k, v := range eff {
		out[k] = v
	}
	return out, err
}

// Cluster is one directory under Root.
type Cluster struct {
	Name     string
	Provider string
	Status   string
	Dir      string
}

// Workspace is the repository checkout and its clusters directory.
type Workspace struct {
	Repo string // repository root
	Root string // clusters directory, normally <Repo>/clusters
}

// New returns a Workspace for repo with Root = repo/clusters.
func New(repo string) *Workspace {
	return &Workspace{Repo: repo, Root: filepath.Join(repo, "clusters")}
}

// Providers lists examples/*/ that ship a deploy.sh, sorted.
func (w *Workspace) Providers() []string { return schema.Providers(w.Repo) }

// List returns all clusters sorted by name. A missing Root is an empty list.
func (w *Workspace) List() ([]Cluster, error) {
	entries, err := os.ReadDir(w.Root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []Cluster
	for _, e := range entries {
		if !e.IsDir() || !ValidName(e.Name()) {
			continue
		}
		c, err := w.Get(e.Name())
		if err != nil {
			continue
		}
		out = append(out, *c)
	}
	return out, nil
}

// Get returns the named cluster; the directory must carry a .provider file.
func (w *Workspace) Get(name string) (*Cluster, error) {
	if !ValidName(name) {
		return nil, ErrInvalidName
	}
	dir := filepath.Join(w.Root, name)
	prov, err := ReadProvider(dir)
	if err != nil {
		return nil, err
	}
	c := &Cluster{Name: name, Provider: prov, Dir: dir}
	c.Status = Status(dir)
	return c, nil
}

// Create runs `cluster.sh new --empty <provider> <name>`.
func (w *Workspace) Create(ctx context.Context, provider, name string) (*Cluster, error) {
	if !ValidName(name) {
		return nil, ErrInvalidName
	}
	known := false
	for _, p := range w.Providers() {
		known = known || p == provider
	}
	if !known {
		return nil, ErrUnknownProv
	}
	if _, err := os.Lstat(filepath.Join(w.Root, name)); err == nil {
		return nil, ErrExists
	}
	if err := os.MkdirAll(w.Root, 0o700); err != nil {
		return nil, err
	}
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	script := filepath.Join(w.Repo, "tools", "multicluster", "cluster.sh")
	out, err := func() ([]byte, error) {
		cmd := exec.CommandContext(cctx, script, "new", "--empty", provider, name)
		cmd.Env = ChildEnv(nil)
		return cmd.CombinedOutput()
	}()
	if err != nil {
		return nil, fmt.Errorf("cluster.sh new: %w: %s", err, strings.TrimSpace(string(out)))
	}
	_ = os.Chmod(filepath.Join(w.Root, name), 0o700)
	return w.Get(name)
}

// Status derives the cluster status from marker files. It never exposes
// state contents; only the resource count is read.
func Status(dir string) string {
	if LockLive(filepath.Join(dir, ".deploy", "webui.lock")) {
		return StatusRunning
	}
	if b, err := os.ReadFile(filepath.Join(dir, ".deploy", "webui-last-status")); err == nil &&
		strings.TrimSpace(string(b)) == "failed" {
		return StatusError
	}
	if !HasState(dir) {
		return StatusNoState
	}
	return StatusDeployed
}

// HasState reports whether terraform.tfstate lists at least one resource.
func HasState(dir string) bool {
	b, err := os.ReadFile(filepath.Join(dir, "terraform.tfstate"))
	if err != nil || len(b) == 0 {
		return false
	}
	var s struct {
		Resources []json.RawMessage `json:"resources"`
	}
	if json.Unmarshal(b, &s) != nil {
		return false
	}
	return len(s.Resources) > 0
}

// Alive reports whether a process with pid exists.
func Alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// Instance identifies this webui process. A lock written by another instance
// (an earlier container, whose PIDs may be reused here) is stale.
var Instance = func() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}()

// LockLive reports whether a webui.lock ("pid start action instance") belongs
// to a running job of this instance.
func LockLive(path string) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	f := strings.Fields(string(b))
	if len(f) < 4 || f[3] != Instance {
		return false
	}
	pid, _ := strconv.Atoi(f[0])
	return pid > 0 && Alive(pid)
}
