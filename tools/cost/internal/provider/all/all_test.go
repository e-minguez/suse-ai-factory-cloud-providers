package all

import (
	"slices"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
)

func TestRegistry(t *testing.T) {
	if got := provider.Names(); !slices.Equal(got, []string{"aws", "evroc", "vultr"}) {
		t.Errorf("Names() = %v", got)
	}
	for _, n := range provider.Names() {
		p, err := provider.Get(n)
		if err != nil || p.Name() != n {
			t.Errorf("Get(%q) = %v, %v", n, p, err)
		}
	}
	if _, err := provider.Get("nope"); err == nil {
		t.Error("an unknown provider must fail")
	}
}
