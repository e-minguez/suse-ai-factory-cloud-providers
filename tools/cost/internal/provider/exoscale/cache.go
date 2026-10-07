package exoscale

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// cacheFile is the on-disk shape of the warm cache: a fetch timestamp plus
// the price list as fetched.
type cacheFile struct {
	FetchedAt time.Time `json:"fetched_at"`
	Prices    PriceList `json:"prices"`
}

// cachePath is the price list cache file inside dir.
func cachePath(dir string) string { return filepath.Join(dir, "exoscale-pricing.json") }

// LoadCache reads a previously saved price list and the time it was fetched.
func LoadCache(path string) (PriceList, time.Time, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, time.Time{}, err
	}
	var cf cacheFile
	if err := json.Unmarshal(data, &cf); err != nil {
		return nil, time.Time{}, fmt.Errorf("parsing cache %s: %w", path, err)
	}
	if len(cf.Prices[currency]) == 0 {
		return nil, time.Time{}, fmt.Errorf("cache %s has no %q section", path, currency)
	}
	return cf.Prices, cf.FetchedAt, nil
}

// SaveCache persists the price list as the warm cache. Best effort: callers
// ignore a failure.
func SaveCache(path string, pl PriceList, fetchedAt time.Time) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.Marshal(cacheFile{FetchedAt: fetchedAt, Prices: pl})
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}
