package outputs

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

func TestGetDropsSensitive(t *testing.T) {
	bin := t.TempDir()
	script := `#!/bin/sh
cat <<'J'
{"api_host":{"sensitive":false,"type":"string","value":"h.example"},
 "pw":{"sensitive":true,"type":"string","value":"topsecret"},
 "nodes":{"sensitive":false,"type":["map","string"],"value":{"a":"1"}}}
J
`
	if err := os.WriteFile(filepath.Join(bin, "terraform"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	got, err := Get(context.Background(), t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := got["pw"]; ok || got["api_host"] != "h.example" || got["nodes"] == nil {
		t.Fatalf("%v", got)
	}
}

func TestGetError(t *testing.T) {
	bin := t.TempDir()
	_ = os.WriteFile(filepath.Join(bin, "terraform"), []byte("#!/bin/sh\necho no state >&2\nexit 1\n"), 0o755)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	if _, err := Get(context.Background(), t.TempDir(), nil); err == nil || !strings.Contains(err.Error(), "no state") {
		t.Fatalf("%v", err)
	}
}

func TestKubeconfig(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "kubeconfig.sh"), []byte("#!/bin/sh\necho \"args=$#\"\necho server: x\n"), 0o755)
	b, err := Kubeconfig(context.Background(), t.TempDir(), dir, nil)
	if err != nil || string(b) != "args=0\nserver: x\n" {
		t.Fatalf("%q %v", b, err)
	}
}

func TestKubeconfigEnv(t *testing.T) {
	t.Setenv("WEBUI_TOKEN", "sessiontoken")
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "kubeconfig.sh"), []byte("#!/bin/sh\necho \"home=$HOME tok=${WEBUI_TOKEN:-none} k=$X_CRED\"\n"), 0o755)
	env := workspace.ChildEnv([]string{"HOME=/clusters/.home", "X_CRED=v"})
	b, err := Kubeconfig(context.Background(), t.TempDir(), dir, env)
	if err != nil || string(b) != "home=/clusters/.home tok=none k=v\n" {
		t.Fatalf("%q %v", b, err)
	}
}

func TestRaw(t *testing.T) {
	bin := t.TempDir()
	script := "#!/bin/sh\n[ \"$2 $3 $4\" = 'output -raw rancher_bootstrap_password' ] || exit 2\nprintf 'p4ss'\n"
	_ = os.WriteFile(filepath.Join(bin, "terraform"), []byte(script), 0o755)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	got, err := Raw(context.Background(), t.TempDir(), "rancher_bootstrap_password", nil)
	if err != nil || got != "p4ss" {
		t.Fatalf("%q %v", got, err)
	}
}
