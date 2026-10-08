package server

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/sshkeys"
)

func post(s *Server, target string, form url.Values, c *http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest("POST", target, strings.NewReader(form.Encode()))
	req.Host = "127.0.0.1:8080"
	req.Header.Set("Origin", "http://127.0.0.1:8080")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(c)
	rr := httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, req)
	return rr
}

func TestProfileSaveWriteOnly(t *testing.T) {
	s := testServer(t)
	c := session(t, s)
	rr := post(s, "/profiles/aws", url.Values{"access_key_id": {"AKIDEXAMPLE"}, "secret_access_key": {"SECRETVALUE"}}, c)
	if rr.Code != http.StatusSeeOther {
		t.Fatalf("%d %s", rr.Code, rr.Body)
	}
	if _, err := os.Stat(filepath.Join(s.Cfg.ClustersDir(), ".aws", "credentials")); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("GET", "/profiles/aws", nil)
	req.Host = "127.0.0.1:8080"
	req.AddCookie(c)
	out := httptest.NewRecorder()
	s.Handler().ServeHTTP(out, req)
	body := out.Body.String()
	if out.Code != 200 || strings.Contains(body, "AKIDEXAMPLE") || strings.Contains(body, "SECRETVALUE") || !strings.Contains(body, `class="badge set"`) {
		t.Fatalf("%d %s", out.Code, body)
	}
	if rr := post(s, "/profiles/nope", url.Values{}, c); rr.Code != 404 {
		t.Fatal(rr.Code)
	}
}

func TestSSHKeysFlow(t *testing.T) {
	s := testServer(t)
	c := session(t, s)
	base := url.Values{"sshkeys_name": {"ssh_authorized_keys"}, "sshkeys_provider": {"aws"}}

	f := url.Values{"sshkeys_name": base["sshkeys_name"], "sshkeys_provider": base["sshkeys_provider"], "sshkeys_comment": {"my key"}}
	rr := post(s, "/sshkeys/generate", f, c)
	body := rr.Body.String()
	m := regexp.MustCompile(`/sshkeys/download\?id=([0-9a-f]{32})`).FindStringSubmatch(body)
	if rr.Code != 200 || m == nil || !strings.Contains(body, "ssh-ed25519") || !strings.Contains(body, `hx-swap-oob="beforeend:body"`) {
		t.Fatalf("%d %s", rr.Code, body)
	}
	line := regexp.MustCompile(`name="ssh_authorized_keys" value="([^"]+)"`).FindStringSubmatch(body)
	if line == nil || !strings.HasSuffix(line[1], "my-key") {
		t.Fatalf("no key line: %s", body)
	}

	dl := post(s, "/sshkeys/download?id="+m[1], url.Values{}, c)
	if dl.Code != 200 || !strings.Contains(dl.Body.String(), "OPENSSH PRIVATE KEY") ||
		!strings.Contains(dl.Header().Get("Content-Disposition"), "attachment") || dl.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("%d %v", dl.Code, dl.Header())
	}
	if again := post(s, "/sshkeys/download?id="+m[1], url.Values{}, c); again.Code != 404 {
		t.Fatalf("second download %d", again.Code)
	}

	// Paste: private key rejected, selection state preserved via recalc.
	f = url.Values{"sshkeys_name": base["sshkeys_name"], "sshkeys_provider": base["sshkeys_provider"],
		"sshkeys_paste": {"-----BEGIN OPENSSH PRIVATE KEY-----"}}
	if rr := post(s, "/sshkeys/parse", f, c); !strings.Contains(rr.Body.String(), "private key") {
		t.Fatal(rr.Body)
	}
	f = url.Values{"sshkeys_name": base["sshkeys_name"], "sshkeys_provider": base["sshkeys_provider"],
		"ssh_authorized_keys__listed": {"generated|" + line[1]}}
	rr = post(s, "/sshkeys/recalc", f, c)
	if regexp.MustCompile(`value="ssh-[^>]* checked`).MatchString(rr.Body.String()) || !strings.Contains(rr.Body.String(), "Selected keys: 0 of 16384") {
		t.Fatalf("unselected key still checked: %s", rr.Body)
	}
	if rr := post(s, "/sshkeys/recalc", url.Values{"sshkeys_name": {"bad name"}, "sshkeys_provider": {"aws"}}, c); rr.Code != 400 {
		t.Fatal(rr.Code)
	}
}

func TestMyIP(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("203.0.113.7")) }))
	defer srv.Close()
	old := ipifyURL
	ipifyURL = srv.URL
	defer func() { ipifyURL = old }()
	s := testServer(t)
	c := session(t, s)
	rr := post(s, "/helpers/myip", url.Values{"target": {"cidr-admin_cidrs"}}, c)
	if !strings.Contains(rr.Body.String(), "203.0.113.7/32") {
		t.Fatal(rr.Body)
	}
	if rr := post(s, "/helpers/myip", url.Values{"target": {`x"><script>`}}, c); rr.Code != 400 {
		t.Fatal(rr.Code)
	}
}

func TestWidgetTemplates(t *testing.T) {
	s := testServer(t)
	w := NewSSHKeysWidget("keys", "exoscale", nil)
	rr := httptest.NewRecorder()
	s.renderPartial(rr, partialHost, "sshkeys", w)
	if !strings.Contains(rr.Body.String(), "No SSH keys yet") {
		t.Fatal(rr.Body)
	}
	rr = httptest.NewRecorder()
	s.renderPartial(rr, partialHost, "cidr_list", CIDRWidget{Name: "admin_cidrs", Values: []string{"10.0.0.0/8", "1.2.3.4/32"}})
	if !strings.Contains(rr.Body.String(), "10.0.0.0/8\n1.2.3.4/32") || !strings.Contains(rr.Body.String(), "cidr-admin_cidrs") {
		t.Fatal(rr.Body)
	}
}

func TestSSHGenerateKeepsKey(t *testing.T) {
	s := testServer(t)
	c := session(t, s)
	f := url.Values{"sshkeys_name": {"ssh_authorized_keys"}, "sshkeys_provider": {"aws"}, "sshkeys_keep": {"1"}}
	rr := post(s, "/sshkeys/generate", f, c)
	dlRe := regexp.MustCompile(`/sshkeys/download\?id=([0-9a-f]{32})`)
	m := dlRe.FindStringSubmatch(rr.Body.String())
	if rr.Code != 200 || m == nil || !strings.Contains(rr.Body.String(), "stored on the volume") {
		t.Fatalf("%d %s", rr.Code, rr.Body)
	}
	priv := filepath.Join(s.Cfg.ClustersDir(), ".home", ".ssh", "id_ed25519")
	st, err := os.Stat(priv)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("private key: %v", err)
	}
	if st, err := os.Stat(priv + ".pub"); err != nil || st.Mode().Perm() != 0o644 {
		t.Fatalf("public key: %v", err)
	}
	want, _ := os.ReadFile(priv)
	if dl := post(s, "/sshkeys/download?id="+m[1], url.Values{}, c); !strings.Contains(dl.Body.String(), "OPENSSH PRIVATE KEY") {
		t.Fatal("download once broken")
	}
	// Second generation: existing key kept, download still offered.
	rr = post(s, "/sshkeys/generate", f, c)
	if !strings.Contains(rr.Body.String(), "existing key kept") || dlRe.FindString(rr.Body.String()) == "" {
		t.Fatalf("second: %s", rr.Body)
	}
	if got, _ := os.ReadFile(priv); string(got) != string(want) {
		t.Fatal("existing key overwritten")
	}
	// Without the checkbox nothing is written.
	s2 := testServer(t)
	post(s2, "/sshkeys/generate", url.Values{"sshkeys_name": {"k"}, "sshkeys_provider": {"aws"}}, session(t, s2))
	if _, err := os.Stat(filepath.Join(s2.Cfg.ClustersDir(), ".home")); err == nil {
		t.Fatal("key stored without consent")
	}
}

func TestProfilesSSHKeyPaste(t *testing.T) {
	s := testServer(t)
	c := session(t, s)
	priv := filepath.Join(s.Cfg.ClustersDir(), ".home", ".ssh", "id_ed25519")
	_, body := getPage(s, "/profiles", c)
	if !strings.Contains(body, "SSH private key for the container") || !strings.Contains(body, "not set") {
		t.Fatalf("page: %s", body)
	}
	if rr := post(s, "/profiles/sshkey", url.Values{"ssh_private_key": {"nonsense"}}, c); rr.Code != 400 {
		t.Fatalf("garbage: %d", rr.Code)
	}
	_, pem, _ := sshkeys.Generate("t")
	rr := post(s, "/profiles/sshkey", url.Values{"ssh_private_key": {string(pem)}}, c)
	if rr.Code != http.StatusSeeOther {
		t.Fatalf("%d %s", rr.Code, rr.Body)
	}
	if st, err := os.Stat(priv); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("stored: %v", err)
	}
	_, body = getPage(s, "/profiles", c)
	if !strings.Contains(body, "stored") || strings.Contains(body, "b3BlbnNzaC1rZXk") {
		t.Fatal("status page")
	}
	if rr := post(s, "/profiles/sshkey", url.Values{"ssh_private_key": {string(pem)}}, c); rr.Code != 400 || !strings.Contains(rr.Body.String(), "already stored") {
		t.Fatalf("overwrite: %d", rr.Code)
	}
	if rr := post(s, "/profiles/sshkey", url.Values{"ssh_private_key": {string(pem)}, "replace": {"1"}}, c); rr.Code != http.StatusSeeOther {
		t.Fatalf("replace: %d", rr.Code)
	}
}
