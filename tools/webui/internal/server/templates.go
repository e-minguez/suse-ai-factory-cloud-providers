package server

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"fmt"
	"html/template"
	"io/fs"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"
)

//go:embed all:web
var webFS embed.FS

const (
	ProductName = "SUSE AI Factory on Cloud Providers"
	Disclaimer  = "Unofficial community project. Not affiliated with, endorsed or supported by SUSE."
	flashCookie = "webui_flash"
)

// Version is the web UI release (tools/webui/VERSION), set by main.
var Version = "dev"

// Page is the data every template receives. Handlers put their own data
// in Data (templates read it as .Data.X).
type Page struct {
	Title   string
	Nav     string // active nav entry: "clusters", "profiles", ...
	Flash   string
	Err     string
	Product string
	Footer  string
	Version string
	Data    any
}

type templates struct {
	pages  map[string]*template.Template
	assets map[string]string // static file -> content hash
}

// loadTemplates parses every web/templates/<page>.html together with
// layout.html and all partials (_*.html). A page defines "content" (and
// optionally "title"); partials are executed by name via renderPartial.
func loadTemplates() (*templates, error) {
	t := &templates{pages: map[string]*template.Template{}, assets: map[string]string{}}
	st, _ := fs.Sub(webFS, "web/static")
	_ = fs.WalkDir(st, ".", func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			b, _ := fs.ReadFile(st, p)
			h := sha256.Sum256(b)
			t.assets[p] = hex.EncodeToString(h[:4])
		}
		return nil
	})
	funcs := template.FuncMap{
		"asset": func(n string) string {
			if v, ok := t.assets[n]; ok {
				return "/static/" + n + "?v=" + v
			}
			return "/static/" + n
		},
		"since":        func(ts time.Time) string { return time.Since(ts).Truncate(time.Second).String() },
		"query":        url.QueryEscape,
		"statusLabel":  statusLabel,
		"providerName": providerName,
		"providerLogo": func(p string) bool { return providerLogos[p] },
	}
	entries, err := fs.ReadDir(webFS, "web/templates")
	if err != nil {
		return nil, err
	}
	var shared []string
	for _, e := range entries {
		if n := e.Name(); n == "layout.html" || strings.HasPrefix(n, "_") {
			shared = append(shared, path.Join("web/templates", n))
		}
	}
	for _, e := range entries {
		n := e.Name()
		if n == "layout.html" || strings.HasPrefix(n, "_") || !strings.HasSuffix(n, ".html") {
			continue
		}
		files := append(append([]string{}, shared...), path.Join("web/templates", n))
		tp, err := template.New(n).Funcs(funcs).ParseFS(webFS, files...)
		if err != nil {
			return nil, fmt.Errorf("template %s: %w", n, err)
		}
		t.pages[n] = tp
	}
	return t, nil
}

// statusLabels maps cluster, job and pass status values (also used as CSS
// classes) to the text shown in status pills.
var statusLabels = map[string]string{
	"no-state":   "not deployed",
	"ok":         "finished",
	"no_changes": "no changes",
}

func statusLabel(s string) string {
	if l, ok := statusLabels[s]; ok {
		return l
	}
	return strings.NewReplacer("_", " ", "-", " ").Replace(s)
}

// providerNames is the brand spelling of each provider; templates keep the
// lowercase key in URLs and form values.
var providerNames = map[string]string{
	"aws": "AWS", "evroc": "evroc", "exoscale": "Exoscale", "vultr": "Vultr",
}

// providerLogos lists the providers with a symbol in static/providers.svg.
var providerLogos = map[string]bool{"aws": true, "evroc": true, "exoscale": true, "vultr": true}

func providerName(p string) string {
	if n, ok := providerNames[p]; ok {
		return n
	}
	return p
}

// render writes the named page (file name, e.g. "clusters.html") inside
// the base layout. data may be a Page or any value (wrapped as Page.Data).
func (s *Server) render(w http.ResponseWriter, name string, data any) {
	s.renderStatus(w, http.StatusOK, name, data)
}

func (s *Server) renderStatus(w http.ResponseWriter, code int, name string, data any) {
	p, ok := data.(Page)
	if !ok {
		p = Page{Data: data}
	}
	p.Product, p.Footer, p.Version = ProductName, Disclaimer, Version
	if p.Title == "" {
		p.Title = ProductName
	}
	tp := s.tmpl.pages[name]
	if tp == nil {
		http.Error(w, "template not found: "+name, http.StatusInternalServerError)
		return
	}
	var buf bytes.Buffer
	if err := tp.ExecuteTemplate(&buf, "layout", p); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(code)
	_, _ = buf.WriteTo(w)
}

// renderPartial executes a named template (e.g. "_cost.html" define) of
// page set `name` without the layout, for htmx fragments.
func (s *Server) renderPartial(w http.ResponseWriter, name, tmpl string, data any) {
	tp := s.tmpl.pages[name]
	if tp == nil {
		http.Error(w, "template not found: "+name, http.StatusInternalServerError)
		return
	}
	var buf bytes.Buffer
	if err := tp.ExecuteTemplate(&buf, tmpl, data); err != nil {
		http.Error(w, "render error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = buf.WriteTo(w)
}

// page builds a Page for request r and consumes the flash cookie.
func (s *Server) page(w http.ResponseWriter, r *http.Request, nav, title string, data any) Page {
	p := Page{Title: title, Nav: nav, Data: data}
	p.Flash, p.Err = popFlash(w, r)
	return p
}

// setFlash stores a one-shot message for the next page. kind: "ok" or "err".
func setFlash(w http.ResponseWriter, kind, msg string) {
	http.SetCookie(w, &http.Cookie{
		Name: flashCookie, Value: url.QueryEscape(kind + ":" + msg), Path: "/",
		HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: 60,
	})
}

func popFlash(w http.ResponseWriter, r *http.Request) (flash, errMsg string) {
	c, err := r.Cookie(flashCookie)
	if err != nil {
		return "", ""
	}
	http.SetCookie(w, &http.Cookie{Name: flashCookie, Path: "/", MaxAge: -1})
	v, err := url.QueryUnescape(c.Value)
	if err != nil {
		return "", ""
	}
	kind, msg, _ := strings.Cut(v, ":")
	if kind == "err" {
		return "", msg
	}
	return msg, ""
}

// errorPage renders the generic error page with the given status.
func (s *Server) errorPage(w http.ResponseWriter, r *http.Request, code int, title, detail string) {
	s.renderStatus(w, code, "error.html", Page{
		Title: title,
		Data:  map[string]any{"Code": code, "Heading": title, "Detail": detail},
	})
}

// forbidden renders the 403 page shown without a valid session.
func (s *Server) forbidden(w http.ResponseWriter, r *http.Request) {
	s.renderStatus(w, http.StatusForbidden, "forbidden.html", Page{Title: "Forbidden"})
}

// staticHandler serves embedded assets with a long cache lifetime
// (templates add ?v=<hash> through the asset func).
func (s *Server) staticHandler(sub fs.FS) http.Handler {
	fsrv := http.StripPrefix("/static/", http.FileServerFS(sub))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		fsrv.ServeHTTP(w, r)
	})
}
