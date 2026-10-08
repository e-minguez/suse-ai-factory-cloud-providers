package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/jobs"
)

const jobsScript = `#!/bin/bash
ev() { printf '%s\n' "$1" >&3; }
ev '{"type":"start","provider":"aws","action":"deploy","pass_total":1}'
ev '{"type":"pass_start","index":1,"total":1,"title":"Deploy"}'
ev '{"type":"plan_summary","index":1,"create":1,"update":0,"replace":["x.y"],"destroy":["a.b"],"no_changes":false}'
ev '{"type":"confirm_request","index":1}'
read -r ans <&4
echo "answer $ans sekret"
ev '{"type":"resource","index":1,"address":"x.y","action":"create","status":"complete","elapsed_s":3}'
ev '{"type":"pass_done","index":1,"status":"ok","duration_s":4}'
ev '{"type":"done","status":"ok","exit_code":0,"log_dir":""}'
`

func jobsServer(t *testing.T) (*Server, *http.Cookie, string) {
	s := testServer(t)
	repo := s.Cfg.Repo
	_ = os.WriteFile(filepath.Join(repo, "tools/multicluster/cluster.sh"), []byte(jobsScript), 0o755)
	dir := filepath.Join(repo, "clusters", "c1")
	if err := os.MkdirAll(filepath.Join(dir, ".deploy/logs/20260101-000000"), 0o700); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(dir, ".provider"), []byte("aws\n"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, ".deploy/logs/20260101-000000/apply.log"), []byte("token sekret\n"), 0o600)
	s.Jobs = jobs.NewManager(repo, filepath.Join(repo, "clusters"), nil,
		func(x string) string { return strings.ReplaceAll(x, "sekret", "***") })
	s.Shutdowners = append(s.Shutdowners, s.Jobs)
	return s, session(t, s), dir
}

func TestDestroyNeedsName(t *testing.T) {
	s, c, _ := jobsServer(t)
	rr := jpost(s, "/clusters/c1/destroy", "confirm=wrong", c)
	if rr.Code != 303 || rr.Header().Get("Location") != "/clusters/c1" {
		t.Fatalf("%d %s", rr.Code, rr.Header().Get("Location"))
	}
	if len(s.Jobs.List("c1")) != 0 {
		t.Fatal("job started")
	}
}

func jpost(s *Server, target, body string, c *http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", target, strings.NewReader(body))
	req.Host = "127.0.0.1:8080"
	req.Header.Set("Origin", "http://127.0.0.1:8080")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(c)
	rr := httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, req)
	return rr
}

func TestDeployFlow(t *testing.T) {
	s, c, _ := jobsServer(t)
	rr := jpost(s, "/clusters/c1/deploy", "rebuild=on", c)
	loc := rr.Header().Get("Location")
	if rr.Code != 303 || !strings.HasPrefix(loc, "/jobs/") {
		t.Fatalf("%d %s", rr.Code, loc)
	}
	id := strings.TrimPrefix(loc, "/jobs/")
	if rr := jpost(s, "/clusters/c1/deploy", "", c); rr.Header().Get("Location") != "/clusters/c1" {
		t.Fatal("second start was not rejected")
	}
	j, _ := s.Jobs.Get(id)
	for i := 0; i < 200 && !j.Info().Confirm; i++ {
		time.Sleep(25 * time.Millisecond)
	}
	if rr := jpost(s, "/jobs/"+id+"/confirm", "answer=maybe", c); rr.Code != 400 {
		t.Fatalf("bad answer: %d", rr.Code)
	}
	if rr := jpost(s, "/jobs/"+id+"/confirm", "answer=yes", c); rr.Code != 400 {
		t.Fatalf("missing index: %d", rr.Code)
	}
	if rr := jpost(s, "/jobs/"+id+"/confirm", "answer=yes&index=7", c); rr.Code != 409 ||
		!strings.Contains(rr.Body.String(), "already answered") {
		t.Fatalf("stale index: %d %s", rr.Code, rr.Body.String())
	}
	if f := s.frag("job_confirm", confirmView{Pending: true, Index: 3, Job: id}); !strings.Contains(f, `name="index" value="3"`) {
		t.Fatalf("confirm form lacks the pass index:\n%s", f)
	}
	if rr := jpost(s, "/jobs/"+id+"/confirm", "answer=yes&index=1", c); rr.Code != 303 {
		t.Fatalf("confirm: %d", rr.Code)
	}
	if rr := jpost(s, "/jobs/"+id+"/confirm", "answer=yes&index=1", c); rr.Code != 409 {
		t.Fatalf("second answer: %d", rr.Code)
	}
	select {
	case <-j.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("not finished")
	}
	page := do(s, "GET", "/jobs/"+id, nil, c)
	if page.Code != 200 || !strings.Contains(page.Body.String(), `sse-connect="/jobs/`+id+`/events"`) {
		t.Fatalf("page %d", page.Code)
	}
	ev := do(s, "GET", "/jobs/"+id+"/events", nil, c).Body.String()
	for _, name := range []string{"event: line", "event: pass", "event: plan", "event: resource", "event: confirm", "event: done"} {
		if !strings.Contains(ev, name) {
			t.Errorf("missing %q in stream:\n%s", name, ev)
		}
	}
	if strings.Contains(ev, "sekret") || !strings.Contains(ev, "answer yes ***") {
		t.Errorf("redaction:\n%s", ev)
	}
	if !strings.Contains(ev, "x.y") || !strings.Contains(ev, "class=\"destroy\"") && !strings.Contains(ev, "destroy") {
		t.Errorf("plan lists missing")
	}
	// Reconnect after the last id: state fragments again, no repeated lines.
	last := ev[strings.LastIndex(ev, "id: ")+4:]
	last = last[:strings.IndexByte(last, '\n')]
	again := do(s, "GET", "/jobs/"+id+"/events", map[string]string{"Last-Event-ID": last}, c).Body.String()
	if strings.Contains(again, "event: line") {
		t.Errorf("lines repeated after Last-Event-ID:\n%s", again)
	}
	if rr := do(s, "GET", "/clusters/c1/jobs", nil, c); !strings.Contains(rr.Body.String(), id) {
		t.Error("jobs panel misses job")
	}
}

func TestLogs(t *testing.T) {
	s, c, _ := jobsServer(t)
	if rr := do(s, "GET", "/clusters/c1/logs", nil, c); !strings.Contains(rr.Body.String(), "apply.log") {
		t.Fatal("list")
	}
	rr := do(s, "GET", "/clusters/c1/logs/20260101-000000/apply.log", nil, c)
	if rr.Code != 200 || strings.Contains(rr.Body.String(), "sekret") || !strings.Contains(rr.Body.String(), "***") {
		t.Fatalf("%d %q", rr.Code, rr.Body.String())
	}
	for _, p := range []string{"/clusters/c1/logs/..%2F..%2F.provider/x", "/clusters/c1/logs/20260101-000000/..%2F..%2F..%2F.provider", "/clusters/c1/logs/20260101-000000/nope.log"} {
		if rr := do(s, "GET", p, nil, c); rr.Code != 404 {
			t.Errorf("%s: %d", p, rr.Code)
		}
	}
}

func TestKubeconfigDownload(t *testing.T) {
	s, c, dir := jobsServer(t)
	_ = os.WriteFile(filepath.Join(dir, "kubeconfig.sh"), []byte("#!/bin/sh\necho 'server: https://x'\n"), 0o755)
	rr := jpost(s, "/clusters/c1/kubeconfig", "", c)
	if rr.Code != 200 || rr.Header().Get("Cache-Control") != "no-store" ||
		rr.Header().Get("Content-Type") != "application/yaml" ||
		!strings.Contains(rr.Header().Get("Content-Disposition"), "attachment") {
		t.Fatalf("%d %v", rr.Code, rr.Header())
	}
	if _, err := os.Stat(filepath.Join(dir, "kubeconfig")); err == nil {
		t.Fatal("written to disk")
	}
}

func TestStartDuringShutdown(t *testing.T) {
	s, c, _ := jobsServer(t)
	_ = s.Shutdown(context.Background())
	rr := jpost(s, "/clusters/c1/deploy", "", c)
	if rr.Code != 303 || rr.Header().Get("Location") != "/clusters/c1" {
		t.Fatalf("%d %s", rr.Code, rr.Header().Get("Location"))
	}
	page := do(s, "GET", "/clusters/c1", nil, c)
	if page.Code != 200 {
		t.Fatalf("overview: %d", page.Code)
	}
	if _, ok := s.Jobs.Current("c1"); ok {
		t.Fatal("job started during shutdown")
	}
}

func TestLeftoversPanel(t *testing.T) {
	s, c, _ := jobsServer(t)
	t.Setenv("PATH", t.TempDir())
	body := do(s, "GET", "/clusters/c1/leftovers", nil, c).Body.String()
	if strings.Contains(body, "<button") || !strings.Contains(body, "tools/leftovers/aws.sh") ||
		!strings.Contains(body, "needs the aws CLI") {
		t.Fatalf("panel without aws CLI:\n%s", body)
	}
	if rr := jpost(s, "/clusters/c1/leftovers", "", c); rr.Code != 303 || rr.Header().Get("Location") != "/clusters/c1" {
		t.Fatalf("start without aws CLI: %d %s", rr.Code, rr.Header().Get("Location"))
	}
	if _, ok := s.Jobs.Current("c1"); ok {
		t.Fatal("leftovers job started without the CLI")
	}
	bin := t.TempDir()
	_ = os.WriteFile(filepath.Join(bin, "aws"), []byte("#!/bin/sh\n"), 0o755)
	t.Setenv("PATH", bin)
	if body := do(s, "GET", "/clusters/c1/leftovers", nil, c).Body.String(); !strings.Contains(body, "<button") {
		t.Fatalf("panel with aws CLI:\n%s", body)
	}
}
