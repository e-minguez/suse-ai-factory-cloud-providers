package aws

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

// cacheFile is both the per-region cache and the --catalog file format:
// decoded rates in micros of USD, so reading it never parses Price List JSON.
type cacheFile struct {
	Region    string                `json:"region"`
	FetchedAt time.Time             `json:"fetched_at"`
	Plans     map[string]cachedPlan `json:"plans"`
}

type cachedPlan struct {
	HourlyMicros    int64   `json:"hourly_micros,omitempty"`
	GBMonthlyMicros int64   `json:"gb_monthly_micros,omitempty"`
	MinHours        float64 `json:"min_hours,omitempty"`
}

func newCacheFile(region string, at time.Time, plans map[string]pricing.Plan) cacheFile {
	cf := cacheFile{Region: region, FetchedAt: at, Plans: map[string]cachedPlan{}}
	for id, p := range plans {
		cf.Plans[id] = cachedPlan{int64(p.Hourly), int64(p.GBMonthly), p.MinHours}
	}
	return cf
}

// merge returns c with other's plans added, other winning, stamped with other's time.
func (c cacheFile) merge(other cacheFile) cacheFile {
	out := cacheFile{Region: other.Region, FetchedAt: other.FetchedAt, Plans: map[string]cachedPlan{}}
	for id, p := range c.Plans {
		out.Plans[id] = p
	}
	for id, p := range other.Plans {
		out.Plans[id] = p
	}
	return out
}

func (c cacheFile) catalog(info pricing.CatalogInfo) pricing.StaticCatalog {
	plans := make(map[string]pricing.Plan, len(c.Plans))
	for id, p := range c.Plans {
		plans[id] = pricing.Plan{ID: id, Hourly: pricing.Micros(p.HourlyMicros), GBMonthly: pricing.Micros(p.GBMonthlyMicros), MinHours: p.MinHours}
	}
	return pricing.StaticCatalog{Cur: "USD", Meta: info, Plans: plans}
}

func cachePath(dir, region string) string {
	return filepath.Join(dir, "aws-pricing-"+region+".json")
}

func loadCacheFile(path string) (cacheFile, error) {
	var cf cacheFile
	data, err := os.ReadFile(path)
	if err != nil {
		return cf, err
	}
	if err := json.Unmarshal(data, &cf); err != nil {
		return cf, fmt.Errorf("parsing %s: %w", path, err)
	}
	return cf, nil
}

func saveCacheFile(path string, cf cacheFile) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cf, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}
