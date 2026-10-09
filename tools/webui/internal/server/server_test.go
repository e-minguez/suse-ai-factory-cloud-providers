package server

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/tfvars"
)

const tok = "s3cret-token"

func testServer(t *testing.T) *Server {
	t.Helper()
	repo := t.TempDir()
	for _, p := range []string{"examples/aws", "tools/multicluster"} {
		if err := os.MkdirAll(filepath.Join(repo, p), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	_ = os.WriteFile(filepath.Join(repo, "examples/aws/deploy.sh"), nil, 0o755)
	_ = os.WriteFile(filepath.Join(repo, "tools/multicluster/cluster.sh"), []byte(`#!/bin/sh
d="$(dirname "$0")/../../clusters/$4"
mkdir -p "$d" && echo "$3" > "$d/.provider"
`), 0o755)
	s, err := New(Config{Repo: repo, Token: tok, AllowedHosts: []string{"127.0.0.1", "localhost"}})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func do(s *Server, method, target string, hdr map[string]string, cookies ...*http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, strings.NewReader(""))
	req.Host = "127.0.0.1:8080"
	for k, v := range hdr {
		if k == "Host" {
			req.Host = v
			continue
		}
		req.Header.Set(k, v)
	}
	for _, c := range cookies {
		req.AddCookie(c)
	}
	rr := httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, req)
	return rr
}

func session(t *testing.T, s *Server) *http.Cookie {
	t.Helper()
	rr := do(s, "GET", "/?token="+tok, nil)
	for _, c := range rr.Result().Cookies() {
		if c.Name == sessionCookie {
			return c
		}
	}
	t.Fatal("no session cookie")
	return nil
}

func TestNoTokenForbidden(t *testing.T) {
	rr := do(testServer(t), "GET", "/", nil)
	if rr.Code != 403 || !strings.Contains(rr.Body.String(), "container log") {
		t.Fatalf("%d %s", rr.Code, rr.Body.String())
	}
}

func TestWrongToken(t *testing.T) {
	if rr := do(testServer(t), "GET", "/?token=nope", nil); rr.Code != 403 {
		t.Fatal(rr.Code)
	}
}

func TestTokenSetsCookieAndRedirects(t *testing.T) {
	s := testServer(t)
	rr := do(s, "GET", "/clusters/new?token="+tok+"&x=1", nil)
	if rr.Code != http.StatusSeeOther || rr.Header().Get("Location") != "/clusters/new?x=1" {
		t.Fatalf("%d %s", rr.Code, rr.Header().Get("Location"))
	}
	c := session(t, s)
	if !c.HttpOnly || c.SameSite != http.SameSiteStrictMode || c.Value == tok {
		t.Fatalf("cookie %+v", c)
	}
	if rr := do(s, "GET", "/", nil, c); rr.Code != 200 {
		t.Fatalf("with cookie: %d", rr.Code)
	}
}

func TestBadHost(t *testing.T) {
	s := testServer(t)
	c := session(t, s)
	if rr := do(s, "GET", "/", map[string]string{"Host": "evil.example:8080"}, c); rr.Code != 403 {
		t.Fatalf("%d", rr.Code)
	}
	if rr := do(s, "GET", "/", map[string]string{"Host": "localhost:9"}, c); rr.Code != 200 {
		t.Fatalf("localhost: %d", rr.Code)
	}
}

func TestCrossOriginPost(t *testing.T) {
	s := testServer(t)
	c := session(t, s)
	for name, h := range map[string]map[string]string{
		"evil origin":  {"Origin": "http://evil.example"},
		"no origin":    {},
		"null":         {"Origin": "null"},
		"cross site":   {"Origin": "http://127.0.0.1:8080", "Sec-Fetch-Site": "cross-site"},
		"evil referer": {"Referer": "http://evil.example/x"},
		"same site":    {"Origin": "null", "Sec-Fetch-Site": "same-site"},
	} {
		if rr := do(s, "POST", "/clusters/new", h, c); rr.Code != 403 {
			t.Errorf("%s: %d", name, rr.Code)
		}
	}
	for name, h := range map[string]map[string]string{
		"same-origin":     {"Origin": "http://127.0.0.1:8080", "Sec-Fetch-Site": "same-origin"},
		"browser form":    {"Origin": "null", "Sec-Fetch-Site": "same-origin"}, // seen with no-referrer
		"no fetch header": {"Origin": "http://127.0.0.1:8080"},
	} {
		if rr := do(s, "POST", "/clusters/new", h, c); rr.Code == 403 {
			t.Errorf("%s rejected", name)
		}
	}
}

func TestHealthzNoAuth(t *testing.T) {
	s := testServer(t)
	rr := do(s, "GET", "/healthz", map[string]string{"Host": "anything"})
	if rr.Code != 200 || rr.Body.String() != "ok" {
		t.Fatalf("%d %q", rr.Code, rr.Body.String())
	}
}

func TestHeaders(t *testing.T) {
	s := testServer(t)
	rr := do(s, "GET", "/", nil, session(t, s))
	for k, want := range map[string]string{
		"Content-Security-Policy": "default-src 'self'",
		"X-Content-Type-Options":  "nosniff",
		"Referrer-Policy":         "same-origin",
		"Cache-Control":           "no-store",
	} {
		if !strings.Contains(rr.Header().Get(k), want) {
			t.Errorf("%s = %q", k, rr.Header().Get(k))
		}
	}
	if !strings.Contains(rr.Body.String(), "Unofficial community project") {
		t.Error("footer missing")
	}
	rr = do(s, "GET", "/static/app.css", nil)
	if rr.Code != 200 || !strings.Contains(rr.Header().Get("Cache-Control"), "max-age=31536000") {
		t.Fatalf("static: %d %q", rr.Code, rr.Header().Get("Cache-Control"))
	}
}

func TestCreateFlow(t *testing.T) {
	s := testServer(t)
	c := session(t, s)
	h := map[string]string{"Origin": "http://127.0.0.1:8080", "Content-Type": "application/x-www-form-urlencoded"}
	post := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest("POST", "/clusters/new", strings.NewReader(body))
		req.Host = "127.0.0.1:8080"
		for k, v := range h {
			req.Header.Set(k, v)
		}
		req.AddCookie(c)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, req)
		return rr
	}
	if rr := post("provider=aws&name=Bad_Name"); rr.Code != 400 || !strings.Contains(rr.Body.String(), "invalid cluster name") {
		t.Fatalf("invalid: %d", rr.Code)
	}
	rr := post("provider=aws&name=demo")
	if rr.Code != http.StatusSeeOther || rr.Header().Get("Location") != "/clusters/demo/edit" {
		t.Fatalf("create: %d %s", rr.Code, rr.Header().Get("Location"))
	}
	if m, err := tfvars.Read(filepath.Join(s.Cfg.ClustersDir(), "demo", "terraform.tfvars")); err != nil || m["cluster_name"] != "demo" {
		t.Fatalf("cluster_name not prefilled: %v %v", m, err)
	}
	long := strings.Repeat("a", 22)
	if rr := post("provider=aws&name=" + long); rr.Code != 400 || !strings.Contains(rr.Body.String(), "at most 21") {
		t.Fatalf("long aws name: %d", rr.Code)
	}
	if _, err := os.Stat(filepath.Join(s.Cfg.ClustersDir(), long)); err == nil {
		t.Fatal("long aws cluster created")
	}
	if rr := post("provider=aws&name=trail-"); rr.Code != 400 || !strings.Contains(rr.Body.String(), "dash") {
		t.Fatalf("trailing dash: %d", rr.Code)
	}
	if rr := do(s, "GET", "/clusters/demo", nil, c); rr.Code != 200 || !strings.Contains(rr.Body.String(), "demo") {
		t.Fatalf("overview: %d", rr.Code)
	}
	if rr := do(s, "GET", "/", nil, c); !strings.Contains(rr.Body.String(), "/clusters/demo") {
		t.Fatal("list misses cluster")
	}
	if rr := do(s, "GET", "/clusters/none", nil, c); rr.Code != 404 {
		t.Fatalf("404: %d", rr.Code)
	}
}

func TestRedact(t *testing.T) {
	got := Redact("pw=abc123 tok=abc", []string{"abc", "", "abc123"})
	if got != "pw=*** tok=***" {
		t.Fatal(got)
	}
}

func TestAlphaBanner(t *testing.T) {
	old := Version
	Version = "alpha-9.9.9"
	defer func() { Version = old }()
	s := testServer(t)
	c := session(t, s)
	rr := do(s, "GET", "/", nil, c)
	if body := rr.Body.String(); !strings.Contains(body, "Alpha (alpha-9.9.9)") || !strings.Contains(body, `class="tag alpha"`) {
		t.Fatal("alpha banner or tag missing")
	}
}

func TestStatusLabel(t *testing.T) {
	for in, want := range map[string]string{
		"no-state": "not deployed", "ok": "finished", "no_changes": "no changes",
		"deployed": "deployed", "awaiting confirmation": "awaiting confirmation", "some_new-state": "some new state",
	} {
		if got := statusLabel(in); got != want {
			t.Errorf("statusLabel(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestProviderName(t *testing.T) {
	for in, want := range map[string]string{"aws": "AWS", "evroc": "evroc", "exoscale": "Exoscale", "vultr": "Vultr", "other": "other"} {
		if got := providerName(in); got != want {
			t.Errorf("providerName(%q) = %q, want %q", in, got, want)
		}
	}
	sprite, err := webFS.ReadFile("web/static/providers.svg")
	if err != nil {
		t.Fatal(err)
	}
	for p := range providerLogos {
		if !strings.Contains(string(sprite), `<symbol id="`+p+`"`) {
			t.Errorf("providers.svg has no symbol for %s", p)
		}
	}
}
