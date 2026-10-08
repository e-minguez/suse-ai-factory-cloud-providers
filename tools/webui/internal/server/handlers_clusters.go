package server

import (
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/tfvars"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

// routesClusters registers the cluster list, creation and overview shell.
// Overview handlers for outputs/actions belong to the jobs area.
func (s *Server) routesClusters(mux *http.ServeMux) {
	mux.HandleFunc("GET /{$}", s.handleClusterList)
	mux.HandleFunc("GET /clusters/new", s.handleClusterNew)
	mux.HandleFunc("POST /clusters/new", s.handleClusterCreate)
	mux.HandleFunc("GET /clusters/{name}", s.handleClusterOverview)
}

func (s *Server) handleClusterList(w http.ResponseWriter, r *http.Request) {
	list, err := s.WS.List()
	if err != nil {
		s.errorPage(w, r, http.StatusInternalServerError, "Cannot list clusters", err.Error())
		return
	}
	s.render(w, "clusters.html", s.page(w, r, "clusters", "Clusters", map[string]any{"Clusters": list}))
}

func (s *Server) newForm(w http.ResponseWriter, r *http.Request, provider, name string) {
	s.render(w, "cluster_new.html", s.page(w, r, "new", "New cluster", map[string]any{
		"Providers": s.WS.Providers(), "Provider": provider, "Name": name,
	}))
}

func (s *Server) handleClusterNew(w http.ResponseWriter, r *http.Request) {
	s.newForm(w, r, "", "")
}

func (s *Server) handleClusterCreate(w http.ResponseWriter, r *http.Request) {
	provider, name := r.FormValue("provider"), r.FormValue("name")
	var c *workspace.Cluster
	err := clusterNameErr(provider, name)
	if err == nil {
		c, err = s.WS.Create(r.Context(), provider, name)
	}
	if err == nil {
		// The directory name doubles as the cluster_name prefix.
		path := tfvars.Path(s.Cfg.ClustersDir(), provider, name, tfvars.LayerCluster)
		if err = tfvars.Write(path, map[string]any{"cluster_name": name}, nil); err != nil {
			err = fmt.Errorf("writing cluster_name: %w", err)
		}
	}
	if err != nil {
		msg := err.Error()
		if !errors.Is(err, workspace.ErrInvalidName) && !errors.Is(err, errClusterName) && !errors.Is(err, workspace.ErrExists) && !errors.Is(err, workspace.ErrUnknownProv) {
			msg = "Creating the cluster failed: " + msg
		}
		pg := s.page(w, r, "new", "New cluster", map[string]any{
			"Providers": s.WS.Providers(), "Provider": provider, "Name": name,
		})
		pg.Err = msg
		s.renderStatus(w, http.StatusBadRequest, "cluster_new.html", pg)
		return
	}
	http.Redirect(w, r, "/clusters/"+c.Name+"/edit", http.StatusSeeOther)
}

func (s *Server) handleClusterOverview(w http.ResponseWriter, r *http.Request) {
	c, err := s.WS.Get(r.PathValue("name"))
	if err != nil {
		s.errorPage(w, r, http.StatusNotFound, "Cluster not found", "")
		return
	}
	s.render(w, "cluster.html", s.page(w, r, "clusters", c.Name, map[string]any{"Cluster": c}))
}

var errClusterName = errors.New("unusable as cluster_name")

// awsNameMax mirrors the cluster_name length check of the aws module.
const awsNameMax = 21

// clusterNameErr checks the directory name against the cluster_name
// constraints: DNS label (no trailing dash), at most 21 characters on aws.
func clusterNameErr(provider, name string) error {
	if !workspace.ValidName(name) {
		return nil // reported by workspace.Create
	}
	if strings.HasSuffix(name, "-") {
		return fmt.Errorf("%w: the name is also the cluster_name and must not end with a dash", errClusterName)
	}
	if provider == "aws" && len(name) > awsNameMax {
		return fmt.Errorf("%w: on aws the name is also the cluster_name and must be at most %d characters (got %d)", errClusterName, awsNameMax, len(name))
	}
	return nil
}
