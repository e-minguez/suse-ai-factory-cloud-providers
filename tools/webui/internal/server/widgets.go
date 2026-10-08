package server

import (
	"crypto/rand"
	"encoding/hex"
	"strings"
	"sync"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/sshkeys"
)

// SSHKeysWidget is the data for the "sshkeys" template (_sshkeys.html).
// Selected keys are submitted as multiple values named Name.
type SSHKeysWidget struct {
	Name, Provider string
	Keys           []sshkeys.Key   // every listed key, selected or not
	Selected       map[string]bool // by Key.Line; nil means all selected
	Limit, Total   int             // user_data budget and bytes of selected keys
	Error, Notice  string
	Diff           *SSHKeysDiff // set after a GitHub refresh
	DownloadID     string       // set after Generate: one-time private key
}

// SSHKeysDiff is the result of refreshing the keys of one GitHub user.
type SSHKeysDiff struct {
	User           string
	Added, Removed []sshkeys.Key
}

// NewSSHKeysWidget builds a widget from stored key lines (all selected).
// Unparsable lines are skipped. Callers may set Key.Source before Finalize.
func NewSSHKeysWidget(name, provider string, lines []string) SSHKeysWidget {
	w := SSHKeysWidget{Name: name, Provider: provider}
	for _, l := range lines {
		if ks, err := sshkeys.Parse(l, "saved"); err == nil {
			w.Keys = append(w.Keys, ks...)
		}
	}
	w.Keys = sshkeys.Dedupe(w.Keys)
	return w.Finalize()
}

// Finalize computes Limit and Total.
func (w SSHKeysWidget) Finalize() SSHKeysWidget {
	w.Limit = sshkeys.UserDataLimit(w.Provider)
	w.Total = 0
	for _, k := range w.Keys {
		if w.IsSelected(k) {
			w.Total += k.Size + 1
		}
	}
	return w
}

// IsSelected reports whether k is checked.
func (w SSHKeysWidget) IsSelected(k sshkeys.Key) bool {
	return w.Selected == nil || w.Selected[k.Line]
}

// Listed is the hidden-input value carrying a key and its source.
func (SSHKeysWidget) Listed(k sshkeys.Key) string { return k.Source + "|" + k.Line }

// Near reports whether keys use more than half of the budget.
func (w SSHKeysWidget) Near() bool { return w.Limit > 0 && w.Total*2 > w.Limit }

// Over reports whether keys exceed the budget.
func (w SSHKeysWidget) Over() bool { return w.Limit > 0 && w.Total > w.Limit }

// Percent is the budget share used by selected keys.
func (w SSHKeysWidget) Percent() int {
	if w.Limit <= 0 {
		return 0
	}
	return w.Total * 100 / w.Limit
}

// GitHubUsers lists the distinct GitHub users among the listed keys.
func (w SSHKeysWidget) GitHubUsers() []string {
	var out []string
	seen := map[string]bool{}
	for _, k := range w.Keys {
		if u, ok := strings.CutPrefix(k.Source, "github.com/"); ok && !seen[u] {
			seen[u] = true
			out = append(out, u)
		}
	}
	return out
}

// CIDRWidget is the data for the "cidr_list" template (_cidr.html).
type CIDRWidget struct {
	Name   string
	Values []string
}

// Text is the textarea content, one CIDR per line.
func (c CIDRWidget) Text() string { return strings.Join(c.Values, "\n") }

// privKeys holds generated private keys until their single download.
var privKeys = struct {
	sync.Mutex
	m map[string]privKey
}{m: map[string]privKey{}}

type privKey struct {
	pem     []byte
	expires time.Time
}

const privKeyTTL = 10 * time.Minute

func storePrivKey(pem []byte) string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	id := hex.EncodeToString(b)
	privKeys.Lock()
	defer privKeys.Unlock()
	now := time.Now()
	for k, v := range privKeys.m {
		if now.After(v.expires) {
			delete(privKeys.m, k)
		}
	}
	privKeys.m[id] = privKey{pem: pem, expires: now.Add(privKeyTTL)}
	return id
}

// takePrivKey returns and deletes the key; false when unknown or expired.
func takePrivKey(id string) ([]byte, bool) {
	privKeys.Lock()
	defer privKeys.Unlock()
	v, ok := privKeys.m[id]
	delete(privKeys.m, id)
	if !ok || time.Now().After(v.expires) {
		return nil, false
	}
	return v.pem, true
}
