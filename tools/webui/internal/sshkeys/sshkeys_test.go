package sshkeys

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestGenerateParse(t *testing.T) {
	pub, priv, err := Generate("me@host")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(priv), "OPENSSH PRIVATE KEY") {
		t.Fatal("not openssh pem")
	}
	if _, err := ssh.ParsePrivateKey(priv); err != nil {
		t.Fatal(err)
	}
	if pub.Type != "ssh-ed25519" || pub.Bits != 256 || pub.Comment != "me@host" || !strings.HasPrefix(pub.Fingerprint, "SHA256:") {
		t.Fatalf("%+v", pub)
	}
	keys, err := Parse("# c\n\n"+pub.Line+"\n", "paste")
	if err != nil || len(keys) != 1 || keys[0].Size != len(pub.Line) || keys[0].Source != "paste" {
		t.Fatalf("%v %+v", err, keys)
	}
}

func TestParseErrors(t *testing.T) {
	if _, err := Parse("-----BEGIN OPENSSH PRIVATE KEY-----\nx", ""); !errors.Is(err, ErrPrivateKey) {
		t.Fatal(err)
	}
	pub, _, _ := Generate("")
	_, err := Parse(pub.Line+"\nbogus line\n", "")
	if err == nil || !strings.Contains(err.Error(), "line 2") {
		t.Fatal(err)
	}
}

func TestDedupe(t *testing.T) {
	a, _, _ := Generate("a")
	b, _, _ := Generate("b")
	a2 := a
	a2.Line = strings.Fields(a.Line)[0] + " " + strings.Fields(a.Line)[1] + " other"
	got := Dedupe([]Key{a, b, a2})
	if len(got) != 2 || got[0].Comment != "a" {
		t.Fatalf("%+v", got)
	}
}

func TestFetchGitHub(t *testing.T) {
	pub, _, _ := Generate("k")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/alice.keys":
			_, _ = w.Write([]byte(pub.Line + "\n"))
		case "/empty.keys":
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	old := githubBase
	githubBase = srv.URL
	defer func() { githubBase = old }()

	ks, err := FetchGitHub(context.Background(), srv.Client(), "alice")
	if err != nil || len(ks) != 1 || ks[0].Source != "github.com/alice" {
		t.Fatalf("%v %+v", err, ks)
	}
	if _, err := FetchGitHub(context.Background(), nil, "empty"); !errors.Is(err, ErrNoKeys) {
		t.Fatal(err)
	}
	if _, err := FetchGitHub(context.Background(), nil, "nobody"); err == nil {
		t.Fatal("want 404 error")
	}
	for _, u := range []string{"", "a/b", "../x", "a b", strings.Repeat("a", 40)} {
		if _, err := FetchGitHub(context.Background(), nil, u); !errors.Is(err, ErrBadUser) {
			t.Errorf("%q: %v", u, err)
		}
	}
}

func TestLimits(t *testing.T) {
	if UserDataLimit("aws") != 16384 || UserDataLimit("evroc") != 786432 {
		t.Fatal("limits")
	}
}
