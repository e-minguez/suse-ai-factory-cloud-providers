package azure

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// cacheFile is the on-disk warm cache: the kept price items of one region.
type cacheFile struct {
	Region    string    `json:"region"`
	FetchedAt time.Time `json:"fetched_at"`
	Prices    PriceList `json:"prices"`
}

func cachePath(dir, region string) string {
	return filepath.Join(dir, "azure-pricing-"+region+".json")
}

// LoadCache reads a saved price list and the time it was fetched.
func LoadCache(path string) (PriceList, time.Time, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return PriceList{}, time.Time{}, err
	}
	var cf cacheFile
	if err := json.Unmarshal(data, &cf); err != nil {
		return PriceList{}, time.Time{}, fmt.Errorf("parsing cache %s: %w", path, err)
	}
	if len(cf.Prices.Items) == 0 {
		return PriceList{}, time.Time{}, fmt.Errorf("cache %s has no items", path)
	}
	return cf.Prices, cf.FetchedAt, nil
}

// SaveCache persists the price list. Best effort: callers ignore a failure.
func SaveCache(path, region string, pl PriceList, fetchedAt time.Time) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.Marshal(cacheFile{Region: region, FetchedAt: fetchedAt, Prices: pl})
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}
