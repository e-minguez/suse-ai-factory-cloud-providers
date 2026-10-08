package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"unicode"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/ext/typeexpr"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/zclconf/go-cty/cty/convert"
	ctyjson "github.com/zclconf/go-cty/cty/json"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/cost"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/creds"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/passhash"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/schema"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/sshkeys"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/tfvars"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

const (
	editPage   = "cluster_edit.html"
	formPrefix = "f_"
	sshField   = "ssh_authorized_keys"
	gpuPool    = "gpu"
	githubSrc  = "github.com/"
)

// routesForms registers the cluster edit form and the live cost fragment.
func (s *Server) routesForms(mux *http.ServeMux) {
	mux.HandleFunc("GET /clusters/{name}/edit", s.handleEditForm)
	mux.HandleFunc("POST /clusters/{name}/edit", s.handleEditSave)
	mux.HandleFunc("POST /clusters/{name}/cost", s.handleCost)
}

// fieldView is what _field.html renders for one variable.
type fieldView struct {
	schema.Field
	Input       string // text of the input (empty = default applies)
	Placeholder string
	Set         bool // a value exists (sensitive fields show "set")
	Own         bool // the cluster layer holds a value
	Checked     bool
	Error       string
	FromProfile bool // a common layer sets the default
	GPUType     string
	GPUCount    string
	GPUOthers   int // other pools kept untouched
	CIDR        CIDRWidget
	SSH         SSHKeysWidget
	Confirm     bool // password_hash: second input
	Choices     []string
}

type groupView struct {
	Title   string
	Fields  []fieldView
	Changed int
}

type formView struct {
	Cluster         *workspace.Cluster
	Provider        string
	Basic           []fieldView
	Optional        []fieldView
	OptionalOpen    bool
	Groups          []groupView
	AdvancedChanged int
	AdvancedOpen    bool
	Errors          []string
	Missing         []string
	Disabled        bool
}

// outcome of parsing one field from the submitted form.
type outcome struct {
	kind   byte // 0 keep, 's' set, 'r' remove
	val    any
	err    string
	raw    string
	ssh    *SSHKeysWidget
	rawGPU [2]string
}

type formCtx struct {
	s        *Server
	cluster  *workspace.Cluster
	fields   []schema.Field
	stored   map[string]any // cluster layer
	layered  map[string]any // common layers
	pending  map[string]any // stored + form changes
	outcomes map[string]outcome
	srcs     map[string]string // ssh key line -> source
}

func (s *Server) loadCtx(w http.ResponseWriter, r *http.Request) (*formCtx, bool) {
	c, err := s.WS.Get(r.PathValue("name"))
	if err != nil {
		s.errorPage(w, r, http.StatusNotFound, "Cluster not found", "")
		return nil, false
	}
	fields, err := schema.Load(s.Cfg.Repo, c.Provider)
	if err != nil {
		s.errorPage(w, r, http.StatusInternalServerError, "Cannot load the variable schema", err.Error())
		return nil, false
	}
	cd := s.Cfg.ClustersDir()
	stored, err := tfvars.Read(tfvars.Path(cd, c.Provider, c.Name, tfvars.LayerCluster))
	if err != nil {
		s.errorPage(w, r, http.StatusInternalServerError, "Cannot read the cluster settings", err.Error())
		return nil, false
	}
	layered := map[string]any{}
	for _, l := range []tfvars.Layer{tfvars.LayerCommonAll, tfvars.LayerCommonProvider} {
		m, err := tfvars.Read(tfvars.Path(cd, c.Provider, c.Name, l))
		if err != nil {
			s.errorPage(w, r, http.StatusInternalServerError, "Cannot read the account profile settings", err.Error())
			return nil, false
		}
		for k, v := range m {
			layered[k] = v
		}
	}
	fc := &formCtx{s: s, cluster: c, fields: fields, stored: stored, layered: layered, outcomes: map[string]outcome{}}
	fc.pending = maps(stored)
	return fc, true
}

func maps(m map[string]any) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

// baseline is the value that applies when the cluster layer sets nothing.
func (fc *formCtx) baseline(f schema.Field) any {
	if v, ok := fc.layered[f.Name]; ok {
		return v
	}
	return f.Default
}

func same(a, b any) bool {
	ja, _ := json.Marshal(a)
	jb, _ := json.Marshal(b)
	return bytes.Equal(ja, jb)
}

func (s *Server) handleEditForm(w http.ResponseWriter, r *http.Request) {
	fc, ok := s.loadCtx(w, r)
	if !ok {
		return
	}
	s.renderForm(w, r, http.StatusOK, fc)
}

func (s *Server) handleEditSave(w http.ResponseWriter, r *http.Request) {
	fc, ok := s.loadCtx(w, r)
	if !ok {
		return
	}
	if fc.cluster.Status == workspace.StatusRunning {
		s.errorPage(w, r, http.StatusConflict, "A job is running", "Wait for it to finish before editing the settings.")
		return
	}
	if !fc.parseForm(w, r) {
		return
	}
	if len(fc.errors()) > 0 {
		s.renderForm(w, r, http.StatusUnprocessableEntity, fc)
		return
	}
	if err := fc.save(); err != nil {
		pg := s.page(w, r, "clusters", "Edit "+fc.cluster.Name, nil)
		pg.Err = "Saving failed: " + err.Error()
		fc.renderWith(w, http.StatusInternalServerError, pg)
		return
	}
	setFlash(w, "ok", "Settings saved.")
	http.Redirect(w, r, "/clusters/"+fc.cluster.Name+"/edit", http.StatusSeeOther)
}

// parseForm fills fc.outcomes and fc.pending from the submitted form.
func (fc *formCtx) parseForm(w http.ResponseWriter, r *http.Request) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxFormBytes)
	if err := r.ParseForm(); err != nil {
		fc.s.errorPage(w, r, http.StatusBadRequest, "Invalid form submission", "")
		return false
	}
	fc.srcs = map[string]string{}
	for _, f := range fc.fields {
		if f.Managed {
			continue
		}
		o := fc.parseField(r, f)
		fc.outcomes[f.Name] = o
		switch o.kind {
		case 's':
			fc.pending[f.Name] = o.val
		case 'r':
			delete(fc.pending, f.Name)
		}
	}
	return true
}

func (fc *formCtx) errors() []string {
	var out []string
	for _, f := range fc.fields {
		if o := fc.outcomes[f.Name]; o.err != "" {
			out = append(out, f.Label+": "+o.err)
		}
	}
	return out
}

func (fc *formCtx) save() error {
	var remove []string
	set := map[string]any{}
	for _, f := range fc.fields {
		o := fc.outcomes[f.Name]
		switch o.kind {
		case 's':
			set[f.Name] = o.val
		case 'r':
			remove = append(remove, f.Name)
		}
	}
	path := tfvars.Path(fc.s.Cfg.ClustersDir(), fc.cluster.Provider, fc.cluster.Name, tfvars.LayerCluster)
	if err := tfvars.Write(path, set, remove); err != nil {
		return err
	}
	if o, ok := fc.outcomes[sshField]; ok && o.ssh != nil {
		return setGitHubComment(path, o.ssh, o.kind == 's')
	}
	return nil
}

// setGitHubComment records the GitHub users the stored keys came from.
func setGitHubComment(path string, w *SSHKeysWidget, present bool) error {
	var lines []string
	for _, u := range w.GitHubUsers() {
		used := false
		for _, k := range w.Keys {
			used = used || (k.Source == githubSrc+u && w.IsSelected(k))
		}
		if used {
			lines = append(lines, "# from github.com/"+u+".keys")
		}
	}
	if !present {
		lines = nil
	}
	err := tfvars.SetComment(path, sshField, strings.Join(lines, "\n"))
	if errors.Is(err, tfvars.ErrNoAttribute) {
		return nil
	}
	return err
}

// parseField reads one field from the form. Fields absent from the form
// are kept as stored.
func (fc *formCtx) parseField(r *http.Request, f schema.Field) outcome {
	key := formPrefix + f.Name
	vals, present := r.PostForm[key]
	last := ""
	if len(vals) > 0 {
		last = vals[len(vals)-1]
	}
	base := fc.baseline(f)
	setOrRemove := func(v any) outcome {
		if same(v, base) {
			return outcome{kind: 'r'}
		}
		return outcome{kind: 's', val: v}
	}
	switch f.Widget {
	case "sshkeys":
		return fc.parseSSH(r, f, key)
	case "cidr_list":
		if !present {
			return outcome{}
		}
		lines, err := parseCIDRs(last)
		if err != nil {
			return outcome{raw: last, err: err.Error()}
		}
		if len(lines) == 0 {
			return outcome{kind: 'r'}
		}
		return setOrRemove(toAny(lines))
	case "list":
		if !present {
			return outcome{}
		}
		lines := splitLines(last)
		if len(lines) == 0 {
			return outcome{kind: 'r'}
		}
		return setOrRemove(toAny(lines))
	case "bool":
		if !present {
			return outcome{}
		}
		return setOrRemove(last == "1")
	case "number":
		if !present {
			return outcome{}
		}
		t := strings.TrimSpace(last)
		if t == "" {
			return outcome{kind: 'r'}
		}
		n, err := strconv.ParseFloat(t, 64)
		if err != nil || n != n || n > 1e15 || n < -1e15 {
			return outcome{raw: last, err: "not a number"}
		}
		return setOrRemove(n)
	case "password_hash":
		return fc.parsePasswordHash(r, f, key)
	case "password":
		if r.PostForm.Get(key+".clear") == "1" {
			return outcome{kind: 'r'}
		}
		if t := last; present && t != "" {
			if strings.ContainsAny(t, "\r\n") {
				return outcome{err: "must be a single line"}
			}
			return outcome{kind: 's', val: t}
		}
		return outcome{}
	case "gpu_pool":
		return fc.parseGPU(r, f, key)
	case "json":
		if !present {
			return outcome{}
		}
		return fc.parseJSON(f, last, base)
	}
	// text and select
	if !present {
		return outcome{}
	}
	t := strings.TrimSpace(last)
	if strings.ContainsAny(t, "\r\n") {
		return outcome{raw: last, err: "must be a single line"}
	}
	if t == "" {
		return outcome{kind: 'r'}
	}
	if f.Widget == "select" && !slices.Contains(f.Options, t) && !same(t, fc.stored[f.Name]) {
		return outcome{raw: last, err: "not one of the allowed values"}
	}
	return setOrRemove(t)
}

func toAny(ss []string) []any {
	out := make([]any, len(ss))
	for i, s := range ss {
		out[i] = s
	}
	return out
}

func splitLines(s string) []string {
	var out []string
	for _, l := range strings.Split(strings.ReplaceAll(s, "\r", ""), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			out = append(out, l)
		}
	}
	return out
}

// effective is the value shown for a widget that cannot use a placeholder.
func (fc *formCtx) effective(f schema.Field) any {
	if v, ok := fc.pending[f.Name]; ok {
		return v
	}
	return fc.baseline(f)
}

func (fc *formCtx) parseSSH(r *http.Request, f schema.Field, key string) outcome {
	listed := r.PostForm[key+"__listed"]
	_, selectedPresent := r.PostForm[key]
	if !selectedPresent && len(listed) == 0 && r.PostForm.Get("sshkeys_name") != key {
		return outcome{}
	}
	for _, v := range listed {
		if src, line, ok := strings.Cut(v, "|"); ok {
			fc.srcs[strings.TrimSpace(line)] = src
		}
	}
	w := SSHKeysWidget{Name: key, Provider: fc.cluster.Provider, Selected: map[string]bool{}}
	var lines []string
	for _, l := range r.PostForm[key] {
		src := fc.srcs[strings.TrimSpace(l)]
		if src == "" {
			src = "saved"
		}
		ks, err := sshkeys.Parse(l, src)
		if err != nil {
			return outcome{err: err.Error(), ssh: &w}
		}
		w.Keys = append(w.Keys, ks...)
	}
	w.Keys = sshkeys.Dedupe(w.Keys)
	for _, k := range w.Keys {
		w.Selected[k.Line] = true
		lines = append(lines, k.Line)
	}
	for _, v := range listed {
		src, line, _ := strings.Cut(v, "|")
		if ks, err := sshkeys.Parse(line, src); err == nil {
			for _, k := range ks {
				if !w.Selected[k.Line] {
					w.Keys = append(w.Keys, k)
				}
			}
		}
	}
	w = w.Finalize()
	if w.Over() {
		return outcome{err: fmt.Sprintf("selected keys use %d of %d bytes of user_data; deselect some", w.Total, w.Limit), ssh: &w}
	}
	if len(lines) == 0 || same(toAny(lines), fc.baseline(f)) {
		return outcome{kind: 'r', ssh: &w}
	}
	return outcome{kind: 's', val: toAny(lines), ssh: &w}
}

// otherHash returns the stored hash of the other password variable.
func (fc *formCtx) otherHash(name string) (hash string) {
	other := "node_user_password_hash"
	if name == other {
		other = "root_password_hash"
	}
	if o, ok := fc.outcomes[other]; ok && o.kind == 's' {
		if s, ok := o.val.(string); ok {
			hash = s
		}
	} else if s, ok := fc.effectiveByName(other).(string); ok {
		hash = s
	}
	return hash
}

func (fc *formCtx) effectiveByName(name string) any {
	for _, f := range fc.fields {
		if f.Name == name {
			return fc.effective(f)
		}
	}
	return nil
}

func (fc *formCtx) parsePasswordHash(r *http.Request, f schema.Field, key string) outcome {
	pw, confirm := r.PostForm.Get(key), r.PostForm.Get(key+".confirm")
	if pw == "" && confirm == "" {
		return outcome{}
	}
	if pw != confirm {
		return outcome{err: "the passwords do not match"}
	}
	if strings.ContainsAny(pw, "\r\n") {
		return outcome{err: "must be a single line"}
	}
	if f.Name == "root_password_hash" || f.Name == "node_user_password_hash" {
		other := "node_user_password_hash"
		if f.Name == other {
			other = "root_password_hash"
		}
		// Both changed in this submit: compare the plain texts.
		if opw := r.PostForm.Get(formPrefix + other); opw != "" && opw == pw {
			return outcome{err: "the root and node user passwords must differ"}
		}
		if opw := r.PostForm.Get(formPrefix + other); opw == "" {
			if h := fc.otherHash(f.Name); h != "" && passhash.Verify(pw, h) {
				return outcome{err: "the root and node user passwords must differ"}
			}
		}
	}
	h, err := passhash.Hash(pw)
	if err != nil {
		return outcome{err: "hashing failed"}
	}
	return outcome{kind: 's', val: h}
}

func (fc *formCtx) parseGPU(r *http.Request, f schema.Field, key string) outcome {
	typ, hasT := r.PostForm[key+".type"]
	cnt := r.PostForm.Get(key + ".count")
	if !hasT {
		return outcome{}
	}
	t := strings.TrimSpace(typ[len(typ)-1])
	raw := [2]string{t, cnt}
	pools, _ := fc.effective(f).(map[string]any)
	out := map[string]any{}
	for k, v := range pools {
		out[k] = v
	}
	base := fc.baseline(f)
	finish := func() outcome {
		if same(out, base) || (len(out) == 0 && base == nil) {
			return outcome{kind: 'r'}
		}
		return outcome{kind: 's', val: out}
	}
	if t == "" {
		delete(out, gpuPool)
		return finish()
	}
	if strings.ContainsAny(t, " \r\n\t") {
		return outcome{rawGPU: raw, err: "instance type must not contain spaces"}
	}
	n := 1.0
	if c := strings.TrimSpace(cnt); c != "" {
		v, err := strconv.Atoi(c)
		if err != nil || v < 1 || v > 1000 {
			return outcome{rawGPU: raw, err: "count must be a whole number of at least 1"}
		}
		n = float64(v)
	}
	pool := map[string]any{}
	if old, ok := out[gpuPool].(map[string]any); ok {
		for k, v := range old {
			pool[k] = v
		}
	}
	pool["instance_type"], pool["count"] = t, n
	out[gpuPool] = pool
	return finish()
}

func (fc *formCtx) parseJSON(f schema.Field, text string, base any) outcome {
	t := strings.TrimSpace(text)
	if t == "" {
		return outcome{kind: 'r'}
	}
	var v any
	dec := json.NewDecoder(strings.NewReader(t))
	if err := dec.Decode(&v); err != nil {
		return outcome{raw: text, err: "invalid JSON: " + err.Error()}
	}
	if dec.More() {
		return outcome{raw: text, err: "invalid JSON: trailing data"}
	}
	if err := checkType(f.Type, t); err != nil {
		return outcome{raw: text, err: err.Error()}
	}
	if same(v, base) {
		return outcome{kind: 'r'}
	}
	return outcome{kind: 's', val: v}
}

// checkType validates JSON text against an HCL type expression.
func checkType(typeExpr, text string) error {
	expr, d := hclsyntax.ParseExpression([]byte(typeExpr), "type", hcl.InitialPos)
	if d.HasErrors() {
		return errors.New("unsupported variable type")
	}
	typ, _, d := typeexpr.TypeConstraintWithDefaults(expr)
	if d.HasErrors() {
		return errors.New("unsupported variable type")
	}
	implied, err := ctyjson.ImpliedType([]byte(text))
	if err != nil {
		return fmt.Errorf("invalid JSON: %v", err)
	}
	val, err := ctyjson.Unmarshal([]byte(text), implied)
	if err != nil {
		return fmt.Errorf("invalid JSON: %v", err)
	}
	if _, err := convert.Convert(val, typ); err != nil {
		return fmt.Errorf("does not match type %s: %s", compact(typeExpr), err)
	}
	return nil
}

func compact(s string) string { return strings.Join(strings.Fields(s), " ") }

// ---- view ----

func (fc *formCtx) text(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(t)
	case []any:
		var l []string
		for _, e := range t {
			l = append(l, fc.text(e))
		}
		return strings.Join(l, "\n")
	}
	b, _ := json.MarshalIndent(v, "", "  ")
	return string(b)
}

func (fc *formCtx) view(f schema.Field) fieldView {
	o := fc.outcomes[f.Name]
	_, own := fc.pending[f.Name]
	_, inLayer := fc.layered[f.Name]
	v := fieldView{Field: f, Own: own, FromProfile: inLayer, Error: o.err}
	eff := fc.effective(f)
	v.Set = eff != nil && eff != ""
	base := fc.baseline(f)
	if base != nil && !f.Sensitive {
		v.Placeholder = fc.text(base)
	}
	if f.Widget == "select" {
		v.Choices = append([]string{}, f.Options...)
		if s, ok := eff.(string); ok && s != "" && !slices.Contains(v.Choices, s) {
			v.Choices = append(v.Choices, s)
		}
	}
	shown := func() string {
		if o.err != "" && o.raw != "" {
			return o.raw
		}
		if own {
			return fc.text(fc.pending[f.Name])
		}
		return ""
	}
	switch f.Widget {
	case "bool":
		b, _ := eff.(bool)
		v.Checked = b
	case "cidr_list":
		var vals []string
		if o.err != "" && o.raw != "" {
			vals = splitLines(o.raw)
		} else if l, ok := eff.([]any); ok {
			for _, e := range l {
				vals = append(vals, fc.text(e))
			}
		}
		v.CIDR = CIDRWidget{Name: formPrefix + f.Name, Values: vals}
	case "sshkeys":
		v.SSH = fc.sshView(f, eff, o)
	case "gpu_pool":
		pools, _ := eff.(map[string]any)
		v.GPUOthers = len(pools)
		if p, ok := pools[gpuPool].(map[string]any); ok {
			v.GPUOthers--
			v.GPUType = fc.text(p["instance_type"])
			v.GPUCount = fc.text(p["count"])
		}
		if o.err != "" {
			v.GPUType, v.GPUCount = o.rawGPU[0], o.rawGPU[1]
		}
	case "password", "password_hash":
	default:
		v.Input = shown()
	}
	return v
}

func (fc *formCtx) sshView(f schema.Field, eff any, o outcome) SSHKeysWidget {
	if o.ssh != nil {
		return *o.ssh
	}
	var lines []string
	if l, ok := eff.([]any); ok {
		for _, e := range l {
			if s, ok := e.(string); ok {
				lines = append(lines, s)
			}
		}
	}
	w := NewSSHKeysWidget(formPrefix+f.Name, fc.cluster.Provider, lines)
	// The comment above the attribute names the GitHub origin; with exactly
	// one user all stored keys are attributed to it.
	if f.Name == sshField {
		path := tfvars.Path(fc.s.Cfg.ClustersDir(), fc.cluster.Provider, fc.cluster.Name, tfvars.LayerCluster)
		var users []string
		for _, c := range tfvars.Comments(path, f.Name) {
			if u, ok := strings.CutPrefix(c, "# from github.com/"); ok {
				users = append(users, strings.TrimSuffix(strings.TrimSpace(u), ".keys"))
			}
		}
		if len(users) == 1 {
			for i := range w.Keys {
				w.Keys[i].Source = githubSrc + users[0]
			}
		}
	}
	return w.Finalize()
}

func (fc *formCtx) formView() formView {
	fv := formView{Cluster: fc.cluster, Provider: fc.cluster.Provider, Errors: fc.errors()}
	fv.Missing = missingForDeploy(fc.fields, fc.effective)
	fv.Disabled = fc.cluster.Status == workspace.StatusRunning
	groups := map[string]*groupView{}
	var order []string
	for _, f := range fc.fields {
		if f.Managed {
			continue
		}
		v := fc.view(f)
		switch {
		case f.Basic && f.Collapsed:
			fv.Optional = append(fv.Optional, v)
			fv.OptionalOpen = fv.OptionalOpen || v.Own || v.Error != ""
		case f.Basic:
			fv.Basic = append(fv.Basic, v)
		default:
			g := groups[f.Group]
			if g == nil {
				g = &groupView{Title: f.Group}
				groups[f.Group] = g
				order = append(order, f.Group)
			}
			g.Fields = append(g.Fields, v)
			if v.Own {
				g.Changed++
				fv.AdvancedChanged++
			}
			fv.AdvancedOpen = fv.AdvancedOpen || v.Error != ""
		}
	}
	for _, t := range order {
		fv.Groups = append(fv.Groups, *groups[t])
	}
	return fv
}

func (s *Server) renderForm(w http.ResponseWriter, r *http.Request, code int, fc *formCtx) {
	fc.renderWith(w, code, s.page(w, r, "clusters", "Edit "+fc.cluster.Name, nil))
}

func (fc *formCtx) renderWith(w http.ResponseWriter, code int, pg Page) {
	pg.Data = fc.formView()
	if pg.Title == "" {
		pg.Title = "Edit " + fc.cluster.Name
	}
	fc.s.renderStatus(w, code, editPage, pg)
}

// ---- cost ----

type costReport struct {
	Currency, Provider, Region string
	Durations                  []string
	Totals, BuildOnlyTotals    map[string]float64
	Resources                  []costRow
	Excluded                   []struct{ Resource, Reason string }
	Notes, Warnings            []string
	Incomplete                 bool
	Recurring                  float64
	Disclaimer                 string
}

type costRow struct {
	Resource, Role, Pool string
	RateID               string
	Qty                  float64
	Hourly               float64
	BuildOnly            bool
	Costs                map[string]float64
}

func (s *Server) costFragment(w http.ResponseWriter, data map[string]any) {
	s.renderPartial(w, editPage, "cost", data)
}

func (s *Server) handleCost(w http.ResponseWriter, r *http.Request) {
	fc, ok := s.loadCtx(w, r)
	if !ok {
		return
	}
	if !fc.parseForm(w, r) {
		return
	}
	if errs := fc.errors(); len(errs) > 0 {
		s.costFragment(w, map[string]any{"Error": "Fix the form errors to see an estimate."})
		return
	}
	rep, err := fc.estimate(r.Context())
	if err != nil {
		s.costFragment(w, map[string]any{"Error": "Cost estimate unavailable: " + err.Error()})
		return
	}
	s.costFragment(w, map[string]any{"Report": rep})
}

// estimate runs the cost binary on the unsaved form values. Only
// non-sensitive values go to a throw-away layer next to symlinks to the
// shared common files.
func (fc *formCtx) estimate(ctx context.Context) (*costReport, error) {
	cd := fc.s.Cfg.ClustersDir()
	tmp, err := os.MkdirTemp("", "aif-cost-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)
	p := fc.cluster.Provider
	for _, n := range []string{"common-all.tfvars", "common-" + p + ".tfvars"} {
		if _, err := os.Stat(filepath.Join(cd, n)); err == nil {
			_ = os.Symlink(filepath.Join(cd, n), filepath.Join(tmp, n))
		}
	}
	dir := filepath.Join(tmp, fc.cluster.Name)
	if err := os.Mkdir(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(dir, ".provider"), []byte(p+"\n"), 0o600); err != nil {
		return nil, err
	}
	vals := map[string]any{}
	for _, f := range fc.fields {
		if v, ok := fc.pending[f.Name]; ok && !f.Sensitive && !f.Managed {
			vals[f.Name] = v
		}
	}
	if err := tfvars.Write(filepath.Join(dir, "terraform.tfvars"), vals, nil); err != nil {
		return nil, err
	}
	raw, err := cost.Run(ctx, fc.s.costBin(), fc.s.Cfg.Repo, tmp, fc.cluster.Name,
		workspace.ChildEnv(append([]string{"HOME=" + creds.HomeDir(cd)}, creds.Env(cd, p)...)))
	if err != nil {
		var ce *cost.Error
		if errors.As(err, &ce) && ce.Detail != "" {
			return nil, errors.New(ce.Detail)
		}
		return nil, errors.New("the cost tool failed")
	}
	var rep costReport
	if err := decodeCost(raw, &rep); err != nil {
		return nil, errors.New("unreadable cost report")
	}
	return &rep, nil
}

func (s *Server) costBin() string {
	if s.Cfg.CostBin != "" {
		return s.Cfg.CostBin
	}
	return "cost"
}

func decodeCost(raw []byte, rep *costReport) error {
	var j struct {
		Disclaimer string             `json:"disclaimer"`
		Provider   string             `json:"provider"`
		Region     string             `json:"region"`
		Currency   string             `json:"currency"`
		Durations  []string           `json:"durations"`
		Totals     map[string]float64 `json:"totals"`
		BuildOnly  map[string]float64 `json:"build_only_totals"`
		Recurring  float64            `json:"recurring_after_destroy_per_month"`
		Incomplete bool               `json:"incomplete"`
		Notes      []string           `json:"notes"`
		Warnings   []string           `json:"warnings"`
		Excluded   []struct {
			Resource string `json:"resource"`
			Reason   string `json:"reason"`
		} `json:"excluded"`
		Resources []struct {
			Resource  string             `json:"resource"`
			Role      string             `json:"role"`
			Pool      string             `json:"pool"`
			RateID    string             `json:"rate_id"`
			Qty       float64            `json:"qty"`
			Hourly    float64            `json:"hourly"`
			BuildOnly bool               `json:"build_only"`
			Costs     map[string]float64 `json:"costs"`
		} `json:"resources"`
	}
	if err := json.Unmarshal(raw, &j); err != nil {
		return err
	}
	*rep = costReport{
		Currency: j.Currency, Provider: j.Provider, Region: j.Region, Durations: j.Durations,
		Totals: j.Totals, BuildOnlyTotals: j.BuildOnly, Notes: j.Notes, Warnings: j.Warnings,
		Incomplete: j.Incomplete, Recurring: j.Recurring, Disclaimer: j.Disclaimer,
	}
	for _, e := range j.Excluded {
		rep.Excluded = append(rep.Excluded, struct{ Resource, Reason string }{e.Resource, e.Reason})
	}
	for _, r := range j.Resources {
		rep.Resources = append(rep.Resources, costRow{r.Resource, r.Role, r.Pool, r.RateID, r.Qty, r.Hourly, r.BuildOnly, r.Costs})
	}
	return nil
}

// parseCIDRs accepts CIDRs separated by newlines, commas or spaces; a bare
// address becomes a single-host prefix (/32 or /128).
func parseCIDRs(s string) ([]string, error) {
	var out []string
	for _, t := range strings.FieldsFunc(s, func(r rune) bool { return r == ',' || unicode.IsSpace(r) }) {
		if a, err := netip.ParseAddr(t); err == nil {
			t = netip.PrefixFrom(a, a.BitLen()).String()
		}
		p, err := netip.ParsePrefix(t)
		if err != nil {
			return nil, fmt.Errorf("%q is not a CIDR such as 203.0.113.0/24", t)
		}
		out = append(out, p.String())
	}
	return out, nil
}
