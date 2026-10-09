package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"regexp"
	"strings"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/creds"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/sshkeys"
)

// partialHost is any page template set; all contain the shared partials.
const partialHost = "clusters.html"

const maxFormBytes = 1 << 20

var (
	widgetNameRe = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,63}$`)
	providerRe   = regexp.MustCompile(`^[a-z][a-z0-9]{0,31}$`)
	elemIDRe     = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]{0,80}$`)

	// ipifyURL is overridden by tests only.
	ipifyURL = "https://api.ipify.org"
)

// routesProfiles registers the profile pages and the htmx widget endpoints.
func (s *Server) routesProfiles(mux *http.ServeMux) {
	mux.HandleFunc("GET /profiles", s.handleProfileList)
	mux.HandleFunc("POST /profiles/sshkey", s.handleProfileSSHKey)
	mux.HandleFunc("GET /profiles/{provider}", s.handleProfile)
	mux.HandleFunc("POST /profiles/{provider}", s.handleProfileSave)
	mux.HandleFunc("POST /sshkeys/recalc", s.handleSSHRecalc)
	mux.HandleFunc("POST /sshkeys/parse", s.handleSSHParse)
	mux.HandleFunc("POST /sshkeys/github", s.handleSSHGitHub)
	mux.HandleFunc("POST /sshkeys/generate", s.handleSSHGenerate)
	mux.HandleFunc("POST /sshkeys/download", s.handleSSHDownload)
	mux.HandleFunc("POST /helpers/myip", s.handleMyIP)
}

func (s *Server) handleProfileList(w http.ResponseWriter, r *http.Request) {
	s.profilesPage(w, r, http.StatusOK, s.credProviders(), "")
}

// credSummary counts the stored credential fields of a provider profile.
type credSummary struct {
	Provider   string
	Set, Total int
}

func (c credSummary) Ready() bool { return c.Total > 0 && c.Set == c.Total }

// credSummaries reads the profile status of the given providers. A read
// error counts as nothing stored.
func (s *Server) credSummaries(ps []string) []credSummary {
	out := make([]credSummary, 0, len(ps))
	for _, p := range ps {
		c := credSummary{Provider: p, Total: len(creds.Fields(p))}
		if st, err := creds.Status(s.Cfg.ClustersDir(), p); err == nil {
			for _, f := range creds.Fields(p) {
				if st[f.Name] {
					c.Set++
				}
			}
		}
		out = append(out, c)
	}
	return out
}

func (s *Server) profilesPage(w http.ResponseWriter, r *http.Request, code int, ps []string, errMsg string) {
	pg := s.page(w, r, "profiles", "Profiles", map[string]any{
		"Providers": s.credSummaries(ps), "HasSSHKey": creds.HasSSHKey(s.Cfg.ClustersDir()),
	})
	if errMsg != "" {
		pg.Err = errMsg
	}
	s.renderStatus(w, code, "profiles.html", pg)
}

// handleProfileSSHKey stores a pasted OpenSSH private key for the container.
func (s *Server) handleProfileSSHKey(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxFormBytes)
	if err := r.ParseForm(); err != nil {
		s.errorPage(w, r, http.StatusBadRequest, "Invalid form submission", "")
		return
	}
	err := creds.StorePastedSSHKey(s.Cfg.ClustersDir(), r.PostForm.Get("ssh_private_key"), r.PostForm.Get("replace") == "1")
	if err != nil {
		msg := err.Error()
		if errors.Is(err, creds.ErrKeyExists) {
			msg += "; tick \"Replace the existing key\" to overwrite it."
		} else if !errors.Is(err, creds.ErrKeyPassphrase) && !strings.Contains(msg, "private key") {
			msg = "Saving failed: " + msg
		}
		s.profilesPage(w, r, http.StatusBadRequest, s.credProviders(), msg)
		return
	}
	setFlash(w, "ok", "SSH private key stored.")
	http.Redirect(w, r, "/profiles", http.StatusSeeOther)
}

func (s *Server) credProviders() []string {
	var ps []string
	for _, p := range s.WS.Providers() {
		if creds.Fields(p) != nil {
			ps = append(ps, p)
		}
	}
	return ps
}

func (s *Server) profileProvider(w http.ResponseWriter, r *http.Request) (string, bool) {
	p := r.PathValue("provider")
	for _, k := range s.WS.Providers() {
		if k == p && creds.Fields(p) != nil {
			return p, true
		}
	}
	s.errorPage(w, r, http.StatusNotFound, "Unknown provider", "")
	return "", false
}

func (s *Server) profileView(w http.ResponseWriter, r *http.Request, code int, p, errMsg string) {
	st, err := creds.Status(s.Cfg.ClustersDir(), p)
	if err != nil {
		s.errorPage(w, r, http.StatusInternalServerError, "Cannot read credentials", err.Error())
		return
	}
	pg := s.page(w, r, "profiles", "Profile: "+providerName(p), map[string]any{
		"Provider": p, "Fields": creds.Fields(p), "Status": st,
	})
	if errMsg != "" {
		pg.Err = errMsg
	}
	s.renderStatus(w, code, "profile.html", pg)
}

func (s *Server) handleProfile(w http.ResponseWriter, r *http.Request) {
	if p, ok := s.profileProvider(w, r); ok {
		s.profileView(w, r, http.StatusOK, p, "")
	}
}

func (s *Server) handleProfileSave(w http.ResponseWriter, r *http.Request) {
	p, ok := s.profileProvider(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxFormBytes)
	if err := r.ParseForm(); err != nil {
		s.profileView(w, r, http.StatusBadRequest, p, "Invalid form submission.")
		return
	}
	vals := map[string]string{}
	for _, f := range creds.Fields(p) {
		vals[f.Name] = r.PostForm.Get(f.Name)
	}
	if err := creds.Save(s.Cfg.ClustersDir(), p, vals); err != nil {
		s.profileView(w, r, http.StatusBadRequest, p, "Saving failed: "+err.Error())
		return
	}
	setFlash(w, "ok", "Credentials for "+p+" saved.")
	http.Redirect(w, r, "/profiles/"+p, http.StatusSeeOther)
}

// widgetFromForm rebuilds the SSH key widget state from the submitted form.
func widgetFromForm(w http.ResponseWriter, r *http.Request) (SSHKeysWidget, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, maxFormBytes)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return SSHKeysWidget{}, false
	}
	name, provider := r.PostForm.Get("sshkeys_name"), r.PostForm.Get("sshkeys_provider")
	if !widgetNameRe.MatchString(name) || !providerRe.MatchString(provider) {
		http.Error(w, "bad widget", http.StatusBadRequest)
		return SSHKeysWidget{}, false
	}
	wd := SSHKeysWidget{Name: name, Provider: provider, Selected: map[string]bool{}}
	for _, v := range r.PostForm[name+"__listed"] {
		src, line, ok := strings.Cut(v, "|")
		if !ok {
			continue
		}
		if ks, err := sshkeys.Parse(line, src); err == nil {
			wd.Keys = append(wd.Keys, ks...)
		}
	}
	for _, line := range r.PostForm[name] {
		wd.Selected[strings.TrimSpace(line)] = true
		if ks, err := sshkeys.Parse(line, "saved"); err == nil {
			wd.Keys = append(wd.Keys, ks...)
		}
	}
	wd.Keys = sshkeys.Dedupe(wd.Keys)
	return wd, true
}

// add lists keys not yet present and selects them; returns the new ones.
func (wd *SSHKeysWidget) add(keys []sshkeys.Key) []sshkeys.Key {
	have := map[string]bool{}
	for _, k := range wd.Keys {
		have[sshkeys.Blob(k.Line)] = true
	}
	var added []sshkeys.Key
	for _, k := range keys {
		if !have[sshkeys.Blob(k.Line)] {
			have[sshkeys.Blob(k.Line)] = true
			wd.Keys = append(wd.Keys, k)
			added = append(added, k)
		}
		wd.Selected[k.Line] = true
	}
	return added
}

func (s *Server) renderSSH(w http.ResponseWriter, wd SSHKeysWidget) {
	s.renderPartial(w, partialHost, "sshkeys", wd.Finalize())
}

func (s *Server) handleSSHRecalc(w http.ResponseWriter, r *http.Request) {
	if wd, ok := widgetFromForm(w, r); ok {
		s.renderSSH(w, wd)
	}
}

func (s *Server) handleSSHParse(w http.ResponseWriter, r *http.Request) {
	wd, ok := widgetFromForm(w, r)
	if !ok {
		return
	}
	keys, err := sshkeys.Parse(r.PostForm.Get("sshkeys_paste"), "paste")
	switch {
	case err != nil:
		wd.Error = err.Error()
	case len(keys) == 0:
		wd.Error = "No keys found in the pasted text."
	default:
		n := len(wd.add(keys))
		wd.Notice = fmt.Sprintf("Added %d key(s).", n)
	}
	s.renderSSH(w, wd)
}

func (s *Server) handleSSHGitHub(w http.ResponseWriter, r *http.Request) {
	wd, ok := widgetFromForm(w, r)
	if !ok {
		return
	}
	user := strings.TrimSpace(r.PostForm.Get("sshkeys_user"))
	refresh := r.PostForm.Get("refresh") != ""
	if refresh {
		user = strings.TrimSpace(r.PostForm.Get("user"))
	}
	keys, err := sshkeys.FetchGitHub(r.Context(), nil, user)
	if err != nil {
		wd.Error = githubError(err, user)
		s.renderSSH(w, wd)
		return
	}
	if !refresh {
		wd.Notice = fmt.Sprintf("Added %d new key(s) from github.com/%s.", len(wd.add(keys)), user)
		s.renderSSH(w, wd)
		return
	}
	fetched := map[string]bool{}
	for _, k := range keys {
		fetched[sshkeys.Blob(k.Line)] = true
	}
	src := "github.com/" + user
	diff := &SSHKeysDiff{User: user}
	var kept []sshkeys.Key
	for _, k := range wd.Keys {
		if k.Source == src && !fetched[sshkeys.Blob(k.Line)] {
			diff.Removed = append(diff.Removed, k)
			delete(wd.Selected, k.Line)
			continue
		}
		kept = append(kept, k)
	}
	wd.Keys = kept
	diff.Added = wd.add(keys)
	wd.Diff = diff
	s.renderSSH(w, wd)
}

func githubError(err error, user string) string {
	switch {
	case errors.Is(err, sshkeys.ErrNoKeys):
		return "github.com/" + user + " has no public SSH keys."
	case errors.Is(err, sshkeys.ErrBadUser):
		return "Not a valid GitHub user name."
	}
	return err.Error()
}

func (s *Server) handleSSHGenerate(w http.ResponseWriter, r *http.Request) {
	wd, ok := widgetFromForm(w, r)
	if !ok {
		return
	}
	comment := strings.Join(strings.Fields(r.PostForm.Get("sshkeys_comment")), "-")
	if comment == "" {
		comment = "aif-generated"
	}
	pub, priv, err := sshkeys.Generate(comment)
	if err != nil {
		wd.Error = "Key generation failed."
		s.renderSSH(w, wd)
		return
	}
	wd.add([]sshkeys.Key{pub})
	wd.DownloadID = storePrivKey(priv)
	wd.Notice = "Key generated. Download the private key now: it is shown once and not stored."
	if r.PostForm.Get("sshkeys_keep") == "1" {
		wd.Notice = s.keepKey(priv, pub)
	}
	s.renderSSH(w, wd)
}

// keepKey stores a generated pair as the container key and returns the notice.
func (s *Server) keepKey(priv []byte, pub sshkeys.Key) string {
	const once = "Download the private key now: it is shown once."
	err := creds.StoreSSHKey(s.Cfg.ClustersDir(), priv, []byte(pub.Line+"\n"), false)
	switch {
	case err == nil:
		return "Key generated and stored on the volume for kubeconfig download and SSH. " + once
	case errors.Is(err, creds.ErrKeyExists):
		return "Key generated. A container key already exists, so this one was not stored (existing key kept). " + once
	}
	return "Key generated, but storing it on the volume failed. " + once
}

func (s *Server) handleSSHDownload(w http.ResponseWriter, r *http.Request) {
	pem, ok := takePrivKey(r.URL.Query().Get("id"))
	if !ok {
		s.errorPage(w, r, http.StatusNotFound, "Private key no longer available", "It is served once and expires after 10 minutes. Generate a new key.")
		return
	}
	h := w.Header()
	h.Set("Content-Type", "application/octet-stream")
	h.Set("Content-Disposition", `attachment; filename="id_ed25519"`)
	h.Set("Cache-Control", "no-store")
	_, _ = w.Write(pem)
}

func (s *Server) handleMyIP(w http.ResponseWriter, r *http.Request) {
	target := r.FormValue("target")
	if !elemIDRe.MatchString(target) {
		http.Error(w, "bad target", http.StatusBadRequest)
		return
	}
	ip, err := fetchIP(r.Context())
	data := map[string]any{"Target": target}
	if err != nil {
		data["Error"] = "Could not detect the public IP: " + err.Error()
	} else {
		data["CIDR"] = ip
	}
	s.renderPartial(w, partialHost, "myip_result", data)
}

func fetchIP(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ipifyURL, nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", errors.New("request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("service returned %s", resp.Status)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 64))
	if err != nil {
		return "", err
	}
	a, err := netip.ParseAddr(strings.TrimSpace(string(b)))
	if err != nil {
		return "", errors.New("unexpected response")
	}
	return netip.PrefixFrom(a, a.BitLen()).String(), nil
}
