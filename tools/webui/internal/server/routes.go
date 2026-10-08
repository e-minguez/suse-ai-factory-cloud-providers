package server

import (
	"io/fs"
	"net/http"
)

func (s *Server) mux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok"))
	})
	sub, _ := fs.Sub(webFS, "web/static")
	mux.Handle("GET /static/", s.staticHandler(sub))
	// Each area owns its routes<Area> in handlers_<area>.go.
	s.routesClusters(mux)
	s.routesForms(mux)
	s.routesProfiles(mux)
	s.routesJobs(mux)
	return mux
}
