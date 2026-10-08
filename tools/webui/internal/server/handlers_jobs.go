package server

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/creds"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/jobs"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/outputs"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

const (
	sseHeartbeat = 15 * time.Second
	maxLogView   = 4 << 20 // bytes of a log file served (tail)
)

// routesJobs registers deploy/destroy/leftovers actions, job pages and the
// SSE stream, kubeconfig download, log views and the overview panels.
func (s *Server) routesJobs(mux *http.ServeMux) {
	mux.HandleFunc("POST /clusters/{name}/deploy", s.handleDeploy)
	mux.HandleFunc("POST /clusters/{name}/destroy", s.handleDestroy)
	mux.HandleFunc("POST /clusters/{name}/leftovers", s.handleLeftovers)
	mux.HandleFunc("GET /clusters/{name}/leftovers", s.handleLeftoversPanel)
	mux.HandleFunc("POST /clusters/{name}/kubeconfig", s.handleKubeconfig)
	mux.HandleFunc("POST /clusters/{name}/rancher-password", s.handleRancherPassword)
	mux.HandleFunc("GET /clusters/{name}/outputs", s.handleOutputsPanel)
	mux.HandleFunc("GET /clusters/{name}/jobs", s.handleJobsPanel)
	mux.HandleFunc("GET /clusters/{name}/logs", s.handleLogList)
	mux.HandleFunc("GET /clusters/{name}/logs/{ts}/{file}", s.handleLogFile)
	mux.HandleFunc("GET /jobs/{id}", s.handleJobPage)
	mux.HandleFunc("GET /jobs/{id}/events", s.handleJobEvents)
	mux.HandleFunc("POST /jobs/{id}/confirm", s.handleJobConfirm)
	mux.HandleFunc("POST /jobs/{id}/cancel", s.handleJobCancel)
}

func (s *Server) cluster(w http.ResponseWriter, r *http.Request) *workspace.Cluster {
	if s.Jobs == nil {
		s.errorPage(w, r, http.StatusServiceUnavailable, "Jobs are not available", "")
		return nil
	}
	c, err := s.WS.Get(r.PathValue("name"))
	if err != nil {
		s.errorPage(w, r, http.StatusNotFound, "Cluster not found", "")
		return nil
	}
	return c
}

func (s *Server) back(w http.ResponseWriter, r *http.Request, c *workspace.Cluster, kind, msg string) {
	setFlash(w, kind, msg)
	http.Redirect(w, r, "/clusters/"+c.Name, http.StatusSeeOther)
}

func (s *Server) startJob(w http.ResponseWriter, r *http.Request, c *workspace.Cluster, a jobs.Action) {
	j, err := s.Jobs.Start(c.Name, a)
	var mt *jobs.MissingToolError
	switch {
	case errors.Is(err, jobs.ErrBusy):
		s.back(w, r, c, "err", "A job is already running for this cluster.")
	case errors.Is(err, jobs.ErrShuttingDown):
		s.back(w, r, c, "err", "The web UI is shutting down: no new jobs can start. Start it again and retry.")
	case errors.As(err, &mt):
		s.back(w, r, c, "err", "The leftovers check "+mt.Error()+".")
	case err != nil:
		s.back(w, r, c, "err", "Cannot start the job: "+err.Error())
	default:
		http.Redirect(w, r, "/jobs/"+j.ID, http.StatusSeeOther)
	}
}

func (s *Server) handleDeploy(w http.ResponseWriter, r *http.Request) {
	c := s.cluster(w, r)
	if c == nil {
		return
	}
	if m := s.deployBlockers(c); len(m) > 0 {
		s.back(w, r, c, "err", "Deploy not started. Set these first in Edit settings: "+strings.Join(m, ", ")+".")
		return
	}
	a := jobs.ActionDeploy
	if r.FormValue("rebuild") == "on" {
		a = jobs.ActionRebuild
	}
	s.startJob(w, r, c, a)
}

func (s *Server) handleDestroy(w http.ResponseWriter, r *http.Request) {
	c := s.cluster(w, r)
	if c == nil {
		return
	}
	if r.FormValue("confirm") != c.Name {
		s.back(w, r, c, "err", "Destroy not started: type the cluster name to confirm.")
		return
	}
	s.startJob(w, r, c, jobs.ActionDestroy)
}

func (s *Server) handleLeftovers(w http.ResponseWriter, r *http.Request) {
	if c := s.cluster(w, r); c != nil {
		s.startJob(w, r, c, jobs.ActionLeftovers)
	}
}

// leftoverView is what the templates need to offer the leftovers check: the
// button when this host can run it, else the command to run elsewhere.
type leftoverView struct {
	Cluster string
	OK      bool
	Missing string // "aws" or "curl, jq"
	Command string
}

func (s *Server) leftoverInfo(c *workspace.Cluster) leftoverView {
	v := leftoverView{Cluster: c.Name, OK: true}
	if m := jobs.LeftoversMissing(c.Provider); len(m) > 0 {
		v.OK, v.Missing = false, strings.Join(m, ", ")
		v.Command = jobs.LeftoverSpec(s.Cfg.Repo, s.Cfg.ClustersDir(), c.Provider, c.Name).Command(c.Provider)
	}
	return v
}

func (s *Server) handleLeftoversPanel(w http.ResponseWriter, r *http.Request) {
	if c := s.cluster(w, r); c != nil {
		s.renderPartial(w, "cluster.html", "cluster_leftovers", s.leftoverInfo(c))
	}
}

func (s *Server) handleKubeconfig(w http.ResponseWriter, r *http.Request) {
	c := s.cluster(w, r)
	if c == nil {
		return
	}
	b, err := outputs.Kubeconfig(r.Context(), s.Cfg.Repo, c.Dir, s.Jobs.Env(c.Name))
	if err != nil {
		s.back(w, r, c, "err", "Cannot fetch the kubeconfig: "+s.Jobs.Redact(err.Error()))
		return
	}
	h := w.Header()
	h.Set("Content-Type", "application/yaml")
	h.Set("Content-Disposition", `attachment; filename="`+c.Name+`-kubeconfig.yaml"`)
	h.Set("Cache-Control", "no-store")
	_, _ = w.Write(b)
}

// --- overview panels (loaded lazily by htmx) ---

type nodeRow struct{ Name, Role, Pool, PublicIP, PrivateIP, Type string }

type outputsView struct {
	Cluster     string
	Err         string
	Has         bool
	Provider    string
	Region      string
	RancherURL  string
	APIEndpoint string
	Ingress     string
	Jumphost    string
	Nodes       []nodeRow
	SSHHint     string
	NoSSHKey    bool // no stored private key and no SSH agent: kubeconfig and SSH cannot work
}

func str(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func safeURL(u string) string {
	if strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://") {
		return u
	}
	return ""
}

func (s *Server) handleOutputsPanel(w http.ResponseWriter, r *http.Request) {
	c := s.cluster(w, r)
	if c == nil {
		return
	}
	v := outputsView{Cluster: c.Name}
	if !workspace.HasState(c.Dir) {
		s.renderPartial(w, "cluster.html", "cluster_outputs", v)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	out, err := outputs.Get(ctx, c.Dir, s.Jobs.Env(c.Name))
	if err != nil {
		v.Err = s.Jobs.Redact(err.Error())
		s.renderPartial(w, "cluster.html", "cluster_outputs", v)
		return
	}
	v.Has = true
	v.NoSSHKey = !creds.HasSSHKey(s.Cfg.ClustersDir()) && os.Getenv("SSH_AUTH_SOCK") == ""
	v.Provider, v.Region = str(out["provider"]), str(out["region"])
	v.RancherURL = safeURL(str(out["rancher_url"]))
	v.APIEndpoint, v.Ingress = str(out["kubernetes_api_endpoint"]), str(out["ingress_endpoint"])
	if jh, ok := out["jumphost"].(map[string]any); ok {
		v.Jumphost = str(jh["public_ip"])
	}
	first := ""
	if nodes, ok := out["nodes"].(map[string]any); ok {
		for name, n := range nodes {
			m, _ := n.(map[string]any)
			v.Nodes = append(v.Nodes, nodeRow{Name: name, Role: str(m["role"]), Pool: str(m["pool"]),
				PublicIP: str(m["public_ip"]), PrivateIP: str(m["private_ip"]), Type: str(m["instance_type"])})
		}
		sort.Slice(v.Nodes, func(i, j int) bool { return v.Nodes[i].Name < v.Nodes[j].Name })
		if len(v.Nodes) > 0 {
			first = v.Nodes[0].Name
		}
		for name, n := range nodes {
			if m, _ := n.(map[string]any); m["init"] == true {
				first = name
			}
		}
	}
	if first != "" {
		host, _ := os.Hostname()
		v.SSHHint = fmt.Sprintf("docker exec -it %s clusters/%s/ssh.sh %s", host, c.Name, first)
	}
	s.renderPartial(w, "cluster.html", "cluster_outputs", v)
}

type jobRow struct {
	ID, Action, Status, Started, Duration string
}

func rowOf(j *jobs.Job) jobRow {
	in := j.Info()
	end := in.Ended
	if end.IsZero() {
		end = time.Now()
	}
	return jobRow{ID: in.ID, Action: string(in.Action), Status: in.Status,
		Started: in.Started.Format("2006-01-02 15:04:05"), Duration: end.Sub(in.Started).Truncate(time.Second).String()}
}

func (s *Server) handleJobsPanel(w http.ResponseWriter, r *http.Request) {
	c := s.cluster(w, r)
	if c == nil {
		return
	}
	var rows []jobRow
	for _, j := range s.Jobs.List(c.Name) {
		rows = append(rows, rowOf(j))
	}
	last := ""
	if b, err := os.ReadFile(filepath.Join(c.Dir, ".deploy", "webui-last-status")); err == nil {
		last = strings.TrimSpace(string(b))
	}
	s.renderPartial(w, "cluster.html", "cluster_jobs", map[string]any{"Cluster": c.Name, "Jobs": rows, "Last": last})
}

// --- job page, events, control ---

func (s *Server) job(w http.ResponseWriter, r *http.Request) *jobs.Job {
	if s.Jobs == nil {
		s.errorPage(w, r, http.StatusServiceUnavailable, "Jobs are not available", "")
		return nil
	}
	j, ok := s.Jobs.Get(r.PathValue("id"))
	if !ok {
		s.errorPage(w, r, http.StatusNotFound, "Job not found", "Jobs are kept in memory until the web UI restarts.")
		return nil
	}
	return j
}

func (s *Server) handleJobPage(w http.ResponseWriter, r *http.Request) {
	j := s.job(w, r)
	if j == nil {
		return
	}
	in := j.Info()
	s.render(w, "job.html", s.page(w, r, "clusters", string(in.Action)+" "+in.Cluster, map[string]any{"Job": in}))
}

func (s *Server) handleJobConfirm(w http.ResponseWriter, r *http.Request) {
	j := s.job(w, r)
	if j == nil {
		return
	}
	ans := r.FormValue("answer")
	if ans != "yes" && ans != "no" {
		http.Error(w, "answer must be yes or no", http.StatusBadRequest)
		return
	}
	idx, err := strconv.Atoi(r.FormValue("index"))
	if err != nil {
		http.Error(w, "index is required", http.StatusBadRequest)
		return
	}
	s.control(w, r, j, s.Jobs.Confirm(j.ID, idx, ans == "yes"))
}

func (s *Server) handleJobCancel(w http.ResponseWriter, r *http.Request) {
	j := s.job(w, r)
	if j == nil {
		return
	}
	s.control(w, r, j, s.Jobs.Cancel(j.ID))
}

// control answers htmx requests with 204 (the SSE stream updates the page)
// and plain form posts with a redirect back to the job.
func (s *Server) control(w http.ResponseWriter, r *http.Request, j *jobs.Job, err error) {
	switch {
	case errors.Is(err, jobs.ErrStaleConfirm), errors.Is(err, jobs.ErrNoConfirm):
		http.Error(w, "this plan was already answered", http.StatusConflict)
		return
	case err != nil && !errors.Is(err, jobs.ErrFinished):
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if r.Header.Get("HX-Request") != "" {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	http.Redirect(w, r, "/jobs/"+j.ID, http.StatusSeeOther)
}

// --- SSE ---

type lineView struct{ Text, Class string }

type passView struct {
	Index                   int
	Title, Status, Duration string
	Create, Update          int
	Replace, Destroy        int
	HasPlan, NoChanges      bool
	Errors                  []string
}

type resView struct {
	Addr, Action string
	Elapsed      int
}

type doneView struct {
	Cluster, Job, Action, Status string
	ExitCode                     int
	Destroyed                    bool
	Leftovers                    leftoverView
}

type confirmView struct {
	Pending bool
	Index   int
	Job     string
	Title   string
	Plan    *jobs.PlanSummary
}

// jobView folds protocol events into what the page shows.
type jobView struct {
	info                             jobs.Info
	lo                               leftoverView
	passes                           []*passView
	active                           []resView
	completed, errored               int
	plan                             *jobs.PlanSummary
	planTitle                        string
	confirm                          confirmView
	done                             *doneView
	lines                            []lineView
	dPass, dPlan, dRes, dConf, dDone bool
}

func (v *jobView) pass(i int) *passView {
	for _, p := range v.passes {
		if p.Index == i {
			return p
		}
	}
	p := &passView{Index: i, Status: "pending"}
	v.passes = append(v.passes, p)
	return p
}

func (v *jobView) apply(e jobs.Event) {
	if e.Type == "line" {
		v.lines = append(v.lines, lineView{Text: e.Line})
		return
	}
	var d struct {
		Index     int    `json:"index"`
		Total     int    `json:"total"`
		PassTotal int    `json:"pass_total"`
		Title     string `json:"title"`
		Status    string `json:"status"`
		Answer    string `json:"answer"`
		Address   string `json:"address"`
		Action    string `json:"action"`
		Elapsed   int    `json:"elapsed_s"`
		Duration  int    `json:"duration_s"`
		Severity  string `json:"severity"`
		Summary   string `json:"summary"`
		Detail    string `json:"detail"`
		ExitCode  int    `json:"exit_code"`
	}
	if e.Decode(&d) != nil {
		return
	}
	switch e.Type {
	case "start":
		for i := 1; i <= d.PassTotal; i++ {
			v.pass(i)
		}
		v.dPass = true
	case "pass_start":
		p := v.pass(d.Index)
		p.Title, p.Status = d.Title, "running"
		v.active, v.completed, v.errored = nil, 0, 0
		v.dPass, v.dRes = true, true
	case "plan_summary":
		var ps jobs.PlanSummary
		if e.Decode(&ps) == nil {
			p := v.pass(ps.Index)
			p.HasPlan, p.NoChanges = true, ps.NoChanges
			p.Create, p.Update, p.Replace, p.Destroy = ps.Create, ps.Update, len(ps.Replace), len(ps.Destroy)
			v.plan, v.planTitle = &ps, p.Title
			v.dPlan, v.dPass = true, true
		}
	case "confirm_request":
		v.pass(d.Index).Status = "awaiting confirmation"
		v.confirm = confirmView{Pending: true, Index: d.Index, Job: v.info.ID, Plan: v.plan, Title: v.planTitle}
		v.dConf, v.dPass = true, true
	case "confirm_response":
		v.confirm = confirmView{}
		if p := v.pass(d.Index); d.Answer == "yes" {
			p.Status = "running"
		} else {
			p.Status = "aborted"
		}
		v.dConf, v.dPass = true, true
	case "resource":
		v.dRes = true
		idx := -1
		for i, r := range v.active {
			if r.Addr == d.Address {
				idx = i
			}
		}
		switch d.Status {
		case "start", "progress":
			rv := resView{Addr: d.Address, Action: d.Action, Elapsed: d.Elapsed}
			if idx >= 0 {
				v.active[idx] = rv
			} else {
				v.active = append(v.active, rv)
			}
		default:
			if idx >= 0 {
				v.active = append(v.active[:idx], v.active[idx+1:]...)
			}
			if d.Status == "errored" {
				v.errored++
			} else {
				v.completed++
			}
		}
	case "diagnostic":
		msg := d.Summary
		if d.Detail != "" {
			msg += ": " + d.Detail
		}
		p := v.pass(d.Index)
		if d.Severity == "error" && len(p.Errors) < 20 {
			p.Errors = append(p.Errors, msg)
			v.dPass = true
		}
		v.lines = append(v.lines, lineView{Text: d.Severity + ": " + msg, Class: "diag-" + d.Severity})
	case "pass_done":
		p := v.pass(d.Index)
		p.Status = d.Status
		p.Duration = (time.Duration(d.Duration) * time.Second).String()
		v.active = nil
		v.dPass, v.dRes = true, true
	case "done":
		v.done = &doneView{Cluster: v.info.Cluster, Job: v.info.ID, Action: string(v.info.Action),
			Status: d.Status, ExitCode: d.ExitCode, Destroyed: v.info.Action == jobs.ActionDestroy && d.Status == jobs.StatusOK, Leftovers: v.lo}
		v.confirm = confirmView{}
		v.dDone, v.dConf = true, true
		if v.info.Action == jobs.ActionLeftovers {
			v.dPass = false
		}
	}
}

// frag renders a named template of the job page set to a string.
func (s *Server) frag(name string, data any) string {
	rec := &capture{h: http.Header{}, code: http.StatusOK}
	s.renderPartial(rec, "job.html", name, data)
	if rec.code != http.StatusOK {
		return "<div class=\"muted\">render error</div>"
	}
	return rec.buf.String()
}

type capture struct {
	h    http.Header
	buf  bytes.Buffer
	code int
}

func (c *capture) Header() http.Header         { return c.h }
func (c *capture) Write(b []byte) (int, error) { return c.buf.Write(b) }
func (c *capture) WriteHeader(code int)        { c.code = code }

func writeSSE(w http.ResponseWriter, id int, event, html string) {
	var b strings.Builder
	if id > 0 {
		b.WriteString("id: " + strconv.Itoa(id) + "\n")
	}
	b.WriteString("event: " + event + "\n")
	for _, l := range strings.Split(strings.TrimRight(html, "\n"), "\n") {
		b.WriteString("data: " + l + "\n")
	}
	b.WriteString("\n")
	_, _ = w.Write([]byte(b.String()))
}

// flush writes the accumulated view changes as SSE events and resets them.
func (s *Server) flushView(w http.ResponseWriter, fl http.Flusher, v *jobView, id int) {
	if len(v.lines) > 0 {
		writeSSE(w, id, "line", s.frag("job_lines", v.lines))
		v.lines = nil
	}
	if v.dPass {
		writeSSE(w, id, "pass", s.frag("job_passes", v.passes))
		v.dPass = false
	}
	if v.dPlan {
		writeSSE(w, id, "plan", s.frag("job_plan", map[string]any{"Plan": v.plan, "Title": v.planTitle}))
		v.dPlan = false
	}
	if v.dRes {
		writeSSE(w, id, "resource", s.frag("job_resources", map[string]any{
			"Active": v.active, "Completed": v.completed, "Errored": v.errored}))
		v.dRes = false
	}
	if v.dConf {
		writeSSE(w, id, "confirm", s.frag("job_confirm", v.confirm))
		v.dConf = false
	}
	if v.dDone {
		writeSSE(w, id, "done", s.frag("job_done", v.done))
		v.dDone = false
	}
	fl.Flush()
}

func (s *Server) handleJobEvents(w http.ResponseWriter, r *http.Request) {
	j := s.job(w, r)
	if j == nil {
		return
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Accel-Buffering", "no")
	after, _ := strconv.Atoi(r.Header.Get("Last-Event-ID"))
	replay, ch, cancel := s.Jobs.Subscribe(j.ID)
	defer cancel()
	v := &jobView{info: j.Info()}
	if c, err := s.WS.Get(v.info.Cluster); err == nil {
		v.lo = s.leftoverInfo(c)
	}
	// The view always replays from the start so reconnects keep state; only
	// output after Last-Event-ID is sent again as lines.
	last := 0
	for _, e := range replay {
		n := len(v.lines)
		v.apply(e)
		if e.Seq <= after && len(v.lines) > n {
			v.lines = v.lines[:n]
		}
		last = e.Seq
	}
	w.WriteHeader(http.StatusOK)
	s.flushView(w, fl, v, last)
	if v.done != nil {
		return
	}
	tick := time.NewTicker(sseHeartbeat)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-tick.C:
			_, _ = w.Write([]byte(": keepalive\n\n"))
			fl.Flush()
		case e, ok := <-ch:
			if !ok {
				return
			}
			last = e.Seq
			v.apply(e)
			for more := true; more && len(v.lines) < 500; {
				select {
				case e, ok = <-ch:
					if !ok {
						more = false
						break
					}
					last = e.Seq
					v.apply(e)
				default:
					more = false
				}
			}
			s.flushView(w, fl, v, last)
			if v.done != nil {
				return
			}
		}
	}
}

// --- logs ---

type logDir struct {
	TS    string
	Files []string
}

// listLogs returns .deploy/logs/<ts>/ directories (newest first) with their files.
func listLogs(clusterDir string) []logDir {
	root := filepath.Join(clusterDir, ".deploy", "logs")
	entries, _ := os.ReadDir(root)
	var out []logDir
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		d := logDir{TS: e.Name()}
		fs, _ := os.ReadDir(filepath.Join(root, e.Name()))
		for _, f := range fs {
			if f.Type().IsRegular() && !strings.HasPrefix(f.Name(), ".") {
				d.Files = append(d.Files, f.Name())
			}
		}
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].TS > out[j].TS })
	return out
}

func (s *Server) handleLogList(w http.ResponseWriter, r *http.Request) {
	c := s.cluster(w, r)
	if c == nil {
		return
	}
	s.render(w, "logs.html", s.page(w, r, "clusters", c.Name+" logs", map[string]any{
		"Cluster": c.Name, "Dirs": listLogs(c.Dir)}))
}

func (s *Server) handleLogFile(w http.ResponseWriter, r *http.Request) {
	c := s.cluster(w, r)
	if c == nil {
		return
	}
	ts, file := r.PathValue("ts"), r.PathValue("file")
	// Names must match the directory listing: no traversal, no symlinks.
	var path string
	for _, d := range listLogs(c.Dir) {
		if d.TS != ts {
			continue
		}
		for _, f := range d.Files {
			if f == file {
				path = filepath.Join(c.Dir, ".deploy", "logs", d.TS, f)
			}
		}
	}
	if path == "" {
		http.NotFound(w, r)
		return
	}
	f, err := os.Open(path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		http.NotFound(w, r)
		return
	}
	note := ""
	if st.Size() > maxLogView {
		_, _ = f.Seek(st.Size()-maxLogView, 0)
		note = fmt.Sprintf("[showing the last %d MiB of %s]\n", maxLogView>>20, file)
	}
	var buf bytes.Buffer
	_, _ = buf.ReadFrom(f)
	h := w.Header()
	h.Set("Content-Type", "text/plain; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(note + s.Jobs.Redact(buf.String())))
}

// handleRancherPassword reveals the sensitive rancher_bootstrap_password
// output on an explicit click; the response is not cached.
func (s *Server) handleRancherPassword(w http.ResponseWriter, r *http.Request) {
	c := s.cluster(w, r)
	if c == nil {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	v := struct{ Password, Err string }{}
	pw, err := outputs.Raw(r.Context(), c.Dir, "rancher_bootstrap_password", s.Jobs.Env(c.Name))
	if err != nil {
		v.Err = s.Jobs.Redact(err.Error())
	} else {
		v.Password = pw
	}
	s.renderPartial(w, "cluster.html", "rancher_password", v)
}
