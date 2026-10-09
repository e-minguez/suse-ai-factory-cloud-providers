package server

import (
	"html"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/passhash"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/schema"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/sshkeys"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/tfvars"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

// realRoot finds the repository root from the test working directory.
func realRoot(t *testing.T) string {
	t.Helper()
	d, _ := os.Getwd()
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(d, "examples", "aws", "variables.tf")); err == nil {
			return d
		}
		d = filepath.Dir(d)
	}
	t.Fatal("repo root not found")
	return ""
}

func writeFile(t *testing.T, p string, b []byte, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, b, mode); err != nil {
		t.Fatal(err)
	}
}

// formsServer builds a temp repo (variables.tf copies, ui.yaml, stub
// scripts) with cluster "demo" on provider aws.
func formsServer(t *testing.T, costScript string) (*Server, *http.Cookie, string) {
	t.Helper()
	root, repo := realRoot(t), t.TempDir()
	for _, p := range []string{"aws", "evroc", "exoscale", "vultr"} {
		b, err := os.ReadFile(filepath.Join(root, "examples", p, "variables.tf"))
		if err != nil {
			t.Fatal(err)
		}
		writeFile(t, filepath.Join(repo, "examples", p, "variables.tf"), b, 0o644)
		writeFile(t, filepath.Join(repo, "examples", p, "deploy.sh"), nil, 0o755)
	}
	ui, _ := os.ReadFile(filepath.Join(root, "tools", "webui", "ui.yaml"))
	writeFile(t, filepath.Join(repo, "tools", "webui", "ui.yaml"), ui, 0o644)
	cost := filepath.Join(repo, "cost")
	if costScript == "" {
		costScript = "echo '{}'"
	}
	writeFile(t, cost, []byte("#!/bin/sh\n"+costScript+"\n"), 0o755)
	writeFile(t, filepath.Join(repo, "clusters", "demo", ".provider"), []byte("aws\n"), 0o600)
	s, err := New(Config{Repo: repo, Token: tok, CostBin: cost, AllowedHosts: []string{"127.0.0.1"}})
	if err != nil {
		t.Fatal(err)
	}
	return s, session(t, s), filepath.Join(repo, "clusters", "demo", "terraform.tfvars")
}

func readVars(t *testing.T, p string) map[string]any {
	t.Helper()
	m, err := tfvars.Read(p)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func getPage(s *Server, target string, c *http.Cookie) (int, string) {
	rr := do(s, "GET", target, nil, c)
	return rr.Code, rr.Body.String()
}

func validForm(t *testing.T) url.Values {
	t.Helper()
	pub, _, err := sshkeys.Generate("test")
	if err != nil {
		t.Fatal(err)
	}
	return url.Values{
		"f_cluster_name":                    {"demo-cluster"},
		"f_region":                          {"us-east-1"},
		"f_admin_cidrs":                     {"203.0.113.7/32\r\n198.51.100.0/24\r\n"},
		"f_ssh_authorized_keys":             {pub.Line},
		"f_ssh_authorized_keys__listed":     {"github.com/alice|" + pub.Line},
		"f_root_password_hash":              {"rootpass1"},
		"f_root_password_hash.confirm":      {"rootpass1"},
		"f_node_user_password_hash":         {"nodepass2"},
		"f_node_user_password_hash.confirm": {"nodepass2"},
		"f_gpu_pools.type":                  {"g5.xlarge"},
		"f_gpu_pools.count":                 {"2"},
		"f_control_plane_count":             {"3"},
		"f_api_host":                        {"k8s.example.com"},
		"f_components":                      {"rancher\naif-operator\n"},
		"f_tags":                            {`{"team": "ai"}`},
		"f_deploy_nodes":                    {"0", "1"},
		"f_keep_build_artifacts":            {"0"},
	}
}

func TestEditFormRenders(t *testing.T) {
	s, c, _ := formsServer(t, "")
	code, body := getPage(s, "/clusters/demo/edit", c)
	if code != 200 {
		t.Fatalf("%d %s", code, body)
	}
	for _, want := range []string{
		`name="f_region"`, `id="cidr-f_admin_cidrs"`, `class="sshkeys"`, `name="f_root_password_hash.confirm"`,
		`name="f_gpu_pools.type"`, "Advanced settings", `name="f_control_plane_count"`,
		`placeholder="3"`, `name="f_tags"`, `hx-post="/clusters/demo/cost"`, "Required before a deploy",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %q", want)
		}
	}
	if strings.Contains(body, "f_image_rebuild") || strings.Contains(body, "advanced settings changed") {
		t.Error("managed field or marker shown on an empty cluster")
	}
	if code, _ := getPage(s, "/clusters/none/edit", c); code != 404 {
		t.Errorf("unknown cluster: %d", code)
	}
}

func TestEditSaveWritesOnlyChanges(t *testing.T) {
	s, c, path := formsServer(t, "")
	rr := post(s, "/clusters/demo/edit", validForm(t), c)
	if rr.Code != http.StatusSeeOther {
		t.Fatalf("%d %s", rr.Code, rr.Body)
	}
	m := readVars(t, path)
	if m["region"] != "us-east-1" || m["api_host"] != "k8s.example.com" || m["deploy_nodes"] != false && m["deploy_nodes"] != nil {
		t.Errorf("values: %#v", m)
	}
	if _, ok := m["control_plane_count"]; ok {
		t.Error("default control_plane_count written")
	}
	if _, ok := m["keep_build_artifacts"]; ok {
		t.Error("default bool written")
	}
	if m["cluster_name"] != "demo-cluster" {
		t.Errorf("cluster_name %v", m["cluster_name"])
	}
	cidrs, _ := m["admin_cidrs"].([]any)
	if len(cidrs) != 2 || cidrs[0] != "203.0.113.7/32" {
		t.Errorf("cidrs %#v", m["admin_cidrs"])
	}
	gpu, _ := m["gpu_pools"].(map[string]any)["gpu"].(map[string]any)
	if gpu["instance_type"] != "g5.xlarge" || gpu["count"] != float64(2) {
		t.Errorf("gpu %#v", m["gpu_pools"])
	}
	if tags, _ := m["tags"].(map[string]any); tags["team"] != "ai" {
		t.Errorf("tags %#v", m["tags"])
	}
	rh, _ := m["root_password_hash"].(string)
	nh, _ := m["node_user_password_hash"].(string)
	if !passhash.Verify("rootpass1", rh) || !passhash.Verify("nodepass2", nh) {
		t.Error("hashes do not verify")
	}
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "rootpass1") || strings.Contains(string(raw), "nodepass2") {
		t.Error("plain password in file")
	}
	if !strings.Contains(string(raw), "# from github.com/alice.keys") {
		t.Errorf("github comment missing:\n%s", raw)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", st.Mode())
	}

	// Reload: marker for changed advanced values, github source restored.
	_, body := getPage(s, "/clusters/demo/edit", c)
	if !strings.Contains(body, "advanced settings changed") || !strings.Contains(body, "github.com/alice") {
		t.Error("marker or source missing after save")
	}
	if strings.Contains(body, rh) || strings.Contains(body, "rootpass1") {
		t.Error("secret rendered back")
	}

	// Clearing removes; unchanged secrets stay when inputs are empty.
	f := validForm(t)
	f.Set("f_api_host", "")
	f.Set("f_root_password_hash", "")
	f.Set("f_root_password_hash.confirm", "")
	f.Set("f_node_user_password_hash", "")
	f.Set("f_node_user_password_hash.confirm", "")
	f.Set("f_gpu_pools.type", "")
	if rr := post(s, "/clusters/demo/edit", f, c); rr.Code != http.StatusSeeOther {
		t.Fatalf("%d %s", rr.Code, rr.Body)
	}
	m2 := readVars(t, path)
	if _, ok := m2["api_host"]; ok {
		t.Error("api_host not removed")
	}
	if _, ok := m2["gpu_pools"]; ok {
		t.Error("gpu_pools not removed")
	}
	if m2["root_password_hash"] != rh || m2["node_user_password_hash"] != nh {
		t.Error("stored hashes changed")
	}
}

func TestEditValidationErrors(t *testing.T) {
	s, c, path := formsServer(t, "")
	cases := map[string]struct {
		set  url.Values
		want string
	}{
		"bad cidr":       {url.Values{"f_admin_cidrs": {"not-a-cidr"}}, "is not a CIDR"},
		"bad number":     {url.Values{"f_control_plane_count": {"three"}}, "not a number"},
		"bad json":       {url.Values{"f_tags": {"{nope"}}, "invalid JSON"},
		"json type":      {url.Values{"f_tags": {`{"a": {"b": 1}}`}}, "does not match type"},
		"mismatch":       {url.Values{"f_root_password_hash": {"aaaa"}, "f_root_password_hash.confirm": {"bbbb"}}, "do not match"},
		"same passwords": {url.Values{"f_root_password_hash": {"same"}, "f_root_password_hash.confirm": {"same"}, "f_node_user_password_hash": {"same"}, "f_node_user_password_hash.confirm": {"same"}}, "must differ"},
		"private key":    {url.Values{"f_ssh_authorized_keys": {"-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"}}, "private key"},
		"gpu count":      {url.Values{"f_gpu_pools.type": {"g5"}, "f_gpu_pools.count": {"0"}}, "count must be"},
	}
	for name, tc := range cases {
		f := url.Values{}
		for k, v := range tc.set {
			f[k] = v
		}
		rr := post(s, "/clusters/demo/edit", f, c)
		if rr.Code != http.StatusUnprocessableEntity || !strings.Contains(rr.Body.String(), tc.want) {
			t.Errorf("%s: %d want %q", name, rr.Code, tc.want)
			continue
		}
		// The submitted text comes back in the form.
		for _, k := range []string{"f_admin_cidrs", "f_control_plane_count", "f_tags"} {
			if v, ok := tc.set[k]; ok && !strings.Contains(rr.Body.String(), strings.ReplaceAll(strings.ReplaceAll(v[0], `"`, "&#34;"), "{", "{")) {
				t.Errorf("%s: value for %s not re-rendered", name, k)
			}
		}
	}
	if _, err := os.Stat(path); err == nil {
		if b, _ := os.ReadFile(path); len(b) != 0 {
			t.Error("file written despite errors")
		}
	}
}

func TestStoredHashDiffers(t *testing.T) {
	s, c, path := formsServer(t, "")
	h, _ := passhash.Hash("shared")
	if err := tfvars.Write(path, map[string]any{"root_password_hash": h}, nil); err != nil {
		t.Fatal(err)
	}
	f := url.Values{"f_node_user_password_hash": {"shared"}, "f_node_user_password_hash.confirm": {"shared"}}
	if rr := post(s, "/clusters/demo/edit", f, c); rr.Code != http.StatusUnprocessableEntity || !strings.Contains(rr.Body.String(), "must differ") {
		t.Fatalf("%d", rr.Code)
	}
}

func TestSensitiveFields(t *testing.T) {
	s, c, path := formsServer(t, "")
	if rr := post(s, "/clusters/demo/edit", url.Values{"f_appco_password": {"S3cr3t-Value"}}, c); rr.Code != http.StatusSeeOther {
		t.Fatalf("%d", rr.Code)
	}
	if readVars(t, path)["appco_password"] != "S3cr3t-Value" {
		t.Fatal("not stored")
	}
	_, body := getPage(s, "/clusters/demo/edit", c)
	if strings.Contains(body, "S3cr3t-Value") || !strings.Contains(body, `class="badge set"`) {
		t.Error("secret shown or status missing")
	}
	post(s, "/clusters/demo/edit", url.Values{"f_appco_password": {""}}, c)
	if readVars(t, path)["appco_password"] != "S3cr3t-Value" {
		t.Error("empty input must keep the stored value")
	}
	post(s, "/clusters/demo/edit", url.Values{"f_appco_password": {""}, "f_appco_password.clear": {"1"}}, c)
	if _, ok := readVars(t, path)["appco_password"]; ok {
		t.Error("clear did not remove")
	}
}

func TestAbsentFieldsAreKept(t *testing.T) {
	s, c, path := formsServer(t, "")
	_ = tfvars.Write(path, map[string]any{
		"api_host": "x.example.com", "tags": map[string]any{"a": "b"},
		"gpu_pools": map[string]any{"other": map[string]any{"instance_type": "p4", "count": 1}},
	}, nil)
	if rr := post(s, "/clusters/demo/edit", url.Values{"f_cluster_name": {"z"}}, c); rr.Code != http.StatusSeeOther {
		t.Fatalf("%d", rr.Code)
	}
	m := readVars(t, path)
	if m["api_host"] != "x.example.com" || m["cluster_name"] != "z" || m["tags"] == nil || m["gpu_pools"] == nil {
		t.Errorf("%#v", m)
	}
	// Adding the gpu pool keeps other pools; clearing it keeps them too.
	f := url.Values{"f_gpu_pools.type": {"g5"}, "f_gpu_pools.count": {"1"}}
	post(s, "/clusters/demo/edit", f, c)
	pools := readVars(t, path)["gpu_pools"].(map[string]any)
	if len(pools) != 2 {
		t.Errorf("pools %#v", pools)
	}
	post(s, "/clusters/demo/edit", url.Values{"f_gpu_pools.type": {""}}, c)
	pools = readVars(t, path)["gpu_pools"].(map[string]any)
	if len(pools) != 1 || pools["other"] == nil {
		t.Errorf("pools after clear %#v", pools)
	}
}

func TestProfileLayerDefaults(t *testing.T) {
	s, c, path := formsServer(t, "")
	cd := s.Cfg.ClustersDir()
	_ = tfvars.Write(filepath.Join(cd, "common-all.tfvars"), map[string]any{"api_host": "common.example.com"}, nil)
	_, body := getPage(s, "/clusters/demo/edit", c)
	if !strings.Contains(body, `placeholder="common.example.com"`) || !strings.Contains(body, "comes from the account profile") {
		t.Error("profile default not shown")
	}
	// Submitting the same value keeps the cluster layer clean.
	post(s, "/clusters/demo/edit", url.Values{"f_api_host": {"common.example.com"}}, c)
	if _, ok := readVars(t, path)["api_host"]; ok {
		t.Error("value equal to the profile default written to the cluster layer")
	}
}

func TestEditRefusedWhileRunning(t *testing.T) {
	s, c, _ := formsServer(t, "")
	lock := filepath.Join(s.Cfg.ClustersDir(), "demo", ".deploy", "webui.lock")
	writeFile(t, lock, []byte(strconv.Itoa(os.Getpid())+" 1 deploy "+workspace.Instance+"\n"), 0o600)
	if rr := post(s, "/clusters/demo/edit", url.Values{"f_cluster_name": {"x"}}, c); rr.Code != http.StatusConflict {
		t.Fatalf("%d", rr.Code)
	}
}

func itoa(n int) string {
	return strings.TrimSpace(strings.Join([]string{string(rune('0' + n%10))}, "")) + ""
}

func TestCostFragment(t *testing.T) {
	script := `
while [ $# -gt 0 ]; do
  if [ "$1" = "--var-file" ]; then
    case "$2" in */terraform.tfvars) grep -q password "$2" && exit 9; grep -q 'control_plane_count *= *5' "$2" || exit 8;; esac
  fi
  shift
done
cat <<'JSON'
{"provider":"aws","region":"us-east-1","currency":"USD","durations":["1h","30d"],"totals":{"1h":1.5,"30d":1080},
 "build_only_totals":{"1h":0.2,"30d":0.2},"incomplete":false,"notes":[],"warnings":[],"excluded":[{"resource":"data transfer","reason":"traffic-dependent"}],
 "resources":[{"resource":"control plane","role":"control_plane","qty":5,"rate_id":"m7i.xlarge","hourly":0.2,"build_only":false,"costs":{"1h":1}}],
 "disclaimer":"ESTIMATE ONLY"}
JSON`
	s, c, path := formsServer(t, script)
	f := url.Values{"f_control_plane_count": {"5"}, "f_root_password_hash": {"abc"}, "f_root_password_hash.confirm": {"abc"}, "f_appco_password": {"pw"}}
	rr := post(s, "/clusters/demo/cost", f, c)
	b := rr.Body.String()
	if rr.Code != 200 || !strings.Contains(b, "1080.00") || !strings.Contains(b, "m7i.xlarge") || !strings.Contains(b, "ESTIMATE ONLY") {
		t.Fatalf("%d %s", rr.Code, b)
	}
	if strings.Contains(b, "<html") {
		t.Error("fragment wrapped in layout")
	}
	if _, err := os.Stat(path); err == nil {
		t.Error("cost run saved settings")
	}
	// Invalid form: no estimate, no run.
	rr = post(s, "/clusters/demo/cost", url.Values{"f_control_plane_count": {"x"}}, c)
	if !strings.Contains(rr.Body.String(), "Fix the form errors") {
		t.Errorf("%s", rr.Body)
	}
	// Failing tool: message, not a 500.
	s2, c2, _ := formsServer(t, "echo 'region is required' >&2; exit 3")
	rr = post(s2, "/clusters/demo/cost", url.Values{}, c2)
	if rr.Code != 200 || !strings.Contains(rr.Body.String(), "region is required") {
		t.Errorf("%d %s", rr.Code, rr.Body)
	}
}

// worker_pools uses optional(T, default): the type must still validate JSON.
func TestCheckTypeOptionalDefaults(t *testing.T) {
	root := realRoot(t)
	b, err := os.ReadFile(filepath.Join(root, "modules", "common", "variables-common.tf"))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`(?s)variable "worker_pools" \{\s*type = (map\(object\(\{.*?\}\)\))`).FindSubmatch(b)
	if m == nil {
		t.Fatal("worker_pools type not found")
	}
	typ := string(m[1])
	if err := checkType(typ, `{"w": {"instance_type": "m5.large"}}`); err != nil {
		t.Fatalf("valid value rejected: %v", err)
	}
	if err := checkType(typ, `{"w": {"instance_type": "m5.large", "count": 2, "public_ip": true}}`); err != nil {
		t.Fatalf("valid full value rejected: %v", err)
	}
	if err := checkType(typ, `{"w": {"count": 2}}`); err == nil {
		t.Fatal("missing instance_type accepted")
	}
	if err := checkType(typ, `{"w": {"instance_type": {"x": 1}}}`); err == nil {
		t.Fatal("wrong attribute type accepted")
	}
}

func TestSaveWithExistingWorkerPools(t *testing.T) {
	s, c, path := formsServer(t, "")
	pools := map[string]any{"w": map[string]any{"instance_type": "m5.large", "count": 2}}
	_ = tfvars.Write(path, map[string]any{"worker_pools": pools}, nil)
	_, body := getPage(s, "/clusters/demo/edit", c)
	m := regexp.MustCompile(`(?s)<textarea[^>]*name="f_worker_pools"[^>]*>(.*?)</textarea>`).FindStringSubmatch(body)
	if m == nil {
		t.Fatalf("no worker_pools input")
	}
	rr := post(s, "/clusters/demo/edit", url.Values{"f_worker_pools": {html.UnescapeString(m[1])}, "f_cluster_name": {"z"}}, c)
	if rr.Code != http.StatusSeeOther {
		t.Fatalf("save failed: %d %s", rr.Code, rr.Body)
	}
	got := readVars(t, path)
	if got["cluster_name"] != "z" || got["worker_pools"] == nil {
		t.Fatalf("%#v", got)
	}
}

func TestSSHKeysFromCommonLayerWriteNothing(t *testing.T) {
	s, c, path := formsServer(t, "")
	pub, _, _ := sshkeys.Generate("c")
	cd := s.Cfg.ClustersDir()
	_ = tfvars.Write(filepath.Join(cd, "common-all.tfvars"), map[string]any{"ssh_authorized_keys": []any{pub.Line}}, nil)
	f := url.Values{"f_ssh_authorized_keys": {pub.Line}, "f_ssh_authorized_keys__listed": {"saved|" + pub.Line}}
	if rr := post(s, "/clusters/demo/edit", f, c); rr.Code != http.StatusSeeOther {
		t.Fatalf("%d %s", rr.Code, rr.Body)
	}
	if _, ok := readVars(t, path)["ssh_authorized_keys"]; ok {
		t.Fatal("keys equal to the profile written to the cluster layer")
	}
	// A different selection is written.
	other, _, _ := sshkeys.Generate("d")
	f = url.Values{"f_ssh_authorized_keys": {other.Line}, "f_ssh_authorized_keys__listed": {"paste|" + other.Line}}
	post(s, "/clusters/demo/edit", f, c)
	if _, ok := readVars(t, path)["ssh_authorized_keys"]; !ok {
		t.Fatal("different keys not written")
	}
}

func TestGPUPoolsFromCommonLayerPreserved(t *testing.T) {
	s, c, path := formsServer(t, "")
	cd := s.Cfg.ClustersDir()
	common := map[string]any{"gpu_pools": map[string]any{"other": map[string]any{"instance_type": "p4", "count": 1}}}
	_ = tfvars.Write(filepath.Join(cd, "common-all.tfvars"), common, nil)
	// Unchanged (empty gpu) form: nothing written.
	post(s, "/clusters/demo/edit", url.Values{"f_gpu_pools.type": {""}, "f_gpu_pools.count": {""}}, c)
	if _, ok := readVars(t, path)["gpu_pools"]; ok {
		t.Fatal("gpu_pools written although equal to the profile")
	}
	// Adding the gpu pool keeps the common pool.
	post(s, "/clusters/demo/edit", url.Values{"f_gpu_pools.type": {"g5"}, "f_gpu_pools.count": {"2"}}, c)
	pools, _ := readVars(t, path)["gpu_pools"].(map[string]any)
	if len(pools) != 2 || pools["other"] == nil || pools["gpu"] == nil {
		t.Fatalf("pools %#v", pools)
	}
	// Clearing it returns to the profile value.
	post(s, "/clusters/demo/edit", url.Values{"f_gpu_pools.type": {""}}, c)
	if _, ok := readVars(t, path)["gpu_pools"]; ok {
		t.Fatal("gpu_pools not removed after clearing")
	}
}

func TestParseCIDRs(t *testing.T) {
	got, err := parseCIDRs("95.61.89.11/32, 85.86.67.10/32\n10.0.0.0/8 192.0.2.7\n\n2001:db8::1")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"95.61.89.11/32", "85.86.67.10/32", "10.0.0.0/8", "192.0.2.7/32", "2001:db8::1/128"}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v", got)
	}
	if _, err := parseCIDRs("10.0.0.0/8, nope"); err == nil || !strings.Contains(err.Error(), `"nope"`) {
		t.Fatalf("err = %v", err)
	}
}

// Every ui.yaml example must satisfy the variable's type.
func TestUIExamplesMatchTypes(t *testing.T) {
	root := realRoot(t)
	n := 0
	for _, p := range schema.Providers(root) {
		fields, err := schema.Load(root, p)
		if err != nil {
			t.Fatal(err)
		}
		for _, f := range fields {
			if f.Example == "" {
				continue
			}
			n++
			if err := checkType(f.Type, f.Example); err != nil {
				t.Errorf("%s %s: %v", p, f.Name, err)
			}
		}
	}
	if n == 0 {
		t.Fatal("no examples found")
	}
}
