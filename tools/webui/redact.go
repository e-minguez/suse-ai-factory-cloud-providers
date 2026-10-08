package main

import (
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/creds"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/schema"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/server"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

const secretsTTL = 5 * time.Second

// redactor masks sensitive values (sensitive variables of every cluster,
// the repo-root common-all layer, provider credentials) in job output and
// log views. The secret list is re-collected at most every secretsTTL, so
// values saved in the UI are picked up while a job runs.
type redactor struct {
	repo, clusters string
	ws             *workspace.Workspace

	mu      sync.Mutex
	at      time.Time
	secrets []string
}

func (r *redactor) Redact(s string) string {
	r.mu.Lock()
	if time.Since(r.at) > secretsTTL {
		r.secrets, r.at = r.collect(), time.Now()
	}
	secrets := r.secrets
	r.mu.Unlock()
	return server.Redact(s, secrets)
}

// minSecretLen is the shortest value masked; shorter ones would mangle
// ordinary output.
const minSecretLen = 6

func (r *redactor) collect() []string {
	var out []string
	sensitive := map[string][]string{} // provider -> sensitive variable names
	providers := schema.Providers(r.repo)
	for _, p := range providers {
		fields, err := schema.Load(r.repo, p)
		if err != nil {
			continue
		}
		for _, f := range fields {
			if f.Sensitive {
				sensitive[p] = append(sensitive[p], f.Name)
			}
		}
		if vals, err := creds.SecretValues(r.clusters, p); err == nil {
			out = append(out, vals...)
		}
	}
	list, _ := r.ws.List()
	for _, c := range list {
		// Includes <repo>/common-all.tfvars, which deploy.sh reads too.
		vals, _ := workspace.Vars(r.repo, r.clusters, c.Provider, c.Name)
		for _, n := range sensitive[c.Provider] {
			out = collectStrings(out, vals[n])
		}
	}
	return withEscapes(out)
}

func collectStrings(out []string, v any) []string {
	switch x := v.(type) {
	case string:
		out = append(out, x)
	case []any:
		for _, e := range x {
			out = collectStrings(out, e)
		}
	case map[string]any:
		for _, e := range x {
			out = collectStrings(out, e)
		}
	}
	return out
}

// withEscapes drops too-short values and adds the JSON-escaped forms of
// each, as they appear in raw terraform -json logs.
func withEscapes(in []string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(s string) {
		if len(s) >= minSecretLen && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	for _, s := range in {
		if len(s) < minSecretLen {
			continue
		}
		add(s)
		for _, html := range []bool{false, true} {
			var b strings.Builder
			enc := json.NewEncoder(&b)
			enc.SetEscapeHTML(html)
			if enc.Encode(s) == nil {
				q := strings.TrimRight(b.String(), "\n")
				add(q[1 : len(q)-1])
			}
		}
	}
	return out
}
