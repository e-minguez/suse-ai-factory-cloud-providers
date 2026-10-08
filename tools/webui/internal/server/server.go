// Package server is the HTTP layer: routing, security middleware, templates.
package server

import (
	"context"
	"net/http"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/jobs"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

// Config is the runtime configuration (see main.go for the env vars).
type Config struct {
	Addr         string
	Repo         string
	Token        string
	CostBin      string
	AllowedHosts []string // host names without port
	StopTimeout  time.Duration
}

// ClustersDir is <repo>/clusters, the shared volume.
func (c Config) ClustersDir() string { return c.Repo + "/clusters" }

// Shutdowner is implemented by components that stop children on exit
// (the jobs manager).
type Shutdowner interface {
	Shutdown(ctx context.Context) error
}

// Server holds configuration and dependencies. Other areas add fields
// (typed as small interfaces) and register routes in routes<Area>.
type Server struct {
	Cfg Config
	WS  *workspace.Workspace

	// Jobs runs deploy/destroy/leftovers; set in main.go.
	Jobs *jobs.Manager

	// Shutdown hooks run, in order, by Shutdown.
	Shutdowners []Shutdowner

	tmpl    *templates
	handler http.Handler
}

// New builds a Server and its handler chain.
func New(cfg Config) (*Server, error) {
	t, err := loadTemplates()
	if err != nil {
		return nil, err
	}
	s := &Server{Cfg: cfg, WS: workspace.New(cfg.Repo), tmpl: t}
	s.handler = s.middleware(s.mux())
	return s, nil
}

// Handler returns the full handler including middleware. Routes read
// dependencies (s.Jobs, ...) at request time, so they may be set after New.
func (s *Server) Handler() http.Handler { return s.handler }

// Shutdown runs the registered hooks.
func (s *Server) Shutdown(ctx context.Context) error {
	var first error
	for _, h := range s.Shutdowners {
		if err := h.Shutdown(ctx); err != nil && first == nil {
			first = err
		}
	}
	return first
}
