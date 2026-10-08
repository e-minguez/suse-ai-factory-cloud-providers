package passhash

import (
	"strings"
	"testing"
)

func TestVector(t *testing.T) {
	// Reference vector of the SHA-crypt specification.
	h := "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"
	if !Verify("Hello world!", h) {
		t.Fatal("Verify failed")
	}
	if Verify("Hello world!x", h) {
		t.Fatal("wrong password accepted")
	}
}

func TestHashRoundTrip(t *testing.T) {
	for _, pw := range []string{"s3cret", "päss word", `q"uote$\back`} {
		h, err := Hash(pw)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasPrefix(h, "$6$") || len(strings.Split(h, "$")) != 4 {
			t.Fatalf("bad format %q", h)
		}
		if !Verify(pw, h) || Verify(pw+"x", h) {
			t.Fatalf("verify mismatch for %q", pw)
		}
		if h2, _ := Hash(pw); h == h2 {
			t.Fatal("salt not random")
		}
	}
}

func TestBad(t *testing.T) {
	if _, err := Hash("two\nlines"); err == nil {
		t.Fatal("multi-line password accepted")
	}
	for _, h := range []string{"", "$1$x$y", "$6$rounds=5000$x$y", "$6$"} {
		if Verify("a", h) {
			t.Errorf("accepted %q", h)
		}
	}
}
