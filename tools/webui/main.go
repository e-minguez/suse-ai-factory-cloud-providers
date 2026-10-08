// Command webui is the local web runner for the cluster tooling.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/creds"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/jobs"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/server"
)

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	server.Version = version()
	srv, err := server.New(cfg)
	if err != nil {
		log.Fatal(err)
	}
	if err := creds.EnsureHome(cfg.ClustersDir()); err != nil {
		log.Fatalf("home for child processes: %v", err)
	}
	// Wiring point: other areas set their dependencies on srv here; routes
	// read them at request time.
	wireJobs(srv, cfg)
	hs := &http.Server{Addr: cfg.Addr, Handler: srv.Handler(), ReadHeaderTimeout: 10 * time.Second}

	ln, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%s %s\n", server.ProductName, server.Version)
	fmt.Printf("Open: %s\n", openURL(cfg))

	errc := make(chan error, 1)
	go func() { errc <- hs.Serve(ln) }()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	select {
	case err := <-errc:
		log.Fatal(err)
	case s := <-sig:
		log.Printf("received %v, shutting down", s)
	}
	ctx, cancel := context.WithTimeout(context.Background(), cfg.StopTimeout)
	defer cancel()
	// Stop children first (jobs), then the listener.
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("shutdown hooks: %v", err)
	}
	if err := hs.Shutdown(ctx); err != nil {
		log.Printf("http shutdown: %v", err)
	}
}

func loadConfig() (server.Config, error) {
	cfg := server.Config{
		Addr:         env("WEBUI_ADDR", "127.0.0.1:8080"),
		Token:        os.Getenv("WEBUI_TOKEN"),
		AllowedHosts: splitList(env("WEBUI_ALLOWED_HOSTS", "127.0.0.1,localhost")),
		StopTimeout:  10 * time.Minute,
	}
	if v := os.Getenv("WEBUI_STOP_TIMEOUT"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			cfg.StopTimeout = d
		} else if n, err := strconv.Atoi(v); err == nil {
			cfg.StopTimeout = time.Duration(n) * time.Second
		} else {
			return cfg, fmt.Errorf("WEBUI_STOP_TIMEOUT: %q is not a duration or seconds", v)
		}
	}
	repo := os.Getenv("WEBUI_REPO")
	if repo == "" {
		repo = detectRepo()
	}
	if repo == "" {
		return cfg, errors.New("repository not found: set WEBUI_REPO")
	}
	cfg.Repo = repo
	cfg.CostBin = costBin(repo)
	if cfg.Token == "" {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			return cfg, err
		}
		cfg.Token = hex.EncodeToString(b)
	}
	return cfg, nil
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func isRepo(dir string) bool {
	for _, p := range []string{"examples", "scripts/lib"} {
		if st, err := os.Stat(filepath.Join(dir, p)); err != nil || !st.IsDir() {
			return false
		}
	}
	return true
}

// detectRepo walks up from the executable, then the working directory.
func detectRepo() string {
	var starts []string
	if exe, err := os.Executable(); err == nil {
		starts = append(starts, filepath.Dir(exe))
	}
	if wd, err := os.Getwd(); err == nil {
		starts = append(starts, wd)
	}
	for _, d := range starts {
		for ; ; d = filepath.Dir(d) {
			if isRepo(d) {
				return d
			}
			if d == filepath.Dir(d) {
				break
			}
		}
	}
	return ""
}

func costBin(repo string) string {
	if v := os.Getenv("WEBUI_COST_BIN"); v != "" {
		return v
	}
	if p, err := exec.LookPath("cost"); err == nil {
		return p
	}
	return filepath.Join(repo, "tools", "cost", "cost")
}

func openURL(cfg server.Config) string {
	host, port, err := net.SplitHostPort(cfg.Addr)
	if err != nil || host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	if err == nil {
		host = net.JoinHostPort(host, port)
	}
	return "http://" + host + "/?token=" + cfg.Token
}

// wireJobs builds the jobs manager: child env (HOME on the volume, stored
// credentials of the cluster's provider), output redacted with the known
// secrets.
func wireJobs(srv *server.Server, cfg server.Config) {
	clusters := cfg.ClustersDir()
	rd := &redactor{repo: cfg.Repo, clusters: clusters, ws: srv.WS}
	envFor := func(cluster string) []string {
		env := []string{"HOME=" + creds.HomeDir(clusters)}
		if c, err := srv.WS.Get(cluster); err == nil {
			env = append(env, creds.Env(clusters, c.Provider)...)
		}
		return env
	}
	srv.Jobs = jobs.NewManager(cfg.Repo, clusters, envFor, rd.Redact)
	srv.Shutdowners = append(srv.Shutdowners, srv.Jobs)
}
