// Package provider defines what a cloud provider contributes to the cost
// estimator and a registry to look providers up by name.
//
// Each provider lives in its own subpackage (aws, evroc, exoscale, vultr), imports this
// package and calls Register from init. internal/provider/all blank-imports
// them, so a binary only needs `import _ ".../internal/provider/all"`.
// Registration happens in the subpackages (not here) to avoid an import cycle.
package provider

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

// Config is a provider's resolved view of a deployment.
type Config struct {
	// Common has the provider's locals.tf defaults applied (region, instance
	// types, disk sizes, zones).
	Common tfconfig.Common
	// Details holds provider-only variables; its type is private to the
	// provider package, which type-asserts it in Expand. May be nil.
	Details any
}

// CatalogOpts says where Catalog may get its rates from.
type CatalogOpts struct {
	// File, when set, is a provider-specific catalog file used instead of
	// the network and any cache (the --catalog flag).
	File string
	// NoNetwork forbids network calls; only File or a warm cache may serve.
	NoNetwork bool
	// CacheDir is the directory for cached catalogs; "" disables caching.
	CacheDir string
}

// Provider is implemented once per cloud provider.
type Provider interface {
	// Name is the registry key and the --provider value.
	Name() string
	// Resolve applies the provider's locals.tf defaults to c and reads any
	// provider-only variables from v. Problems go into the returned
	// diagnostics (error severity fails the run with exit code 2).
	Resolve(c tfconfig.Common, v *tfconfig.Vars) (Config, []tfconfig.Diagnostic)
	// Expand lists the resources the module creates, and the costs it
	// leaves out. Role and Pool use docs/conventions.md#labels.
	Expand(cfg Config) ([]pricing.Resource, []pricing.Excluded)
	// Catalog returns rates for region. A failure (not authenticated, no
	// network, no usable cache) is an error, reported with exit code 3.
	Catalog(ctx context.Context, region string, o CatalogOpts) (pricing.Catalog, error)
}

var registry = map[string]Provider{}

// Register adds p under p.Name(); call it from the subpackage's init.
func Register(p Provider) { registry[p.Name()] = p }

// Names lists the registered provider names, sorted.
func Names() []string {
	names := make([]string, 0, len(registry))
	for n := range registry {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// Get returns the provider registered under name.
func Get(name string) (Provider, error) {
	if p, ok := registry[name]; ok {
		return p, nil
	}
	return nil, fmt.Errorf("unknown provider %q (known: %s)", name, strings.Join(Names(), ", "))
}

// DefaultCacheDir is the standard catalog cache directory under the user
// cache dir.
func DefaultCacheDir() (string, error) {
	dir, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "suse-ai-factory-cost"), nil
}
