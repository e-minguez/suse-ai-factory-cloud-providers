// Package jobs runs cluster.sh deploy/destroy (and the leftovers check) as
// child processes, parses their event protocol and fans events out to
// subscribers (WEBUI_SPEC.md, "Event protocol").
package jobs

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

// Action is what a job runs.
type Action string

const (
	ActionDeploy    Action = "deploy"
	ActionDestroy   Action = "destroy"
	ActionRebuild   Action = "rebuild" // deploy --rebuild
	ActionLeftovers Action = "leftovers"
)

// Job statuses.
const (
	StatusRunning = "running"
	StatusOK      = "ok"
	StatusFailed  = "failed"
	StatusAborted = "aborted"
)

const (
	ringMax         = 5000
	subBuffer       = 512
	maxLineLen      = 64 << 10 // plain output lines
	maxEventLineLen = 8 << 20  // protocol events (plan_summary lists every address)
)

var (
	ErrBusy      = errors.New("a job is already running for this cluster")
	ErrNotFound  = errors.New("job not found")
	ErrNoConfirm = errors.New("no confirmation is pending")
	ErrFinished  = errors.New("job already finished")
	ErrAction    = errors.New("unknown action")

	ErrShuttingDown = errors.New("the web UI is shutting down; no new jobs can start")
	ErrStaleConfirm = errors.New("this plan was already answered")
)

// Event is a protocol event (Type = its "type", Raw = the JSON line) or a
// plain output line (Type "line", Line set).
type Event struct {
	Seq  int // per job, increasing; used as SSE id
	Type string
	Raw  json.RawMessage
	Line string
}

// Decode unmarshals Raw into v.
func (e Event) Decode(v any) error { return json.Unmarshal(e.Raw, v) }

// PlanSummary is the plan_summary event.
type PlanSummary struct {
	Index     int      `json:"index"`
	Create    int      `json:"create"`
	Update    int      `json:"update"`
	Replace   []string `json:"replace"`
	Destroy   []string `json:"destroy"`
	NoChanges bool     `json:"no_changes"`
}

// Info is a consistent snapshot of a job.
type Info struct {
	ID, Cluster, Provider string
	Action                Action
	Started, Ended        time.Time
	Status                string
	ExitCode              int
	LogDir                string
	Confirm               bool // a confirm_request is pending
	ConfirmIndex          int
}

// Job is one child process run.
type Job struct {
	ID      string
	Cluster string
	Action  Action
	Started time.Time

	provider string
	mu       sync.Mutex
	events   []Event
	subs     map[chan Event]struct{}
	plans    map[int]PlanSummary
	status   string
	exitCode int
	ended    time.Time
	logDir   string
	confirm  bool
	confIdx  int
	cancels  int
	seq      int
	doneEv   *Event // held until the output streams drain
	pgid     int
	confW    *os.File
	finished chan struct{}
}

// Info returns a snapshot.
func (j *Job) Info() Info {
	j.mu.Lock()
	defer j.mu.Unlock()
	return Info{ID: j.ID, Cluster: j.Cluster, Provider: j.provider, Action: j.Action, Started: j.Started,
		Ended: j.ended, Status: j.status, ExitCode: j.exitCode, LogDir: j.logDir,
		Confirm: j.confirm, ConfirmIndex: j.confIdx}
}

// Plan returns the plan summary recorded for pass index.
func (j *Job) Plan(index int) (PlanSummary, bool) {
	j.mu.Lock()
	defer j.mu.Unlock()
	p, ok := j.plans[index]
	return p, ok
}

// Done is closed when the job has finished and its events are published.
func (j *Job) Done() <-chan struct{} { return j.finished }

// Manager owns all jobs of one process.
type Manager struct {
	repo, clusters string
	envFor         func(cluster string) []string
	redact         func(string) string

	mu      sync.Mutex
	closing bool
	jobs    map[string]*Job
	order   []*Job
	live    map[string]*Job // cluster -> running job
}

// NewManager returns a Manager. envFor and redact may be nil.
func NewManager(repoRoot, clustersDir string, envFor func(cluster string) []string, redact func(string) string) *Manager {
	if envFor == nil {
		envFor = func(string) []string { return nil }
	}
	if redact == nil {
		redact = func(s string) string { return s }
	}
	return &Manager{repo: repoRoot, clusters: clustersDir, envFor: envFor, redact: redact,
		jobs: map[string]*Job{}, live: map[string]*Job{}}
}

func newID() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// Start launches a job for cluster. ErrBusy if one is running (in this
// process or, by lock file, in another one).
func (m *Manager) Start(cluster string, a Action) (*Job, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closing {
		return nil, ErrShuttingDown
	}
	if j, ok := m.live[cluster]; ok && j.Info().Status == StatusRunning {
		return nil, ErrBusy
	}
	cdir := filepath.Join(m.clusters, cluster)
	deployDir := filepath.Join(cdir, ".deploy")
	if err := os.MkdirAll(deployDir, 0o700); err != nil {
		return nil, err
	}
	lock := filepath.Join(deployDir, "webui.lock")
	if workspace.LockLive(lock) {
		return nil, ErrBusy
	}
	provider, err := workspace.ReadProvider(cdir)
	if err != nil {
		return nil, err
	}

	var cmd *exec.Cmd
	extra := m.envFor(cluster)
	useFDs := true
	switch a {
	case ActionDeploy, ActionRebuild, ActionDestroy:
		verb := "deploy"
		if a == ActionDestroy {
			verb = "destroy"
		}
		args := []string{verb, cluster, "-q"}
		if a == ActionRebuild {
			args = append(args, "--rebuild")
		}
		cmd = exec.Command(filepath.Join(m.repo, "tools", "multicluster", "cluster.sh"), args...)
	case ActionLeftovers:
		if missing := LeftoversMissing(provider); len(missing) > 0 {
			return nil, &MissingToolError{Tools: missing}
		}
		spec := LeftoverSpec(m.repo, m.clusters, provider, cluster)
		cmd = exec.Command(filepath.Join(m.repo, "tools", "leftovers", provider+".sh"), spec.Args...)
		extra = append(append([]string(nil), spec.Env...), extra...)
		useFDs = false
	default:
		return nil, ErrAction
	}
	cmd.Dir = m.repo
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Env = workspace.ChildEnv(extra)

	outR, outW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	cmd.Stdout, cmd.Stderr = outW, outW
	var evR, evW, confR, confW *os.File
	closeAll := func() {
		for _, f := range []*os.File{outR, outW, evR, evW, confR, confW} {
			if f != nil {
				_ = f.Close()
			}
		}
	}
	if useFDs {
		if evR, evW, err = os.Pipe(); err != nil {
			closeAll()
			return nil, err
		}
		if confR, confW, err = os.Pipe(); err != nil {
			closeAll()
			return nil, err
		}
		cmd.ExtraFiles = []*os.File{evW, confR}
		cmd.Env = append(cmd.Env, "DEPLOY_EVENTS_FD=3", "DEPLOY_CONFIRM_FD=4")
	}
	if err := cmd.Start(); err != nil {
		closeAll()
		return nil, err
	}
	// Child holds its own copies.
	_ = outW.Close()
	if useFDs {
		_ = evW.Close()
		_ = confR.Close()
	}

	j := &Job{ID: newID(), Cluster: cluster, Action: a, Started: time.Now(), provider: provider,
		subs: map[chan Event]struct{}{}, plans: map[int]PlanSummary{}, status: StatusRunning,
		pgid: cmd.Process.Pid, confW: confW, finished: make(chan struct{})}
	m.jobs[j.ID] = j
	m.order = append(m.order, j)
	m.live[cluster] = j
	writeFile(lock, fmt.Sprintf("%d %d %s %s\n", cmd.Process.Pid, j.Started.Unix(), a, workspace.Instance))

	go m.supervise(j, cmd, outR, evR, lock, cdir)
	return j, nil
}

func (m *Manager) supervise(j *Job, cmd *exec.Cmd, outR, evR *os.File, lock, cdir string) {
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		readLines(outR, maxLineLen, func(s string) { m.publishLine(j, s) })
	}()
	if evR != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			readLines(evR, maxEventLineLen, func(s string) { m.publishProto(j, s) })
		}()
	}
	werr := cmd.Wait()
	// Grandchildren may keep the pipes open; do not wait forever.
	drained := make(chan struct{})
	go func() { wg.Wait(); close(drained) }()
	select {
	case <-drained:
	case <-time.After(5 * time.Second):
		_ = outR.Close()
		if evR != nil {
			_ = evR.Close()
		}
		<-drained
	}
	_ = outR.Close()
	if evR != nil {
		_ = evR.Close()
	}
	exit := 0
	if werr != nil {
		exit = -1
		var ee *exec.ExitError
		if errors.As(werr, &ee) {
			exit = ee.ExitCode()
			if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
				exit = 128 + int(ws.Signal())
			}
		}
	}
	m.finish(j, exit, lock, cdir)
}

func (m *Manager) finish(j *Job, exit int, lock, cdir string) {
	j.mu.Lock()
	status, logDir := "", ""
	var done Event
	if j.doneEv != nil {
		done = *j.doneEv
		var d struct {
			Status string `json:"status"`
			Log    string `json:"log_dir"`
		}
		if done.Decode(&d) == nil {
			status, logDir = d.Status, d.Log
		}
	}
	switch {
	case status == StatusOK || status == StatusFailed || status == StatusAborted:
	case j.cancels > 0:
		status = StatusAborted
	case exit == 0:
		status = StatusOK
	default:
		status = StatusFailed
	}
	if done.Type == "" {
		raw, _ := json.Marshal(map[string]any{"type": "done", "status": status, "exit_code": exit,
			"ts": time.Now().UTC().Format(time.RFC3339)})
		done = Event{Type: "done", Raw: raw}
	}
	j.status, j.exitCode, j.logDir, j.confirm = status, exit, logDir, false
	j.ended = time.Now()
	j.publishLocked(done)
	for ch := range j.subs {
		close(ch)
	}
	j.subs = map[chan Event]struct{}{}
	if j.confW != nil {
		_ = j.confW.Close()
		j.confW = nil
	}
	j.mu.Unlock()

	_ = os.Remove(lock)
	if j.Action != ActionLeftovers {
		writeFile(filepath.Join(cdir, ".deploy", "webui-last-status"), status+"\n")
	}
	m.mu.Lock()
	if m.live[j.Cluster] == j {
		delete(m.live, j.Cluster)
	}
	m.mu.Unlock()
	close(j.finished)
}

func (m *Manager) publishLine(j *Job, s string) {
	s = m.redact(s)
	j.mu.Lock()
	j.publishLocked(Event{Type: "line", Line: s})
	j.mu.Unlock()
}

func (m *Manager) publishProto(j *Job, s string) {
	typ, clean, ok := m.redactEvent(s)
	if !ok {
		m.publishLine(j, s)
		return
	}
	h := struct{ Type string }{typ}
	ev := Event{Type: h.Type, Raw: json.RawMessage(clean)}
	j.mu.Lock()
	defer j.mu.Unlock()
	switch h.Type {
	case "done":
		j.doneEv = &ev // published by finish, after the streams drain
		return
	case "plan_summary":
		var p PlanSummary
		if ev.Decode(&p) == nil {
			j.plans[p.Index] = p
		}
	case "confirm_request":
		var c struct {
			Index int `json:"index"`
		}
		_ = ev.Decode(&c)
		j.confirm, j.confIdx = true, c.Index
	case "confirm_response":
		j.confirm = false
	}
	j.publishLocked(ev)
}

// redactEvent redacts the decoded string fields of a protocol event, so
// secrets are found whatever their JSON escaping. ok is false when s is not
// a JSON object with a string "type".
func (m *Manager) redactEvent(s string) (typ, out string, ok bool) {
	dec := json.NewDecoder(strings.NewReader(s))
	dec.UseNumber()
	var v map[string]any
	if dec.Decode(&v) != nil {
		return "", "", false
	}
	typ, _ = v["type"].(string)
	if typ == "" {
		return "", "", false
	}
	var buf strings.Builder
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if enc.Encode(m.redactValue(v)) != nil {
		return "", "", false
	}
	return typ, strings.TrimRight(buf.String(), "\n"), true
}

func (m *Manager) redactValue(v any) any {
	switch x := v.(type) {
	case string:
		return m.redact(x)
	case []any:
		for i := range x {
			x[i] = m.redactValue(x[i])
		}
	case map[string]any:
		for k := range x {
			x[k] = m.redactValue(x[k])
		}
	}
	return v
}

func (j *Job) appendLocked(e Event) {
	j.seq++
	e.Seq = j.seq
	j.events = append(j.events, e)
	if len(j.events) > ringMax {
		// Drop the oldest plain line; structural events stay.
		for i, x := range j.events {
			if x.Type == "line" {
				j.events = append(j.events[:i], j.events[i+1:]...)
				return
			}
		}
		j.events = j.events[1:]
	}
}

func (j *Job) publishLocked(e Event) {
	j.appendLocked(e)
	e.Seq = j.seq
	for ch := range j.subs {
		select {
		case ch <- e:
		default:
			select { // slow subscriber: drop its oldest
			case <-ch:
			default:
			}
			select {
			case ch <- e:
			default:
			}
		}
	}
}

// Env is the environment of children of cluster: os.Environ() without
// WEBUI_*, plus the cluster provider's credentials and HOME.
func (m *Manager) Env(cluster string) []string { return workspace.ChildEnv(m.envFor(cluster)) }

// Redact applies the manager's redaction to s (for log views).
func (m *Manager) Redact(s string) string { return m.redact(s) }

// Get returns a job by id.
func (m *Manager) Get(id string) (*Job, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	return j, ok
}

// Current returns the running job of cluster.
func (m *Manager) Current(cluster string) (*Job, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.live[cluster]
	return j, ok
}

// List returns the jobs of cluster (all when empty), newest first.
func (m *Manager) List(cluster string) []*Job {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []*Job
	for i := len(m.order) - 1; i >= 0; i-- {
		if cluster == "" || m.order[i].Cluster == cluster {
			out = append(out, m.order[i])
		}
	}
	return out
}

// Subscribe returns the events so far and a channel with the following
// ones; the channel closes after the done event. cancel is idempotent.
func (m *Manager) Subscribe(id string) (replay []Event, ch <-chan Event, cancel func()) {
	j, ok := m.Get(id)
	if !ok {
		c := make(chan Event)
		close(c)
		return nil, c, func() {}
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	replay = append([]Event(nil), j.events...)
	c := make(chan Event, subBuffer)
	if j.status != StatusRunning {
		close(c)
		return replay, c, func() {}
	}
	j.subs[c] = struct{}{}
	return replay, c, func() {
		j.mu.Lock()
		defer j.mu.Unlock()
		if _, ok := j.subs[c]; ok {
			delete(j.subs, c)
			close(c)
		}
	}
}

// Confirm answers the pending confirm_request of pass index. ErrStaleConfirm
// when that request was already answered (or another one is pending).
func (m *Manager) Confirm(id string, index int, yes bool) error {
	j, ok := m.Get(id)
	if !ok {
		return ErrNotFound
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.status != StatusRunning || !j.confirm || j.confW == nil {
		return ErrNoConfirm
	}
	if index != j.confIdx {
		return ErrStaleConfirm
	}
	ans := "no\n"
	if yes {
		ans = "yes\n"
	}
	if _, err := j.confW.WriteString(ans); err != nil {
		return err
	}
	j.confirm = false
	return nil
}

// Cancel sends SIGINT to the process group; a second call sends SIGTERM.
func (m *Manager) Cancel(id string) error {
	j, ok := m.Get(id)
	if !ok {
		return ErrNotFound
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.status != StatusRunning {
		return ErrFinished
	}
	j.cancels++
	sig := syscall.SIGINT
	if j.cancels > 1 {
		sig = syscall.SIGTERM
	}
	return signalGroup(j.pgid, sig)
}

// Shutdown sends SIGINT to every running job, waits until ctx ends, then
// kills what is left.
func (m *Manager) Shutdown(ctx context.Context) error {
	m.mu.Lock()
	m.closing = true
	var running []*Job
	for _, j := range m.live {
		running = append(running, j)
	}
	m.mu.Unlock()
	for _, j := range running {
		j.mu.Lock()
		j.cancels++
		_ = signalGroup(j.pgid, syscall.SIGINT)
		j.mu.Unlock()
	}
	for _, j := range running {
		select {
		case <-j.finished:
		case <-ctx.Done():
			for _, k := range running {
				_ = signalGroup(k.pgid, syscall.SIGKILL)
			}
			for _, k := range running {
				select {
				case <-k.finished:
				case <-time.After(5 * time.Second):
				}
			}
			return fmt.Errorf("jobs killed after stop timeout: %w", ctx.Err())
		}
	}
	return nil
}

func signalGroup(pgid int, sig syscall.Signal) error {
	if err := syscall.Kill(-pgid, sig); err != nil && !errors.Is(err, syscall.ESRCH) {
		return err
	}
	return nil
}

// readLines calls fn for each line (CR-progress reduced to its last
// segment, long lines truncated).
func readLines(r io.Reader, maxLen int, fn func(string)) {
	br := bufio.NewReaderSize(r, 64<<10)
	var buf []byte
	for {
		part, prefix, err := br.ReadLine()
		if len(buf) < maxLen {
			buf = append(buf, part...)
		}
		if !prefix && (err == nil || len(buf) > 0) {
			s := string(buf)
			if i := strings.LastIndexByte(s, '\r'); i >= 0 && i < len(s)-1 {
				s = s[i+1:]
			}
			fn(strings.TrimRight(s, "\r"))
			buf = buf[:0]
		}
		if err != nil {
			return
		}
	}
}

func writeFile(path, content string) {
	tmp := path + ".tmp"
	if os.WriteFile(tmp, []byte(content), 0o600) == nil {
		_ = os.Rename(tmp, path)
	}
}
