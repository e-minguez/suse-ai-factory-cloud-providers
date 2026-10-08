package server

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
)

const (
	sessionCookie = "webui_session"
	csp           = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
)

// sessionValue is the cookie value derived from the token, so the raw
// token never sits in the cookie jar.
func (s *Server) sessionValue() string {
	h := sha256.Sum256([]byte("webui-session:" + s.Cfg.Token))
	return hex.EncodeToString(h[:])
}

func eq(a, b string) bool { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }

func hostOnly(hostport string) string {
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		return strings.ToLower(strings.Trim(h, "[]"))
	}
	return strings.ToLower(strings.Trim(hostport, "[]"))
}

func (s *Server) hostAllowed(hostport string) bool {
	h := hostOnly(hostport)
	for _, a := range s.Cfg.AllowedHosts {
		if strings.EqualFold(strings.Trim(a, "[]"), h) {
			return true
		}
	}
	return false
}

// originOK checks state-changing requests. Sec-Fetch-Site is set by the browser
// and cannot be forged by a page; without it, Origin (or Referer) must match.
func (s *Server) originOK(r *http.Request) bool {
	switch r.Header.Get("Sec-Fetch-Site") {
	case "same-origin":
		return true
	case "", "none":
	default:
		return false
	}
	src := r.Header.Get("Origin")
	if src == "" {
		src = r.Header.Get("Referer")
	}
	if src == "" || src == "null" {
		return false
	}
	u, err := url.Parse(src)
	if err != nil || u.Host == "" {
		return false
	}
	return s.hostAllowed(u.Host) && strings.EqualFold(u.Host, r.Host)
}

// middleware: headers, host allow-list, origin check, token/cookie auth.
// /healthz skips host and auth; /static/ skips auth only.
func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", csp)
		h.Set("X-Content-Type-Options", "nosniff")
		// same-origin: no-referrer would make browsers send "Origin: null" on form posts.
		h.Set("Referrer-Policy", "same-origin")
		path := r.URL.Path
		if path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}
		if !s.hostAllowed(r.Host) {
			s.errorPage(w, r, http.StatusForbidden, "Host not allowed", "Open the UI via 127.0.0.1 or localhost, or add the host to WEBUI_ALLOWED_HOSTS.")
			return
		}
		static := strings.HasPrefix(path, "/static/")
		if !static {
			h.Set("Cache-Control", "no-store")
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead && !s.originOK(r) {
			s.errorPage(w, r, http.StatusForbidden, "Cross-origin request rejected", "")
			return
		}
		if static {
			next.ServeHTTP(w, r)
			return
		}
		if t := r.URL.Query().Get("token"); t != "" {
			if !eq(t, s.Cfg.Token) {
				s.forbidden(w, r)
				return
			}
			http.SetCookie(w, &http.Cookie{
				Name: sessionCookie, Value: s.sessionValue(), Path: "/",
				HttpOnly: true, SameSite: http.SameSiteStrictMode,
			})
			q := r.URL.Query()
			q.Del("token")
			u := url.URL{Path: path, RawQuery: q.Encode()}
			http.Redirect(w, r, u.String(), http.StatusSeeOther)
			return
		}
		c, err := r.Cookie(sessionCookie)
		if err != nil || !eq(c.Value, s.sessionValue()) {
			s.forbidden(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// Redact replaces every non-empty secret in s with "***".
func Redact(s string, secrets []string) string {
	ss := make([]string, 0, len(secrets))
	for _, x := range secrets {
		if x != "" {
			ss = append(ss, x)
		}
	}
	sort.Slice(ss, func(i, j int) bool { return len(ss[i]) > len(ss[j]) })
	for _, x := range ss {
		s = strings.ReplaceAll(s, x, "***")
	}
	return s
}
