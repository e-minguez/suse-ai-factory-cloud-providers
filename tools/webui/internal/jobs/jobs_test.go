package jobs

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

// Fake cluster.sh: $2 is the cluster name and selects the behaviour.
const fakeScript = `#!/bin/bash
name=$2
ev() { printf '%s\n' "$1" >&3; }
ev '{"type":"start","provider":"aws","action":"deploy","pass_total":1}'
ev '{"type":"pass_start","index":1,"total":1,"title":"Deploy"}'
case "$name" in
  confirm)
    ev '{"type":"plan_summary","index":1,"create":2,"update":0,"replace":["a.b"],"destroy":[],"no_changes":false}'
    ev '{"type":"confirm_request","index":1}'
    read -r ans <&4
    ev '{"type":"confirm_response","index":1,"answer":"'"$ans"'"}'
    if [ "$ans" = yes ]; then ev '{"type":"done","status":"ok","exit_code":0,"log_dir":""}'; exit 0; fi
    ev '{"type":"done","status":"aborted","exit_code":1,"log_dir":""}'; exit 1 ;;
  slow)
    trap 'ev "{\"type\":\"done\",\"status\":\"aborted\",\"exit_code\":130,\"log_dir\":\"\"}"; exit 130' INT
    while :; do sleep 0.05; done ;;
  secret)
    echo "token is hunter2 here"
    ev '{"type":"diagnostic","index":1,"severity":"error","summary":"bad hunter2","detail":""}'
    exit 3 ;;
  big)
    printf '{"type":"plan_summary","index":1,"create":1,"update":0,"replace":["%s"],"destroy":[],"no_changes":false}\n' "$(head -c 200000 /dev/zero | tr '\0' a)" >&3
    ev '{"type":"done","status":"ok","exit_code":0,"log_dir":""}' ;;
  esc)
    ev '{"type":"diagnostic","index":1,"severity":"error","summary":"bad h\u0075nter2","detail":"x"}'
    ev '{"type":"done","status":"ok","exit_code":0,"log_dir":""}' ;;
  env)
    echo "home=$HOME tok=${WEBUI_TOKEN:-none} cred=$X_CRED"
    ev '{"type":"done","status":"ok","exit_code":0,"log_dir":""}' ;;
  *)
    echo "hello"
    ev '{"type":"done","status":"ok","exit_code":0,"log_dir":"/x"}' ;;
esac
`

func setup(t *testing.T) (*Manager, string) {
	t.Helper()
	repo := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(repo, "tools/multicluster"), 0o755))
	must(t, os.WriteFile(filepath.Join(repo, "tools/multicluster/cluster.sh"), []byte(fakeScript), 0o755))
	clusters := filepath.Join(repo, "clusters")
	for _, n := range []string{"ok", "confirm", "slow", "secret", "big", "esc", "env"} {
		must(t, os.MkdirAll(filepath.Join(clusters, n), 0o700))
		must(t, os.WriteFile(filepath.Join(clusters, n, ".provider"), []byte("aws\n"), 0o600))
	}
	redact := func(s string) string { return strings.ReplaceAll(s, "hunter2", "***") }
	return NewManager(repo, clusters, nil, redact), clusters
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func wait(t *testing.T, j *Job) {
	t.Helper()
	select {
	case <-j.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("job did not finish")
	}
}

func waitConfirm(t *testing.T, j *Job) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if j.Info().Confirm {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("no confirm_request")
}

func types(m *Manager, j *Job) []string {
	rep, _, _ := m.Subscribe(j.ID)
	var out []string
	for _, e := range rep {
		out = append(out, e.Type)
	}
	return out
}

func TestOK(t *testing.T) {
	m, dir := setup(t)
	j, err := m.Start("ok", ActionDeploy)
	must(t, err)
	wait(t, j)
	in := j.Info()
	if in.Status != StatusOK || in.LogDir != "/x" {
		t.Fatalf("%+v", in)
	}
	// stdout and fd 3 are separate streams: only the protocol order and the final done are fixed.
	got := types(m, j)
	if got[len(got)-1] != "done" || strings.Join(got, ",") == "" || !strings.Contains(strings.Join(got, ","), "start") {
		t.Fatalf("order %v", got)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "ok/.deploy/webui-last-status"))
	if strings.TrimSpace(string(b)) != "ok" {
		t.Fatalf("last-status %q", b)
	}
	if _, err := os.Stat(filepath.Join(dir, "ok/.deploy/webui.lock")); err == nil {
		t.Fatal("lock left behind")
	}
	if _, ok := m.Current("ok"); ok {
		t.Fatal("still current")
	}
}

func TestConfirm(t *testing.T) {
	for _, yes := range []bool{true, false} {
		m, _ := setup(t)
		j, err := m.Start("confirm", ActionDeploy)
		must(t, err)
		if err := m.Confirm(j.ID, 1, true); err != ErrNoConfirm && err != nil && j.Info().Confirm {
			t.Fatal(err)
		}
		waitConfirm(t, j)
		if p, ok := j.Plan(1); !ok || p.Create != 2 || len(p.Replace) != 1 {
			t.Fatalf("plan %+v", p)
		}
		must(t, m.Confirm(j.ID, 1, yes))
		if err := m.Confirm(j.ID, 1, yes); err != ErrNoConfirm && err != ErrFinished {
			t.Fatalf("second confirm: %v", err)
		}
		wait(t, j)
		want := StatusOK
		if !yes {
			want = StatusAborted
		}
		if s := j.Info().Status; s != want {
			t.Fatalf("yes=%v status %s", yes, s)
		}
	}
}

func TestConfirmStaleIndex(t *testing.T) {
	m, _ := setup(t)
	j, err := m.Start("confirm", ActionDeploy)
	must(t, err)
	waitConfirm(t, j)
	if err := m.Confirm(j.ID, 2, true); err != ErrStaleConfirm {
		t.Fatalf("got %v", err)
	}
	if !j.Info().Confirm {
		t.Fatal("stale answer consumed the request")
	}
	must(t, m.Confirm(j.ID, 1, false))
	wait(t, j)
}

func TestConfirmWithoutRequest(t *testing.T) {
	m, _ := setup(t)
	j, err := m.Start("slow", ActionDeploy)
	must(t, err)
	if err := m.Confirm(j.ID, 1, true); err != ErrNoConfirm {
		t.Fatalf("got %v", err)
	}
	must(t, m.Cancel(j.ID))
	wait(t, j)
}

func TestCancelAndBusy(t *testing.T) {
	m, dir := setup(t)
	j, err := m.Start("slow", ActionDeploy)
	must(t, err)
	if _, err := m.Start("slow", ActionDeploy); err != ErrBusy {
		t.Fatalf("want ErrBusy, got %v", err)
	}
	// A second process (lock file only) is also busy.
	m2 := NewManager(m.repo, m.clusters, nil, nil)
	if _, err := m2.Start("slow", ActionDeploy); err != ErrBusy {
		t.Fatalf("lock: want ErrBusy, got %v", err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "slow/.deploy/webui.lock"))
	if f := strings.Fields(string(b)); len(f) != 4 || f[2] != "deploy" || f[3] != workspace.Instance {
		t.Fatalf("lock %q", b)
	}
	time.Sleep(200 * time.Millisecond) // let the trap install
	must(t, m.Cancel(j.ID))
	wait(t, j)
	if s := j.Info().Status; s != StatusAborted {
		t.Fatalf("status %s", s)
	}
	if err := m.Cancel(j.ID); err != ErrFinished {
		t.Fatalf("got %v", err)
	}
	if _, err := m.Start("slow", ActionDeploy); err != nil {
		t.Fatalf("restart after finish: %v", err)
	}
	_ = m.Shutdown(context.Background())
}

func TestStaleLock(t *testing.T) {
	m, dir := setup(t)
	lock := filepath.Join(dir, "ok/.deploy/webui.lock")
	must(t, os.MkdirAll(filepath.Dir(lock), 0o700))
	must(t, os.WriteFile(lock, []byte("2147480000 1 deploy\n"), 0o600))
	j, err := m.Start("ok", ActionDeploy)
	if err != nil {
		t.Fatal(err)
	}
	wait(t, j)
}

func TestRedactionAndExitCode(t *testing.T) {
	m, _ := setup(t)
	j, err := m.Start("secret", ActionDeploy)
	must(t, err)
	wait(t, j)
	in := j.Info()
	if in.Status != StatusFailed || in.ExitCode != 3 {
		t.Fatalf("%+v", in)
	}
	rep, _, _ := m.Subscribe(j.ID)
	for _, e := range rep {
		if strings.Contains(e.Line, "hunter2") || strings.Contains(string(e.Raw), "hunter2") {
			t.Fatalf("leak: %+v", e)
		}
	}
	var sawLine, sawDiag bool
	for _, e := range rep {
		sawLine = sawLine || (e.Type == "line" && strings.Contains(e.Line, "***"))
		sawDiag = sawDiag || (e.Type == "diagnostic" && strings.Contains(string(e.Raw), "bad ***"))
	}
	if !sawLine || !sawDiag {
		t.Fatalf("missing redacted events: %v", rep)
	}
	if last := rep[len(rep)-1]; last.Type != "done" {
		t.Fatalf("last event %s", last.Type)
	}
}

func TestSubscribeLive(t *testing.T) {
	m, _ := setup(t)
	j, err := m.Start("confirm", ActionDeploy)
	must(t, err)
	_, ch, cancel := m.Subscribe(j.ID)
	defer cancel()
	waitConfirm(t, j)
	must(t, m.Confirm(j.ID, 1, true))
	var got []string
	for e := range ch {
		got = append(got, e.Type)
	}
	if len(got) == 0 || got[len(got)-1] != "done" {
		t.Fatalf("live events %v", got)
	}
}

func TestShutdownKills(t *testing.T) {
	m, _ := setup(t)
	j, err := m.Start("slow", ActionDeploy)
	must(t, err)
	time.Sleep(200 * time.Millisecond)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	must(t, m.Shutdown(ctx))
	wait(t, j)
	if syscall.Kill(-j.pgid, 0) == nil {
		t.Fatal("process group still alive")
	}
}

func TestLeftoverSpec(t *testing.T) {
	repo := t.TempDir()
	dir := filepath.Join(repo, "clusters")
	must(t, os.MkdirAll(filepath.Join(dir, "c1"), 0o700))
	must(t, os.WriteFile(filepath.Join(dir, "common-all.tfvars"), []byte("region = \"eu\"\n"), 0o600))
	must(t, os.WriteFile(filepath.Join(dir, "common-vultr.tfvars"), []byte("vultr_api_key = \"k\"\n"), 0o600))
	must(t, os.WriteFile(filepath.Join(dir, "c1/terraform.tfvars"), []byte("cluster_name = \"foo\"\nproject = \"p\"\n"), 0o600))
	cases := map[string]string{
		"aws": "foo --region eu", "evroc": "foo --region eu --project p",
		"exoscale": "foo --region eu", "vultr": "foo",
	}
	for p, want := range cases {
		if got := strings.Join(LeftoverSpec(repo, dir, p, "c1").Args, " "); got != want {
			t.Errorf("%s: %q want %q", p, got, want)
		}
	}
	if e := LeftoverSpec(repo, dir, "vultr", "c1").Env; len(e) != 1 || e[0] != "VULTR_API_KEY=k" {
		t.Errorf("env %v", e)
	}
}

func TestNoEventsExitCode(t *testing.T) {
	m, _ := setup(t)
	must(t, os.WriteFile(filepath.Join(m.repo, "tools/multicluster/cluster.sh"), []byte("#!/bin/sh\necho bad arg >&2\nexit 2\n"), 0o755))
	j, err := m.Start("ok", ActionDeploy)
	must(t, err)
	wait(t, j)
	if in := j.Info(); in.Status != StatusFailed || in.ExitCode != 2 {
		t.Fatalf("%+v", in)
	}
}

func TestLeftoverRootLayer(t *testing.T) {
	repo := t.TempDir()
	dir := filepath.Join(repo, "clusters")
	must(t, os.MkdirAll(filepath.Join(dir, "c1"), 0o700))
	must(t, os.WriteFile(filepath.Join(repo, "common-all.tfvars"), []byte("region = \"root\"\ncluster_name = \"rootname\"\n"), 0o600))
	if got := strings.Join(LeftoverSpec(repo, dir, "exoscale", "c1").Args, " "); got != "rootname --region root" {
		t.Fatalf("got %q", got)
	}
	must(t, os.WriteFile(filepath.Join(dir, "common-all.tfvars"), []byte("region = \"eu\"\n"), 0o600))
	if got := strings.Join(LeftoverSpec(repo, dir, "exoscale", "c1").Args, " "); got != "rootname --region eu" {
		t.Fatalf("clusters layer must win: %q", got)
	}
}

func TestLeftoversNeedTools(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	if m := LeftoversMissing("aws"); len(m) != 1 || m[0] != "aws" {
		t.Fatalf("%v", m)
	}
	m, _ := setup(t)
	_, err := m.Start("ok", ActionLeftovers)
	var mt *MissingToolError
	if !errors.As(err, &mt) {
		t.Fatalf("got %v", err)
	}
	if got := (Leftovers{Args: []string{"it's", "eu"}}).Command("aws"); got != `tools/leftovers/aws.sh 'it'\''s' 'eu'` {
		t.Fatalf("command %q", got)
	}
}

func TestShutdownRejectsStart(t *testing.T) {
	m, _ := setup(t)
	must(t, m.Shutdown(context.Background()))
	if _, err := m.Start("ok", ActionDeploy); err != ErrShuttingDown {
		t.Fatalf("got %v", err)
	}
}

func TestBigEventParses(t *testing.T) {
	m, _ := setup(t)
	j, err := m.Start("big", ActionDeploy)
	must(t, err)
	wait(t, j)
	p, ok := j.Plan(1)
	if !ok || len(p.Replace) != 1 || len(p.Replace[0]) != 200000 {
		t.Fatalf("plan_summary lost: ok=%v", ok)
	}
}

func TestEscapedSecretInEvent(t *testing.T) {
	m, _ := setup(t)
	j, err := m.Start("esc", ActionDeploy)
	must(t, err)
	wait(t, j)
	rep, _, _ := m.Subscribe(j.ID)
	for _, e := range rep {
		if e.Type == "diagnostic" {
			if strings.Contains(string(e.Raw), "hunter2") || !strings.Contains(string(e.Raw), "bad ***") {
				t.Fatalf("raw %s", e.Raw)
			}
			return
		}
	}
	t.Fatal("no diagnostic")
}

func TestChildEnv(t *testing.T) {
	t.Setenv("WEBUI_TOKEN", "sessiontoken")
	m, _ := setup(t)
	m.envFor = func(string) []string { return []string{"HOME=/h", "X_CRED=v"} }
	j, err := m.Start("env", ActionDeploy)
	must(t, err)
	wait(t, j)
	rep, _, _ := m.Subscribe(j.ID)
	for _, e := range rep {
		if e.Type == "line" {
			if e.Line != "home=/h tok=none cred=v" {
				t.Fatalf("env: %q", e.Line)
			}
			return
		}
	}
	t.Fatal("no output")
}

func TestBadProvider(t *testing.T) {
	m, dir := setup(t)
	must(t, os.WriteFile(filepath.Join(dir, "ok/.provider"), []byte("../x; rm\n"), 0o600))
	if _, err := m.Start("ok", ActionDeploy); err == nil {
		t.Fatal("invalid provider accepted")
	}
}
